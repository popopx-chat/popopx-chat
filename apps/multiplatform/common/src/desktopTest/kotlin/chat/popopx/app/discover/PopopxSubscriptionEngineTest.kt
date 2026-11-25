package chat.popopx.app.discover

import chat.popopx.common.discover.PopopxActivationResult
import chat.popopx.common.discover.PopopxDiscoverFilter
import chat.popopx.common.discover.PopopxDiscoverLedger
import chat.popopx.common.discover.PopopxDiscoverLimits
import chat.popopx.common.discover.PopopxDiscoverRenewalOutcome
import chat.popopx.common.discover.PopopxDiscoverServiceStatus
import chat.popopx.common.discover.PopopxNodeCommand
import chat.popopx.common.discover.PopopxNodeMenuAction
import chat.popopx.common.discover.PopopxNodePairing
import chat.popopx.common.discover.PopopxNodeServiceId
import chat.popopx.common.discover.PopopxSubscriptionEngine
import chat.popopx.common.eco.PopopxEcoSecrets
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The 30-day cycle engine (DiscoverSubscriptionManager.swift). Each test names the line it pins.

class PopopxSubscriptionEngineTest {
  @Test
  fun activationBuysTheFirstCycleAndIsPersistedThroughTheKeystore() {
    val h = discoverHarness(balance = 1_000)
    val result = h.engine.activate(PopopxNodeServiceId.ShadowCos)
    val now = h.clock()
    assertEquals(PopopxActivationResult.Charged(PopopxNodeServiceId.ShadowCos, 200, now + PopopxDiscoverLimits.CYCLE_MILLIS), result)
    assertEquals(1, h.ledger.charges)
    assertEquals(listOf(200), h.ledger.amounts)
    // The stored remark is frozen text (DiscoverSubscriptionManager.swift:623-629).
    assertEquals(listOf("Activated Shadow Chief of Staff for 30 days"), h.ledger.notes)

    val row = assertNotNull(h.engine.subscriptionFor(PopopxNodeServiceId.ShadowCos))
    assertEquals(now, row.activatedAtMs)
    assertEquals(now + 30L * 86_400_000L, row.expiresAtMs)
    assertTrue(row.autoRenew, "MEASURED: init sets autoRenew = true (:60), whatever the detail sheet's comment says")
    assertEquals(1, row.cyclesPaid, "the first activation IS a paid cycle (:61)")
    assertNull(row.lastRenewalAtMs)
    assertNull(row.shortfallNoticeExpiresAtMs)

    // Re-read through a fresh engine over the same settings (keystore round trip, :184).
    val reopened = discoverHarness(settings = h.settings)
    val stored = assertNotNull(reopened.engine.subscriptionFor(PopopxNodeServiceId.ShadowCos))
    assertEquals(row, stored)
  }

  @Test
  fun meshActivationIsRefusedBeforeAnyDebit() {
    val h = discoverHarness(balance = 10_000)
    val result = h.engine.activate(PopopxNodeServiceId.EdgeComputeMesh)
    assertTrue(result is PopopxActivationResult.ActivationNotSupported)
    assertEquals(
      "Edge Compute Mesh is settled per job, so there is no 30-day activation to buy.",
      (result as PopopxActivationResult.ActivationNotSupported).notice,
    )
    assertEquals(0, h.ledger.chargeAttempts, "refused IMMEDIATELY — the wallet is never touched (:276-281)")
    assertEquals(0, h.ledger.charges)
    assertTrue(h.engine.subscriptions.isEmpty())
  }

  @Test
  fun secondActivationIsANoOpAndChargeRefusalWritesNothing() {
    val h = discoverHarness(balance = 1_000)
    h.engine.activate(PopopxNodeServiceId.ShadowCos)
    assertEquals(PopopxActivationResult.AlreadyActive(PopopxNodeServiceId.ShadowCos), h.engine.activate(PopopxNodeServiceId.ShadowCos))
    assertEquals(1, h.ledger.charges, "already-subscribed returns BEFORE paying (:275)")

    val poor = discoverHarness(balance = 100)
    val refused = poor.engine.activate(PopopxNodeServiceId.ZeroTrustWarroom) // 500 > 100
    assertTrue(refused is PopopxActivationResult.ChargeRefused)
    assertEquals(0, poor.ledger.charges)
    assertTrue(poor.engine.subscriptions.isEmpty())
    assertFalse(discoverHarness(settings = poor.settings).engine.subscriptions.any { it.serviceId == PopopxNodeServiceId.ZeroTrustWarroom })
  }

