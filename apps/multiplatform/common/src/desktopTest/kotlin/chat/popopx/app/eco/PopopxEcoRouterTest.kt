package chat.popopx.app.eco

import chat.popopx.common.eco.PopopxEcoAction
import chat.popopx.common.eco.PopopxEcoApplyOutcome
import chat.popopx.common.eco.PopopxCreditSource
import chat.popopx.common.eco.PopopxEcoCreditRequest
import chat.popopx.common.eco.PopopxEcoDeepLinkHandler
import chat.popopx.common.eco.PopopxEcoInboundVerdict
import chat.popopx.common.eco.PopopxEcoIntent
import chat.popopx.common.eco.PopopxEcoLink
import chat.popopx.common.eco.PopopxEcoLimits
import chat.popopx.common.eco.PopopxEcoMarker
import chat.popopx.common.eco.PopopxEcoRouter
import chat.popopx.common.eco.PopopxEcoSendFailure
import chat.popopx.common.eco.PopopxEcoSendOutcome
import chat.popopx.common.eco.PopopxEcoSender
import chat.popopx.common.eco.PopopxEcoStore
import chat.popopx.common.eco.PopopxEcoUplink
import chat.popopx.common.eco.PopopxChannelBase64
import chat.popopx.common.eco.PopopxChannelEnvelope
import chat.popopx.common.eco.PopopxChannelKeyRotation
import chat.popopx.common.eco.PopopxChannelKeyUpdate
import chat.popopx.common.eco.PopopxCreditPayment
import chat.popopx.common.eco.PopopxH5Launcher
import chat.popopx.common.eco.PopopxServiceCard
import chat.popopx.common.eco.PopopxEcoActionRunner
import chat.popopx.common.eco.PopopxEcoActionResult
import chat.popopx.common.model.ChatType
import com.russhwolf.settings.Settings
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The router's ordering rules, which are the part a mount point can get wrong silently: which frame may be
// applied to which chat, which row is erased afterwards, whether a debit can precede its confirmation, and
// which handshake is allowed to collect a held `::SSO_SCAN::`.

private const val CARD_JSON = """{"t":"sc","m":"c","card":{"id":"card.1","v":"standard","title":"T","ut":1000}}"""
private const val MENU_JSON = """{"t":"mc","menu":{"items":[{"title":"A","action":"callback","payload":"a","sub":[]}]}}"""
private const val HANDSHAKE_JSON = """{"t":"sh","uid":"popopx1abc","sec":"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"}"""
private const val CONTACT = 7L

private class RecordingSender : PopopxEcoSender {
  val sent = ArrayList<Pair<Long, String>>()
  val erased = ArrayList<Triple<ChatType, Long, Long>>()
  var outcome: PopopxEcoSendOutcome = PopopxEcoSendOutcome.Sent

  override suspend fun sendUplink(contactId: Long, text: String): PopopxEcoSendOutcome {
    sent.add(contactId to text)
    return outcome
  }

  override suspend fun eraseControlRow(chatType: ChatType, chatId: Long, itemId: Long) {
    erased.add(Triple(chatType, chatId, itemId))
  }
}

private class FakeCredits(
  override var balance: Int = 100,
  var entryId: String? = "tx.1",
) : PopopxCreditSource {
  val debits = ArrayList<Pair<Int, String>>()
  var refused = false

  override fun payForService(amount: Int, note: String): String? {
    if (refused) return null
    debits.add(amount to note)
    balance -= amount
    return entryId
  }
}

private class Fixture(
  defaults: Settings = ecoSettings(),
  credits: FakeCredits? = null,
  startMs: Long = 1_700_000_000_000L,
  private var nowMs: Long = startMs,
) {
  val sender = RecordingSender()
  val rotation = PopopxChannelKeyRotation(defaults)
  val store = PopopxEcoStore(defaults, rotation)
  val router = PopopxEcoRouter(
    store = store,
    sender = sender,
    keyRotation = rotation,
    h5 = PopopxH5Launcher(),
    creditsSource = { credits },
    nowMs = { nowMs },
    directContactIds = { knownContactIds },
    connectionInProgress = { inProgress },
  )

  var knownContactIds: Set<Long> = setOf(1L, 2L)
  var inProgress = false

  fun advanceSeconds(seconds: Long) {
    nowMs += seconds * 1000
  }
}

class PopopxEcoRouterTest {
  // MARK: - The inbound gate

  @Test
  fun onlyDirectAndGroupChatsAreEvenConsidered() = runBlocking<Unit> {
    val f = Fixture()
    for (type in listOf(ChatType.Local, ChatType.ContactRequest, ChatType.ContactConnection)) {
      assertEquals(
        PopopxEcoInboundVerdict.NOT_ECO,
        f.router.observeIncoming(type, CONTACT, 1L, ecoFrameText(CARD_JSON)),
        type.toString()
      )
    }
    assertEquals(PopopxEcoInboundVerdict.NOT_ECO, f.router.observeIncoming(ChatType.Direct, CONTACT, 1L, "just text"))
    assertTrue(f.sender.erased.isEmpty())
  }