  @Test
  fun chargeCommittedBeforeFailedStateWrite() {
    // THE ordering test (class KDoc item 2; Swift :282-297): the debit stands, the row is NOT
    // rolled back from memory, the failure is LOGGED and SURFACED, and the disk stays truthful.
    val backing = discoverSettings()
    val settings = FailingPutSettings(backing, SUBSCRIPTIONS_CT_KEY)
    val h = discoverHarness(settings = settings, balance = 1_000)
    val result = h.engine.activate(PopopxNodeServiceId.ShadowCos)
    assertEquals(PopopxActivationResult.PersistenceFailed(PopopxNodeServiceId.ShadowCos, 200), result)
    assertEquals(1, h.ledger.charges, "the charge is NOT rolled back — this layer does not own the wallet")
    assertEquals(1, h.engine.subscriptions.size, "the row lives in memory for this session (:292-293)")
    assertTrue(h.logs.any { "could not reach the keychain" in it }, "the loss is logged, never hidden (:295)")
    assertEquals(
      "This device could not store the activation. The credits were not spent twice; reopen Discover.",
      (result as PopopxActivationResult.PersistenceFailed).notice,
    )
    // The next launch re-reads the truth from the keystore: no row there (:293-294's stated consequence).
    assertTrue(discoverHarness(settings = backing).engine.subscriptions.isEmpty())
  }

  @Test
  fun renewalExtendsFromTheOldExpiryNeverFromNow() {
    // :365 — expiresAtMs = max(existing, now) + cycle. 29 days in, the window is open at exactly
    // the 24 h boundary (`<=`, :87); the new expiry lands 30 days after the OLD one, so the two
    // days still bought are kept, not refunded into a now-anchored cycle.
    val h = discoverHarness(balance = 10_000)
    val activated = h.engine.activate(PopopxNodeServiceId.ShadowCos)
    val oldExpiry = (activated as PopopxActivationResult.Charged).expiresAtMs
    h.clock.advanceDays(29)
    val outcomes = h.engine.onForeground()
    assertEquals(1, outcomes.size)
    val renewed = outcomes[0]
    assertTrue(renewed is PopopxDiscoverRenewalOutcome.Renewed)
    assertEquals(oldExpiry + PopopxDiscoverLimits.CYCLE_MILLIS, (renewed as PopopxDiscoverRenewalOutcome.Renewed).expiresAtMs)
    val row = assertNotNull(h.engine.subscriptionFor(PopopxNodeServiceId.ShadowCos))
    assertEquals(oldExpiry + PopopxDiscoverLimits.CYCLE_MILLIS, row.expiresAtMs)
    assertEquals(h.clock(), row.lastRenewalAtMs)
    assertEquals(2, row.cyclesPaid)
    assertEquals(listOf("Activated Shadow Chief of Staff for 30 days", "Renewed Shadow Chief of Staff for 30 days from the credit balance"), h.ledger.notes)
    assertEquals(10_000 - 400, h.ledger.balance)

    // A second sweep in the same window: the window closed behind the renewal by construction.
    assertEquals(listOf(PopopxDiscoverRenewalOutcome.NotDue(PopopxNodeServiceId.ShadowCos)), h.engine.onPullToRefresh())
    assertEquals(2, h.ledger.charges, "sweep is safe to call on every foreground (:322-324)")
  }

  @Test
  fun renewalOutsideTheWindowIsNotDue() {
    val h = discoverHarness(balance = 10_000)
    h.engine.activate(PopopxNodeServiceId.ShadowCos)
    assertEquals(listOf(PopopxDiscoverRenewalOutcome.NotDue(PopopxNodeServiceId.ShadowCos)), h.engine.sweep())
    assertEquals(1, h.ledger.charges, "activation only")
    h.clock.advanceDays(31) // lapsed: the sweep NEVER revives a dead cycle — renewal requires isActive (:83-88)
    assertEquals(listOf(PopopxDiscoverRenewalOutcome.NotDue(PopopxNodeServiceId.ShadowCos)), h.engine.sweep())
    assertEquals(1, h.ledger.charges)
    assertEquals(PopopxDiscoverServiceStatus.Expired, h.engine.statusFor(PopopxNodeServiceId.ShadowCos))
  }

  @Test
  fun aMeteredRowInStorageReportsNotRenewableAndIsSkipped() {
    // The :334 guard is unreachable through activate(); craft the stored row the way a migration
    // could, and prove the sweep walks past it without touching the wallet.
    val settings = discoverSettings()
    val body = """[{"serviceId":"edge_compute_mesh","activatedAtMs":1,"expiresAtMs":99999999999999,"autoRenew":true,"cyclesPaid":1}]"""
    assertTrue(PopopxEcoSecrets.write(body.encodeToByteArray(), "popopx.discover.subscriptions", settings))
    val h = discoverHarness(settings = settings, balance = 10_000)
    assertEquals(listOf(PopopxDiscoverRenewalOutcome.NotRenewable(PopopxNodeServiceId.EdgeComputeMesh)), h.engine.sweep())
    assertEquals(0, h.ledger.chargeAttempts)
    // One live (metered) row still counts for the badge; only its own section chip appears (:255-265).
    assertEquals(1, h.engine.activeCount)
    assertEquals(mapOf(PopopxDiscoverFilter.ALL to 1, PopopxDiscoverFilter.COMPUTE to 1), h.engine.activeCountByFilter())
  }

  @Test
  fun balanceShortPostsOneNoticePerExpiry() {
    val h = discoverHarness(balance = 1_000)
    val activated = h.engine.activate(PopopxNodeServiceId.ShadowCos)
    val expiry = (activated as PopopxActivationResult.Charged).expiresAtMs
    h.clock.advanceMillis(29L * 86_400_000L + 3_600_000L) // inside the last day, still active
    h.ledger.balance = 50 // something else spent the wallet between cycles
    h.authorised = true

    val outcomes = h.engine.onForeground()
    assertEquals(listOf<PopopxDiscoverRenewalOutcome>(PopopxDiscoverRenewalOutcome.BalanceShort(PopopxNodeServiceId.ShadowCos, 200, 50)), outcomes)
    assertEquals(1, h.posted.size)
    val notice = h.posted.single()
    assertEquals("Compute credits are not enough", notice.title)
    assertEquals("Shadow Chief of Staff renews in less than a day and costs 200 credits. This wallet holds 50.", notice.body)
    assertEquals("popopx.discover.shortfall.shadow_cos.$expiry", notice.requestIdentifier)
    assertEquals("popopx.discover.shortfall", notice.channelId) // the literal, :585
    assertEquals(setOf(PopopxNodeServiceId.ShadowCos), h.engine.servicesAwaitingBalance)
    assertEquals(1, h.ledger.charges, "no renewal charge was taken — only the activation debit stands")

    // Same expiry, repeated foregrounds: silence (:391-393, :400).
    h.engine.onPullToRefresh()
    h.engine.onForeground()
    assertEquals(1, h.posted.size)

    // Once it lapses: awaitingBalance, usable=NO — the grace of a lapsed cycle is not a free day of compute (:142-149).
    // overdueDays TRUNCATES (:237-239, "less than a day overdue" reads as none, not as one).
    h.clock.advanceDays(2)
    val status = h.engine.statusFor(PopopxNodeServiceId.ShadowCos)
    assertEquals(PopopxDiscoverServiceStatus.AwaitingBalance(1), status)
    assertFalse(status.isUsable)
    assertEquals("Waiting for credits", status.label)
  }

  @Test
  fun unauthorisedNoticesAreSuppressedButStillMarked() {
    val h = discoverHarness(balance = 1_000)
    h.engine.activate(PopopxNodeServiceId.ShadowCos)
    h.clock.advanceMillis(29L * 86_400_000L + 3_600_000L)
    h.ledger.balance = 50
    h.authorised = false
    h.engine.onForeground()
    assertEquals(0, h.posted.size)
    assertTrue(h.logs.any { "notifications not authorised" in it })
    // Permission arriving later must NOT retroactively spam the lapse the marker already covered.
    h.authorised = true
    h.engine.onForeground()
    assertEquals(0, h.posted.size)
  }