  /**
   * The group rule is the whole cross-member leak guard: a menu would attach one member's private buttons to
   * a shared conversation, a handshake would store one member's pairwise identity under the group's id, and
   * a key update would push an epoch key to people who are not members of that channel.
   */
  @Test
  fun aGroupAcceptsOnlyACard() = runBlocking<Unit> {
    val f = Fixture()
    // A `ku` frame has to survive the decoder before the group rule can refuse it: its payload section is
    // `update` (`ch`/`se`/`env`), and a frame that only pretends — the iOS-shaped `chan`/`sealed` — is dropped
    // one step earlier and never reaches the guard. The envelope's own sanity gate measures BYTES, not
    // characters, so the three fields are encoded at their real widths: a 12-byte nonce, a ciphertext one
    // byte past the 16-byte tag, and a 64-byte signature. A `"nonce":"AQ"` literal is a correct-looking
    // string that decodes to one byte, and the whole frame is refused for it.
    val envelope = PopopxChannelEnvelope(
      epoch = 2,
      nonceBase64 = PopopxChannelBase64.encode(ByteArray(PopopxChannelEnvelope.NONCE_BYTES)),
      ciphertextBase64 = PopopxChannelBase64.encode(ByteArray(PopopxChannelEnvelope.TAG_BYTES + 1)),
      signatureBase64 = PopopxChannelBase64.encode(ByteArray(PopopxChannelEnvelope.SIGNATURE_BYTES)),
    )
    // The text comes from this module's own wire encoder: a `ku` frame nests an update object inside an
    // envelope object, and writing that by hand is a test of the test's brackets rather than of the gate.
    val keyUpdate = PopopxEcoMarker.wireString(
      chat.popopx.common.eco.PopopxEcoFrame.ChannelKeyUpdate(PopopxChannelKeyUpdate("chan", 1, false, envelope))
    )
    assertNotNull(PopopxEcoMarker.parseControlText(keyUpdate))
    assertNull(PopopxEcoMarker.parseControlText(ecoFrameText("""{"t":"ku","chan":"c","sealed":1,"env":{}}""")))

    assertEquals(PopopxEcoInboundVerdict.REFUSED_IN_GROUP, f.router.observeIncoming(ChatType.Group, 9L, 1L, ecoFrameText(MENU_JSON)))
    assertEquals(PopopxEcoInboundVerdict.REFUSED_IN_GROUP, f.router.observeIncoming(ChatType.Group, 9L, 1L, ecoFrameText(HANDSHAKE_JSON)))
    assertEquals(PopopxEcoInboundVerdict.REFUSED_IN_GROUP, f.router.observeIncoming(ChatType.Group, 9L, 1L, keyUpdate))
    // Refusing is not deleting: iOS logs and returns here, because a group message belongs to the sender's
    // conversation and this device has no authority to erase somebody else's row out of it.
    assertTrue(f.sender.erased.isEmpty(), "a refused group frame must not be erased locally")
    assertNull(f.store.liveMenu(9L))
    assertNull(f.store.session(9L))

    // Same frame, direct: the store takes it.
    assertTrue(f.router.observeIncoming(ChatType.Direct, CONTACT, 1L, ecoFrameText(MENU_JSON)) is PopopxEcoInboundVerdict.Applied)
    // A card in a group is not refused, and it is the only thing that is not.
    assertTrue(f.router.observeIncoming(ChatType.Group, 9L, 1L, ecoFrameText(CARD_JSON)) is PopopxEcoInboundVerdict.Applied)
    val stored = f.store.card("card.1") ?: error("a card survives the group gate")
    assertEquals("card.1", stored.cardId)
    assertEquals("T", stored.title)
    assertEquals(1000L, stored.updatedAtMs)
    assertEquals(PopopxServiceCard.Mode.CREATE, stored.mode)
  }