  @Test
  fun aWalletRefusalMidSweepRecordsShortWithoutANotice() {
    // :355-362: payForService checked the balance again and refused — recorded as balanceShort,
    // NO notice, expiry untouched, and the OTHER rows still swept.
    val h = discoverHarness(balance = 10_000)
    h.engine.activate(PopopxNodeServiceId.ShadowCos) // 200
    h.engine.activate(PopopxNodeServiceId.MorningTv) // 100
    h.clock.advanceMillis(29L * 86_400_000L + 3_600_000L)
    h.ledger.accept = false
    h.authorised = true
    val outcomes = h.engine.sweep()
    assertEquals(
      listOf(
        PopopxDiscoverRenewalOutcome.BalanceShort(PopopxNodeServiceId.ShadowCos, 200, 9_700),
        PopopxDiscoverRenewalOutcome.BalanceShort(PopopxNodeServiceId.MorningTv, 100, 9_700),
      ),
      outcomes,
    )
    assertEquals(0, h.posted.size, "the throw path posts nothing (:356-362)")
    assertEquals(2, h.engine.servicesAwaitingBalance.size)
  }

  @Test
  fun perRowBalanceReadsMakeTheFirstRenewalButNotTheSecond() {
    val h = discoverHarness(balance = 700)
    val first = h.engine.activate(PopopxNodeServiceId.ZeroTrustWarroom) // 500 -> 200 left
    val oldExpiry = (first as PopopxActivationResult.Charged).expiresAtMs
    h.engine.activate(PopopxNodeServiceId.ShadowCos) // 200 -> 0 left
    assertEquals(0, h.ledger.balance)
    h.clock.advanceMillis(29L * 86_400_000L + 3_600_000L)
    h.ledger.balance = 600 // topped up, enough for ONE renewal
    h.authorised = false
    val outcomes = h.engine.onForeground()
    assertEquals(
      listOf<PopopxDiscoverRenewalOutcome>(
        PopopxDiscoverRenewalOutcome.Renewed(PopopxNodeServiceId.ZeroTrustWarroom, 500, oldExpiry + PopopxDiscoverLimits.CYCLE_MILLIS),
        PopopxDiscoverRenewalOutcome.BalanceShort(PopopxNodeServiceId.ShadowCos, 200, 100),
      ),
      outcomes,
    )
    assertEquals(100, h.ledger.balance, "the balance was re-read between rows (:342)")
    assertEquals(setOf(PopopxNodeServiceId.ShadowCos), h.engine.servicesAwaitingBalance)
    assertEquals(0, h.posted.size)
  }

  @Test
  fun triggersAreExactlyForegroundAndPullToRefresh() {
    val h = discoverHarness(balance = 10_000)
    assertNull(h.engine.lastSweepAtMs, "construction sweeps nothing")
    h.engine.subscriptionFor(PopopxNodeServiceId.ShadowCos)
    h.engine.statusFor(PopopxNodeServiceId.ShadowCos)
    h.engine.resultsFor(PopopxNodeServiceId.ShadowCos)
    h.engine.activeCount
    assertNull(h.engine.lastSweepAtMs, "reads never sweep; there is no timer, no push, no background task (:190-202, PopopxDiscoverView.swift:79)")
    h.engine.onForeground()
    assertNotNull(h.engine.lastSweepAtMs)
    val at = h.engine.lastSweepAtMs ?: error("a sweep stamps the instant")
    h.engine.onPullToRefresh()
    assertTrue(h.engine.lastSweepAtMs!! >= at)
  }

  @Test
  fun dispatchGateOrderIsWireFirstContactSecondPaidThird() {
    val h = discoverHarness(balance = 1_000)
    val action = PopopxNodeServiceId.ShadowCos.menuActions.first() // Today's action brief / briefing
    // No node at all.
    assertFalse(h.engine.dispatch(action))
    assertTrue(h.sent.isEmpty())
    // Bonded and attached, but NOT activated: a renewable service is refused before the wire.
    val offer = assertNotNull(PopopxNodePairing.parse(liveOfferCode(h.clock())))
    h.engine.bond(offer)
    h.engine.attach(77L, "Mac")
    assertFalse(h.engine.dispatch(action))
    assertTrue(h.sent.isEmpty())
    // Activated: it goes, on the bonded contact, and delivery confirms the handshake.
    h.engine.activate(PopopxNodeServiceId.ShadowCos)
    h.senderAccepts = true
    assertTrue(h.engine.dispatch(action))
    assertEquals(listOf(action.command to 77L), h.sent)
    assertTrue(assertNotNull(h.engine.binding).handshakeConfirmed)
    // An oversized command cannot be built from the menu, only directly — still refused un-sent.
    val fat = PopopxNodeMenuAction("x", "a".repeat(1_200), PopopxNodeServiceId.ShadowCos)
    assertFalse(h.engine.dispatch(fat))
    assertEquals(1, h.sent.size)
  }