  /**
   * Which outcomes erase the row is a decision, not a detail: a created card is the bubble the user reads and
   * must stay, while every frame that only mutates this device must vanish — with `.cidmInternal`, since a
   * broadcast deletion writes this module's existence into the peer's timeline.
   */
  @Test
  fun theRowSurvivesOnlyForTheCardTheUserReads() = runBlocking<Unit> {
    val f = Fixture()
    f.router.observeIncoming(ChatType.Direct, CONTACT, 11L, ecoFrameText(CARD_JSON))
    assertTrue(f.sender.erased.isEmpty(), "a created card must keep its row")

    f.router.observeIncoming(ChatType.Direct, CONTACT, 12L, ecoFrameText(HANDSHAKE_JSON))
    f.router.observeIncoming(ChatType.Direct, CONTACT, 13L, ecoFrameText(MENU_JSON))
    assertEquals(
      listOf(Triple(ChatType.Direct, CONTACT, 12L), Triple(ChatType.Direct, CONTACT, 13L)),
      f.sender.erased
    )

    // A second, newer card sent as an UPDATE changes the bubble in place, so its own row is erased and the
    // first one remains. The `m` has to move with the timestamp: iOS picks the outcome from the frame's mode
    // alone (`PopopxEcoRouterAndDeepLink.swift:174` — `card.mode == .create ? .renderedCard : .updatedCard`),
    // so a second `m:"c"` frame is a new bubble and its row correctly stays.
    f.router.observeIncoming(
      ChatType.Direct,
      CONTACT,
      14L,
      ecoFrameText(CARD_JSON.replace("\"ut\":1000", "\"ut\":2000").replace("\"m\":\"c\"", "\"m\":\"u\""))
    )
    assertEquals(listOf(Triple(ChatType.Direct, CONTACT, 12L), Triple(ChatType.Direct, CONTACT, 13L), Triple(ChatType.Direct, CONTACT, 14L)), f.sender.erased)
    assertEquals(2000L, f.store.card("card.1")!!.updatedAtMs)

    // A refused or stale frame erases nothing of its own accord.
    val before = f.sender.erased.size
    f.router.observeIncoming(ChatType.Direct, CONTACT, 15L, ecoFrameText("""{"t":"sc","m":"c","card":{"id":"","v":"standard","title":"x","ut":1}}"""))
    f.router.observeIncoming(ChatType.Direct, CONTACT, 16L, ecoFrameText(CARD_JSON))
    assertEquals(before, f.sender.erased.size)
  }

  // MARK: - Uplink

  @Test
  fun anUplinkLineIsBuiltByTheSameFunctionThatSuppressesItOnScreen() = runBlocking<Unit> {
    val f = Fixture()
    assertEquals(PopopxEcoSendOutcome.Sent, f.router.sendCallback("buy:2", CONTACT))
    assertEquals(listOf(CONTACT to "::CB::buy:2"), f.sender.sent)
    assertTrue(PopopxEcoUplink.isUplinkText(f.sender.sent.single().second))

    f.router.sendReference("art.9", CONTACT)
    f.router.sendSSOScan("s-1", CONTACT)
    assertEquals(listOf("::REF::art.9", "::SSO_SCAN::s-1"), f.sender.sent.drop(1).map { it.second })
  }

  /**
   * A payload with whitespace would make one line look like two commands, so it is refused BEFORE anything
   * is sent — the sender must not have been touched at all.
   */
  @Test
  fun aPayloadThatLooksLikeTwoCommandsNeverLeavesTheDevice() = runBlocking<Unit> {
    val f = Fixture()
    for (bad in listOf("buy now", "a::b", "")) {
      val outcome = f.router.sendCallback(bad, CONTACT)
      assertEquals(PopopxEcoSendOutcome.failed(PopopxEcoSendFailure.MALFORMED_PAYLOAD), outcome, bad)
    }
    assertTrue(f.sender.sent.isEmpty())
  }

  @Test
  fun aRefusedSendIsReportedAsRefusedRatherThanAsSent() = runBlocking<Unit> {
    val f = Fixture()
    f.sender.outcome = PopopxEcoSendOutcome.failed(PopopxEcoSendFailure.SEND_REFUSED)
    assertFalse(f.router.sendReference("a", CONTACT).wasSent)
  }

  // MARK: - Pending intents

  @Test
  fun anIntentIsStampedByTheRouterNotByItsCaller() = runBlocking<Unit> {
    val f = Fixture()
    f.knownContactIds = setOf(1L, 2L)
    f.router.recordPendingIntent(PopopxEcoIntent.Kind.SsoScan("s-1"), "smp://x/y#key=z", "s-1")
    val intent = f.router.pendingIntent
    assertNotNull(intent)
    // Recorded at the injected instant, so `advanceSeconds` alone decides staleness.
    assertFalse(intent.isStale(1_700_000_000_000L + PopopxEcoLimits.PENDING_INTENT_LIFETIME_SECONDS * 1000 - 1000))
    assertTrue(intent.isStale(1_700_000_000_000L + PopopxEcoLimits.PENDING_INTENT_LIFETIME_SECONDS * 1000 + 1000))
    // The snapshot is taken at the same instant, which is the only thing the before/after test can rest on.
    assertEquals(setOf(1L, 2L), intent.knownContactIds)
    assertNull(intent.boundContactId)
  }

  @Test
  fun anUnboundIntentGoesOnlyToAContactTheLinkCannotHaveAlreadyKnown() {
    val f = Fixture()
    f.router.recordPendingIntent(PopopxEcoIntent.Kind.Reference("art"), "smp://x/y", "art")
    val intent = f.router.pendingIntent!!
    assertFalse(intent.accepts(1L))
    assertFalse(intent.accepts(2L))
    assertTrue(intent.accepts(3L))

    f.router.bindPendingIntent(1L)
    val bound = f.router.pendingIntent!!
    assertTrue(bound.accepts(1L))
    assertFalse(bound.accepts(3L))
  }

  /**
   * Delivery happens on a DIRECT handshake only, and a refused intent is still CONSUMED: leaving it in the
   * slot would hand it to the next handshake instead, which is the exact mis-delivery these tests exist to
   * prevent.
   */
  @Test
  fun aHandshakeCollectsOneIntentAndThenTheSlotIsEmpty() = runBlocking<Unit> {
    val f = Fixture()
    f.router.recordPendingIntent(PopopxEcoIntent.Kind.Reference("art.5"), "smp://x/y", "art.5")
    // A menu frame is not a handshake: nothing is delivered.
    f.router.observeIncoming(ChatType.Direct, 3L, 1L, ecoFrameText(MENU_JSON))
    assertEquals(0, f.sender.sent.size)
    assertNotNull(f.router.pendingIntent)

    f.router.observeIncoming(ChatType.Direct, 3L, 2L, ecoFrameText(HANDSHAKE_JSON))
    assertEquals(listOf(3L to "::REF::art.5"), f.sender.sent)
    assertNull(f.router.pendingIntent)

    // A second handshake delivers nothing: the intent had its one shot.
    f.router.observeIncoming(ChatType.Direct, 4L, 3L, ecoFrameText(HANDSHAKE_JSON))
    assertEquals(1, f.sender.sent.size)
  }

  @Test
  fun anExpiredIntentIsConsumedRatherThanQueued() = runBlocking<Unit> {
    val f = Fixture()
    f.router.recordPendingIntent(PopopxEcoIntent.Kind.SsoScan("s-1"), "smp://x/y", "s-1")
    f.advanceSeconds(PopopxEcoLimits.PENDING_INTENT_LIFETIME_SECONDS + 1)
    f.router.observeIncoming(ChatType.Direct, 3L, 1L, ecoFrameText(HANDSHAKE_JSON))
    assertTrue(f.sender.sent.isEmpty())
    assertNull(f.router.pendingIntent)
  }

  @Test
  fun aHandshakeFromAnUnrelatedContactRefusesButStillClearsTheIntent() = runBlocking<Unit> {
    val f = Fixture()
    f.knownContactIds = setOf(3L)
    f.router.recordPendingIntent(PopopxEcoIntent.Kind.SsoScan("s-1"), "smp://x/y", "s-1")
    f.router.observeIncoming(ChatType.Direct, 3L, 1L, ecoFrameText(HANDSHAKE_JSON))
    assertTrue(f.sender.sent.isEmpty())
    assertNull(f.router.pendingIntent)
  }

  @Test
  fun anAbandonedConnectionDropsTheIntentButASuccessfulOneDoesNot() = runBlocking<Unit> {
    val f = Fixture()
    f.router.recordPendingIntent(PopopxEcoIntent.Kind.Reference("art"), "smp://x/y", "art")

    // Still in progress: `cleanup` may have run for the success path, so this proves nothing yet.
    f.inProgress = true
    f.router.discardPendingIntentIfConnectionAborted()
    assertNotNull(f.router.pendingIntent)

    f.inProgress = false
    // No new contact appeared, so nothing was created by the link: abandoned.
    f.router.discardPendingIntentIfConnectionAborted()
    assertNull(f.router.pendingIntent)

    // The same call after the link DID create a contact leaves the intent for the handshake to collect.
    f.router.recordPendingIntent(PopopxEcoIntent.Kind.Reference("art"), "smp://x/y", "art")
    f.knownContactIds = setOf(1L, 2L, 5L)
    f.router.discardPendingIntentIfConnectionAborted()
    assertNotNull(f.router.pendingIntent)

    // A bound intent belongs to a connected contact; the handshake owns its delivery, not this cleanup.
    f.router.bindPendingIntent(1L)
    f.knownContactIds = setOf(1L, 2L)
    f.router.discardPendingIntentIfConnectionAborted()
    assertNotNull(f.router.pendingIntent)
  }

  // MARK: - Paying with credits

  /**
   * The order is the security property: balance first, ledger second, callback third. A
   * `::CB::<payload>:paid_<txHash>` naming a transaction that does not exist would be a payment confirmation
   * the server can neither refuse nor honour.
   */
  @Test
  fun theDebitIsProvenAffordableBeforeAnythingIsWritten() = runBlocking<Unit> {
    val credits = FakeCredits(balance = 40)
    val f = Fixture(credits = credits)
    val card = f.store.rendered(card("card.pay", 3))
    val action = payAction("a1", 50, "job.1")

    val payment = f.router.payForCard(card, action, CONTACT)
    assertEquals(PopopxCreditPayment.InsufficientBalance(50, 40), payment)
    assertTrue(credits.debits.isEmpty())
    assertTrue(f.sender.sent.isEmpty())
  }

  @Test
  fun anUnsendableCallbackPayloadRefusesThePaymentBeforeTheDebit() = runBlocking<Unit> {
    val credits = FakeCredits(balance = 100)
    val f = Fixture(credits = credits)
    val card = f.store.rendered(card("card.pay", 3))
    // A payload holding a space is a line that would read as two commands; taking the money and then being
    // unable to name the transaction is the failure this guard exists for.
    val payment = f.router.payForCard(card, payAction("a1", 10, "job 1"), CONTACT)
    assertEquals(PopopxCreditPayment.Failed(chat.popopx.common.eco.PopopxEcoPaymentFailure.MALFORMED_PAYLOAD), payment)
    assertTrue(credits.debits.isEmpty())
  }