  @Test
  fun lapsedServiceCannotDispatchEvenThoughTheBadgeLooksAlive() {
    val h = discoverHarness(balance = 1_000)
    val offer = assertNotNull(PopopxNodePairing.parse(liveOfferCode(h.clock())))
    h.engine.bond(offer)
    h.engine.attach(77L, "Mac")
    h.engine.activate(PopopxNodeServiceId.MorningTv)
    h.ledger.balance = 0
    h.authorised = false
    h.clock.advanceMillis(29L * 86_400_000L + 3_600_000L)
    h.engine.sweep() // -> balanceShort, awaiting
    h.senderAccepts = true
    // Still ACTIVE for ~1 h and inside the window: usable-looking but ExpiringToday is USABLE.
    // Jump past expiry: now awaitingBalance -> not usable -> dispatch refused (:142-149).
    h.clock.advanceDays(3)
    assertEquals(PopopxDiscoverServiceStatus.AwaitingBalance(2), h.engine.statusFor(PopopxNodeServiceId.MorningTv))
    assertFalse(h.engine.dispatch(PopopxNodeServiceId.MorningTv.menuActions.first()))
    assertTrue(h.sent.isEmpty())
  }

  @Test
  fun handshakeUsesTheMeasuredMeshProbeNotASystemVerb() {
    val h = discoverHarness()
    assertFalse(h.engine.sendHandshake(), "no contact, no probe")
    val offer = assertNotNull(PopopxNodePairing.parse(liveOfferCode(h.clock())))
    h.engine.bond(offer)
    h.engine.attach(9L, "Mac")
    h.senderAccepts = true
    assertTrue(h.engine.sendHandshake())
    val sent = h.lastSentCommand()
    assertEquals(PopopxNodeCommand(PopopxNodeServiceId.EdgeComputeMesh, "status", "{\"probe\":\"pairing\"}"), sent)
    assertTrue(sent!!.isAcceptedByNode)
    assertEquals(9L, h.sent.single().second)
    assertTrue(assertNotNull(h.engine.binding).handshakeConfirmed)
  }

  @Test
  fun unpairedBubblesStayBubblesAndPairedCardsFillTheCappedInbox() {
    val h = discoverHarness()
    val text = "\u2705 Shadow Chief of Staff \u00b7 Daily brief ready \u00b7 1432 ms"
    assertNull(h.engine.recordInboundText(text, fromPairedNode = false))
    assertTrue(h.engine.resultsFor(PopopxNodeServiceId.ShadowCos).isEmpty(), "a nil card means the message renders as it arrived")
    assertNotNull(h.engine.recordInboundText(text, fromPairedNode = true))
    assertEquals(1, h.engine.resultsFor(PopopxNodeServiceId.ShadowCos).size)

    // 45 recorded commands: newest first, capped at 40, oldest five gone — and the cap survives a reload.
    val base = 1_700_000_000_000L
    for (i in 0 until 45) {
      h.engine.recordInboundCommand(PopopxNodeCommand(PopopxNodeServiceId.ChronoArk, "heartbeat"), now = base + i)
    }
    val rows = h.engine.resultsFor(PopopxNodeServiceId.ChronoArk)
    assertEquals(40, rows.size)
    assertEquals(base + 44, rows.first().receivedAtMs)
    assertEquals(base + 5, rows.last().receivedAtMs)

    val reopened = discoverHarness(settings = h.settings)
    val reloaded = reopened.engine.resultsFor(PopopxNodeServiceId.ChronoArk)
    assertEquals(40, reloaded.size)
    assertEquals(rows.map { it.id }, reloaded.map { it.id })
  }