  @Test
  fun anAmountOutsideTheLimitsIsRefusedWithoutTouchingTheLedger() = runBlocking<Unit> {
    val credits = FakeCredits(balance = 1_000_000)
    val f = Fixture(credits = credits)
    val card = f.store.rendered(card("card.pay", 3))
    for (amount in listOf(0, -5, PopopxEcoLimits.MAXIMUM_CREDIT_AMOUNT + 1)) {
      val payment = f.router.payForCard(card, payAction("a1", amount, "job"), CONTACT)
      assertTrue(payment is PopopxCreditPayment.Failed, amount.toString())
    }
    assertTrue(credits.debits.isEmpty())
  }

  @Test
  fun theLedgerNoteIsTheShownTitleRatherThanTheServersTargetString() = runBlocking<Unit> {
    val credits = FakeCredits(balance = 100, entryId = "tx.77")
    val f = Fixture(credits = credits)
    val card = f.store.rendered(card("card.pay", 3, title = "Render job"))
    val action = payAction("a1", 12, "job.1").copy(target = "an internal identifier nobody showed the user")

    val payment = f.router.payForCard(card, action, CONTACT)
    assertEquals(PopopxCreditPayment.Paid("tx.77", true), payment)
    assertEquals(listOf(12 to "Paid 12 POPOPX Compute Credits · Render job"), credits.debits)
    assertEquals(listOf(CONTACT to "::CB::job.1:paid_tx.77"), f.sender.sent)
  }

  /**
   * When the debit succeeded but the callback did not reach the peer the entry is KEPT and the hash is
   * returned anyway: the user paid, the ledger is the record, and a second tap on a locked button must not
   * charge them twice.
   */
  @Test
  fun aLostConfirmationDoesNotUndoThePayment() = runBlocking<Unit> {
    val credits = FakeCredits(balance = 100, entryId = "tx.9")
    val f = Fixture(credits = credits)
    f.sender.outcome = PopopxEcoSendOutcome.failed(PopopxEcoSendFailure.SEND_REFUSED)
    val card = f.store.rendered(card("card.pay", 3))
    val payment = f.router.payForCard(card, payAction("a1", 10, "job"), CONTACT)
    assertEquals(PopopxCreditPayment.Paid("tx.9", false), payment)
    assertEquals(90, credits.balance)
  }

  @Test
  fun aRefusedDebitPaysNothingAndSendsNothing() = runBlocking<Unit> {
    val credits = FakeCredits(balance = 100).apply { refused = true }
    val f = Fixture(credits = credits)
    val card = f.store.rendered(card("card.pay", 3))
    val payment = f.router.payForCard(card, payAction("a1", 10, "job"), CONTACT)
    assertTrue(payment is PopopxCreditPayment.Failed)
    assertTrue(credits.debits.isEmpty())
    assertTrue(f.sender.sent.isEmpty())
  }

  @Test
  fun aRouterWithoutALedgerDegradesInsteadOfInventingOne() = runBlocking<Unit> {
    val f = Fixture(credits = null)
    val card = f.store.rendered(card("card.pay", 3))
    val payment = f.router.payForCard(card, payAction("a1", 10, "job"), CONTACT)
    assertTrue(payment is PopopxCreditPayment.Failed)
  }

  @Test
  fun aTopUpRequestIsASingleSlotThatDrainsOnce() {
    val f = Fixture()
    f.router.requestCreditTopUp(required = 50, available = 20)
    assertEquals(PopopxEcoCreditRequest(50, 20), f.router.takeCreditTopUpRequest())
    assertNull(f.router.takeCreditTopUpRequest())
  }

  // MARK: - Action dispatch

  @Test
  fun theLockAndTheDeadlineGateBeforeAnythingIsSent() = runBlocking<Unit> {
    val f = Fixture()
    val live = card("card.gate", 3, actions = listOf(callbackAction("a1", "go")))
    f.store.apply(chat.popopx.common.eco.PopopxEcoFrame.ServiceCard(live), CONTACT)
    val stored = f.store.card("card.gate")!!
    val action = stored.actions.first()

    assertEquals(PopopxEcoActionResult.SENT_CALLBACK, PopopxEcoActionRunner.run(action, stored, CONTACT, f.router, f.store, nowMs = { 1L }))
    // The same card, the same button, a second tap: nothing goes out twice.
    assertEquals(PopopxEcoActionResult.LOCKED, PopopxEcoActionRunner.run(action, stored, CONTACT, f.router, f.store, nowMs = { 1L }))
    assertEquals(1, f.sender.sent.size)

    val deadCard = card("card.dead", 3, et = 10_000L, actions = listOf(callbackAction("a9", "go")))
    f.store.apply(chat.popopx.common.eco.PopopxEcoFrame.ServiceCard(f.store.rendered(deadCard)), CONTACT)
    val dead = f.store.card("card.dead")!!
    assertEquals(PopopxEcoActionResult.EXPIRED, PopopxEcoActionRunner.run(dead.actions.first(), dead, CONTACT, f.router, f.store, nowMs = { 11_000L }))
    assertEquals(1, f.sender.sent.size)
  }

  @Test
  fun aMenuOnlyKindOnACardButtonIsIgnoredNotFailed() = runBlocking<Unit> {
    val f = Fixture()
    val card = f.store.rendered(card("card.kinds", 3))
    for (kind in listOf(PopopxEcoAction.Kind.NONE, PopopxEcoAction.Kind.SEND_COMMAND)) {
      val action = PopopxEcoAction("x", "X", kind, PopopxEcoAction.Visual.PRIMARY, "p", null, null, null, false)
      assertEquals(PopopxEcoActionResult.IGNORED, PopopxEcoActionRunner.run(action, card, CONTACT, f.router, f.store, nowMs = { 1L }), kind.toString())
    }
    assertTrue(f.sender.sent.isEmpty())
  }

  @Test
  fun anOpenUrlNeedsAHttpUrlAndAPairwiseIdentity() = runBlocking<Unit> {
    val f = Fixture()
    val card = f.store.rendered(card("card.h5", 3))
    val javascript = PopopxEcoAction("j", "J", PopopxEcoAction.Kind.OPEN_URL, PopopxEcoAction.Visual.PRIMARY, null, "javascript:alert(1)", null, null, false)
    assertEquals(PopopxEcoActionResult.IGNORED, PopopxEcoActionRunner.run(javascript, card, CONTACT, f.router, f.store, nowMs = { 1L }))

    val https = javascript.copy(id = "u", url = "https://eco.test/pay")
    // Connected but never identified: the app's own definition of a service account is a completed handshake.
    assertEquals(PopopxEcoActionResult.NO_SESSION, PopopxEcoActionRunner.run(https, card, CONTACT, f.router, f.store, nowMs = { 1L }))

    f.store.apply(chat.popopx.common.eco.PopopxEcoFrame.SessionHandshake(handshake()), CONTACT)
    // A different `id`: the refused attempt already spent this button's lockout. iOS records the lock
    // before it looks the session up (`PopopxEcoRouterAndDeepLink.swift:773` against `:792`), so a retry of
    // the very same action is `.locked`, and reusing the id here would test the lock and not the launcher.
    val identified = https.copy(id = "u1")
    assertEquals(PopopxEcoActionResult.OPENED_H5, PopopxEcoActionRunner.run(identified, card, CONTACT, f.router, f.store, nowMs = { 1L }))
    // The launcher is a single slot, so a second open is refused rather than stacked.
    assertEquals(PopopxEcoActionResult.SEND_FAILED, PopopxEcoActionRunner.run(https.copy(id = "u2"), card, CONTACT, f.router, f.store, nowMs = { 1L }))
    f.router.takeChannelPageRequest()
  }

  @Test
  fun aChannelButtonOpensThePageOrOffersTheLinkForImport() = runBlocking<Unit> {
    val f = Fixture()
    val key = chat.popopx.common.crypto.base64UrlEncode(ByteArray(32) { 1 })
    val pub = chat.popopx.common.crypto.base64UrlEncode(ByteArray(32) { 2 })
    val link = "popopx://channel/smp1.popopx.test/chan.9#key=$key&pub=$pub"
    val action = PopopxEcoAction("c", "C", PopopxEcoAction.Kind.OPEN_CHANNEL, PopopxEcoAction.Visual.PRIMARY, link, null, null, null, false)
    val card = f.store.rendered(card("card.ch", 3))

    // Not a member: no key material for that channel id, so the list opens with the link prefilled — the
    // fragment is the read key and the import field is the only place a channel key enters this device.
    assertEquals(
      PopopxEcoActionResult.OPENED_CHANNEL,
      PopopxEcoActionRunner.run(action, card, CONTACT, f.router, f.store, nowMs = { 1L })
    )
    val request = f.router.takeChannelPageRequest()
    assertNotNull(request)
    assertNull(request.channelId)
    assertEquals(link, request.importURI)

    // Now imported, so the detail page opens and nothing is offered for import.
    assertTrue(f.rotation.importPublicURI(link))
    PopopxEcoActionRunner.run(action.copy(id = "c2"), card, CONTACT, f.router, f.store, nowMs = { 1L })
    val second = f.router.takeChannelPageRequest()!!
    assertEquals("chan.9", second.channelId)
    assertNull(second.importURI)

    // A payload that is not a channel URI is not this action's business.
    val junk = action.copy(id = "c3", payload = "not a uri")
    assertEquals(PopopxEcoActionResult.IGNORED, PopopxEcoActionRunner.run(junk, card, CONTACT, f.router, f.store, nowMs = { 1L }))
    assertNull(f.router.takeChannelPageRequest())
  }

  // MARK: - The deep-link string