  @Test
  fun stopKeepsTheInboxEraseTakesEverything() {
    val h = discoverHarness(balance = 1_000)
    val offer = assertNotNull(PopopxNodePairing.parse(liveOfferCode(h.clock())))
    h.engine.bond(offer)
    h.engine.recordInboundCommand(PopopxNodeCommand(PopopxNodeServiceId.SoloAutopilot, "run"))
    h.engine.stop(PopopxNodeServiceId.SoloAutopilot) // no row existed; the next assert is about erase anyway
    h.engine.activate(PopopxNodeServiceId.ShadowCos)
    h.engine.stop(PopopxNodeServiceId.ShadowCos)
    assertNull(h.engine.subscriptionFor(PopopxNodeServiceId.ShadowCos))
    assertEquals(1, h.engine.resultsFor(PopopxNodeServiceId.SoloAutopilot).size, "a cancelled service keeps the results the Mac produced (:309-310)")

    h.engine.eraseLocalState()
    assertNull(h.engine.binding)
    assertTrue(h.engine.subscriptions.isEmpty())
    val after = discoverHarness(settings = h.settings)
    assertNull(after.engine.binding)
    assertTrue(after.engine.subscriptions.isEmpty())
    assertTrue(after.engine.resultsFor(PopopxNodeServiceId.SoloAutopilot).isEmpty())
  }

  @Test
  fun badgesLabelsAndUsabilityMatchTheSwiftTable() {
    val h = discoverHarness(balance = 10_000)
    assertEquals(PopopxDiscoverServiceStatus.NotActivated, h.engine.statusFor(PopopxNodeServiceId.ShadowCos))
    assertEquals("Not activated", h.engine.statusFor(PopopxNodeServiceId.ShadowCos).label)
    assertEquals(PopopxDiscoverServiceStatus.Metered, h.engine.statusFor(PopopxNodeServiceId.EdgeComputeMesh))
    assertEquals("Metered, settled per job", h.engine.statusFor(PopopxNodeServiceId.EdgeComputeMesh).label)
    assertTrue(h.engine.statusFor(PopopxNodeServiceId.EdgeComputeMesh).isUsable)

    h.engine.activate(PopopxNodeServiceId.ShadowCos)
    val active = h.engine.statusFor(PopopxNodeServiceId.ShadowCos)
    assertEquals(PopopxDiscoverServiceStatus.Active(true), active)
    assertEquals("Running \u00b7 auto-renew", active.label)
    assertTrue(active.isUsable)
    h.engine.setAutoRenew(false, PopopxNodeServiceId.ShadowCos)
    assertEquals("Running", h.engine.statusFor(PopopxNodeServiceId.ShadowCos).label)

    h.clock.advanceMillis(29L * 86_400_000L + 3_600_000L)
    val expiring = h.engine.statusFor(PopopxNodeServiceId.ShadowCos)
    assertEquals(PopopxDiscoverServiceStatus.ExpiringToday(false), expiring)
    assertEquals("Expires today", expiring.label)
    assertTrue(expiring.isUsable)

    h.clock.advanceDays(40)
    val expired = h.engine.statusFor(PopopxNodeServiceId.ShadowCos)
    assertEquals(PopopxDiscoverServiceStatus.Expired, expired)
    assertEquals("Paused", expired.label)
    assertFalse(expired.isUsable)
  }

  @Test
  fun turningAutoRenewBackOnClearsTheNoticeMarker() {
    val h = discoverHarness(balance = 1_000)
    h.engine.activate(PopopxNodeServiceId.MorningTv)
    h.clock.advanceMillis(29L * 86_400_000L + 3_600_000L)
    h.ledger.balance = 0
    h.authorised = true
    h.engine.sweep()
    assertEquals(1, h.posted.size)
    h.engine.sweep()
    assertEquals(1, h.posted.size)
    h.engine.setAutoRenew(true, PopopxNodeServiceId.MorningTv)
    h.engine.sweep()
    assertEquals(2, h.posted.size, "the marker cleared, so the SAME lapse may warn once more (:305)")
  }

  @Test
  fun ledgerUnpaidDefaultBehavesLikeAnEmptyWallet() {
    // The no-wiring state of the module: every activation refuses, nothing throws, nothing stores.
    val engine = PopopxSubscriptionEngine(defaults = discoverSettings(), nowMs = DiscoverClock(1L).let { { it() } })
    assertTrue(engine.activate(PopopxNodeServiceId.ChronoArk) is PopopxActivationResult.ChargeRefused)
    assertEquals(0, PopopxDiscoverLedger.UNPAID.balance)
    assertFalse(PopopxDiscoverLedger.UNPAID.payForService(1, "note"))
    assertTrue(engine.activeCountByFilter().isEmpty())
  }
}