  @Test
  fun theAddressSurvivesUnescapedBecauseTheParserLocatesNamesAtParameterBoundaries() {
    val address = "smp://relay1.popopx.test/AbCDeFg#key=abcdefgh&auth=ijklmnop"
    val service = PopopxEcoLink.parse("popopx://service?uri=$address&ref=art.42")
    assertNotNull(service)
    assertEquals(address, service.serviceURI)
    assertEquals("art.42", service.payload)
    assertEquals(PopopxEcoLink.Kind.SERVICE, service.kind)

    // Either order: the address is the whole span between the two anchors, separators included.
    val flipped = PopopxEcoLink.parse("popopx://sso?session=s-9&uri=$address")
    assertNotNull(flipped)
    assertEquals(address, flipped.serviceURI)
    assertEquals("s-9", flipped.payload)
    assertEquals(PopopxEcoLink.Kind.SSO, flipped.kind)

    // Percent-encoded by a well-behaved producer, it is an ordinary query parameter.
    val encoded = PopopxEcoLink.parse("popopx://service?uri=${"smp://h/c#key=a&auth=b".percent() }&ref=x")
    assertNotNull(encoded)
    assertEquals("smp://h/c#key=a&auth=b", encoded.serviceURI)
  }

  @Test
  fun AParameterInsideAnAddressIsNotReadAsAParameter() {
    // `xref=` sits inside the address value; only a name at the start or straight after a `&` counts, so the
    // article id must be `real`.
    val link = PopopxEcoLink.parse("popopx://service?uri=smp://h/c#key=a&xref=trap&auth=b&ref=real")
    assertNotNull(link)
    assertEquals("real", link.payload)
    assertEquals("smp://h/c#key=a&xref=trap&auth=b", link.serviceURI)
  }

  @Test
  fun aLinkMissingEitherHalfOrRepeatingOneIsNotAnEcoLink() {
    assertNull(PopopxEcoLink.parse("popopx://service?ref=a"))
    assertNull(PopopxEcoLink.parse("popopx://service?uri=smp://h/c"))
    assertNull(PopopxEcoLink.parse("popopx://service?uri=&ref=a"))
    assertNull(PopopxEcoLink.parse("popopx://service?uri=smp://h/c&uri=smp://h/d&ref=a"))
    assertNull(PopopxEcoLink.parse("popopx://service?uri=smp://h/c&ref=a&ref=b"))
    // A bare scheme without the `?` is not a claim, so the caller keeps handling the text.
    assertNull(PopopxEcoLink.parse("popopx://service"))
    assertNull(PopopxEcoLink.parse("popopx://invite?smp://h/c"))
    // The payload is the token `PopopxEcoUplink` requires: no whitespace, no second `::`, not empty.
    assertNull(PopopxEcoLink.parse("popopx://service?uri=smp://h/c&ref=a::b"))
    assertNull(PopopxEcoLink.parse("popopx://service?uri=smp://h/c&ref=a%20b"))
  }

  /**
   * The address is never interpreted here — it goes to the connection flow, which asks the core. What makes
   * it safe is that it must be ONE printable-ASCII token with none of the quoting or expansion
   * metacharacters: a space would split the argument and a newline does that AND ends the command.
   */
  @Test
  fun anAddressThatWouldBreakACommandLineIsRefused() {
    for (bad in listOf("smp://h/c#k=a b", "smp://h/c#k=\"quote", "smp://h/c#k='quote", "smp://h/c#k=`tick", "smp://h/c#k=a\\b", "smp://h/c#k=a\$b", "smp://h/c#k=a%0Ab", "smp://h/c#k=é")) {
      assertNull(PopopxEcoLink.parse("popopx://service?uri=$bad&ref=a"), bad)
    }
    // A `+` stays a `+`: the JVM's own decoder would turn it into a space, which is why this file decodes by
    // hand. A base64 key is full of them.
    val plus = PopopxEcoLink.parse("popopx://service?uri=smp://h/c#key=a+b%2Fc&ref=a")
    assertNotNull(plus)
    assertEquals("smp://h/c#key=a+b/c", plus.serviceURI)
    // A malformed escape is a broken link, not a literal percent.
    assertNull(PopopxEcoLink.parse("popopx://service?uri=smp://h/c%2zz&ref=a"))
    assertNull(PopopxEcoLink.parse("popopx://service?uri=smp://h/c%2&ref=a"))
  }

  @Test
  fun theWholeLinkIsBoundedAndSurroundingWhitespaceIsNotPartOfIt() {
    val padded = PopopxEcoLink.parse("  popopx://service?uri=smp://h/c&ref=a \n")
    assertNotNull(padded)
    assertEquals("smp://h/c", padded.serviceURI)
    val long = "popopx://service?uri=smp://h/" + "x".repeat(PopopxEcoLimits.MAXIMUM_URL_CHARACTERS) + "&ref=a"
    assertNull(PopopxEcoLink.parse(long))
  }

  // MARK: - Mount

  @Test
  fun anUnrelatedPasteReachesTheCallerAsUnhandledAndAnEcoLinkRecordsBeforeConnecting() = runBlocking<Unit> {
    val f = Fixture()
    val connects = ArrayList<String>()
    var cleanup: (() -> Unit)? = null
    var knownContact: (suspend (Long) -> Unit)? = null
    val opened = ArrayList<Long>()
    val handler = PopopxEcoDeepLinkHandler(
      f.router,
      connect = { uri, onCleanup, onKnown ->
        connects.add(uri)
        cleanup = onCleanup
        knownContact = onKnown
      },
      openKnownChat = { opened.add(it) },
      // The bind branch is decided by whether the host has a conversation row, which a test without a
      // ChatModel can only state.
      hasContactChat = { it == 4L },
      hasSession = { f.store.session(it) != null },
    )

    assertFalse(handler.handle("https://eco.test/x"))
    assertTrue(connects.isEmpty())

    assertTrue(handler.handle("popopx://sso?uri=smp://h/c&session=s-1"))
    assertEquals(listOf("smp://h/c"), connects)
    assertNotNull(f.router.pendingIntent)

    // The core reports the contact it already knew for this exact address: the intent becomes bound, and
    // because that contact has no eco session the intent is HELD for its handshake rather than sent blind.
    knownContact!!.invoke(4L)
    assertEquals(listOf(4L), opened)
    assertEquals(4L, f.router.pendingIntent?.boundContactId)
    assertTrue(f.sender.sent.isEmpty(), "an unidentified contact is not sent the scan line blind")

    // `cleanup` runs on cancel AND after a chat opened, so only the in-progress test separates them.
    f.inProgress = true
    cleanup!!.invoke()
    assertNotNull(f.router.pendingIntent)
    f.inProgress = false
  }

  /** A contact the core knows but with no conversation to send into: the intent is dropped, not held. */
  @Test
  fun aKnownContactWithNoChatRowLosesTheIntent() = runBlocking<Unit> {
    val f = Fixture()
    var knownContact: (suspend (Long) -> Unit)? = null
    val handler = PopopxEcoDeepLinkHandler(
      f.router,
      connect = { _, _, onKnown -> knownContact = onKnown },
      openKnownChat = { error("there is no chat row to open") },
      hasContactChat = { false },
      hasSession = { false },
    )
    assertTrue(handler.handle("popopx://service?uri=smp://h/c&ref=a-1"))
    assertNotNull(f.router.pendingIntent)
    knownContact!!.invoke(99L)
    assertNull(f.router.pendingIntent)
    assertTrue(f.sender.sent.isEmpty())
  }

  /**
   * The third branch: the peer already completed its handshake, so this device already knows it is a service
   * account, and the link is spent on the spot instead of waiting for a handshake that has happened.
   */
  @Test
  fun aContactThatAlreadyIdentifiedItselfIsSentTheLinkImmediately() = runBlocking<Unit> {
    val f = Fixture()
    var knownContact: (suspend (Long) -> Unit)? = null
    val opened = ArrayList<Long>()
    val handler = PopopxEcoDeepLinkHandler(
      f.router,
      connect = { _, _, onKnown -> knownContact = onKnown },
      openKnownChat = { opened.add(it) },
      hasContactChat = { it == 5L },
      hasSession = { f.store.session(it) != null },
    )
    f.router.observeIncoming(ChatType.Direct, 5L, 1L, ecoFrameText(HANDSHAKE_JSON))
    assertNotNull(f.store.session(5L))
    f.sender.sent.clear()

    assertTrue(handler.handle("popopx://service?uri=smp://h/c&ref=a-1"))
    knownContact!!.invoke(5L)
    assertEquals(listOf(5L), opened)
    assertEquals(listOf(5L to "::REF::a-1"), f.sender.sent)
    assertNull(f.router.pendingIntent, "a spent intent must not survive to authorize the next handshake")
  }

  private fun card(
    id: String,
    ut: Long,
    title: String = "T",
    et: Long? = null,
    actions: List<String>? = null,
  ): PopopxServiceCard {
    val json = buildString {
      append("""{"t":"sc","m":"c","card":{"id":"$id","v":"standard","title":"$title","ut":$ut""")
      if (et != null) append(""","et":$et""")
      if (actions != null) append(""","actions":[${actions.joinToString(",")}]""")
      append("}}")
    }
    return chat.popopx.common.eco.PopopxEcoMarker.parseControlText(ecoFrameText(json))
      .let { it as chat.popopx.common.eco.PopopxEcoFrame.ServiceCard }.card
  }

  private fun callbackAction(id: String, payload: String) =
    """{"id":"$id","title":"Go","m":"callback","payload":"$payload"}"""

  private fun payAction(id: String, amount: Int, payload: String): PopopxEcoAction =
    PopopxEcoAction(id, "Pay", PopopxEcoAction.Kind.PAY_CREDITS, PopopxEcoAction.Visual.PRIMARY, payload, null, null, null, false)
      .let { it.copy(amount = amount) }

  private fun handshake() = chat.popopx.common.eco.PopopxEcoSession(
    pairwiseUid = "popopx1abc",
    secretHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
    serviceId = null,
  )
}

private fun String.percent(): String = buildString {
  for (c in this@percent) {
    if (c in " &#/?=") append("%%%02X".format(c.code)) else append(c)
  }
}
