package chat.popopx.app.signal

import chat.popopx.common.signal.PopopxInboundVerdict
import chat.popopx.common.signal.PopopxRedemptionOutcome
import chat.popopx.common.signal.PopopxSignal
import chat.popopx.common.signal.PopopxSignalChatKind
import chat.popopx.common.signal.PopopxSignalDisposition
import chat.popopx.common.signal.PopopxSignalFailure
import chat.popopx.common.signal.PopopxSignalKind
import chat.popopx.common.signal.PopopxSignalLimits
import chat.popopx.common.signal.PopopxSignalTarget
import chat.popopx.common.signal.PopopxSilentDeleteMode
import chat.popopx.common.signal.PopopxSilentSignalingRouter
import chat.popopx.common.signal.PopopxSysMarker
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The router's sequences against PopopxSilentSignalingRouter.swift:126-180, 188-253, 257-309,
// 313-379, 387-414, 459-522, 544-652. Every claim is checked through the recording transport,
// because for a silent signal the only honest witness is the call it made.

private const val CLOCK = 1_700_000_000_000L

class PopopxSilentSignalingRouterTest {
  @Test
  fun aSignalGoesOutNeverLiveNeverTtlAndComesBackDeletedInternally() = runBlocking<Unit> {
    val transport = RecordingTransport()
    val gate = ScriptedGate()
    val router = PopopxSilentSignalingRouter(transport, gate, signalSettings(), nowMs = { CLOCK })

    assertTrue(router.sendRedPacketReceipt("packet-1", PopopxSignalTarget.Contact(9L)))
    assertEquals(
      listOf(RecordingTransport.Sent(9L, false, signalWire(PopopxSignalKind.REDPACKET_CLAIMED, "packet-1"), false, null)),
      transport.sent,
    )

    // The receipt landing back: consumed, then deleted with INTERNAL and nothing else
    // (router:694-721 — a broadcast delete would write the signalling back into the peer's timeline).
    router.observeIncoming(PopopxSignalChatKind.DIRECT, 9L, 31L, signalWire(PopopxSignalKind.REDPACKET_CLAIMED, "packet-1"))
    assertEquals(listOf(RecordingTransport.Deleted(9L, listOf(31L), PopopxSilentDeleteMode.INTERNAL)), transport.deleted)
    assertEquals(CLOCK, gate.inbounds.single().receivedAtMs)
  }

  @Test
  fun paidAtMsIsTheParseInstantNotAWireField() = runBlocking<Unit> {
    // The security-relevant fudge, pinned: the outbound wire carries THREE fields
    // (`{channelId}:{credits}:{txHash}`, Models:1365-1367) — the sender's own Date() (router:620)
    // is dropped by that encoder — and the timestamp the owner may record is THIS device's parse
    // instant, taken once from the injected clock (Models:1360).
    val transport = RecordingTransport()
    val gate = ScriptedGate()
    val router = PopopxSilentSignalingRouter(transport, gate, signalSettings(), nowMs = { CLOCK })

    router.sendChannelPaymentReceipt(42L, 10, "txhash-1", PopopxSignalTarget.Contact(5L))
    val wire = transport.sent.single().text
    assertEquals(signalWire(PopopxSignalKind.CHANNEL_PAY_RCPT, "42:10:txhash-1"), wire)
    assertTrue(!wire.contains(CLOCK.toString()), "the sender's clock must not leak into the frame")

    router.observeIncoming(PopopxSignalChatKind.DIRECT, 5L, 12L, wire)
    val inbound = gate.inbounds.last()
    assertEquals(CLOCK, inbound.receivedAtMs)
    assertEquals("42:10:txhash-1", inbound.signal.payload)

    // A later parse of the same frame is a LATER instant: the value is the receiver's now, never
    // something carried over. (Replay itself is the owner ledger's guard — commerce's txHash set.)
    var clock = CLOCK
    val router2 = PopopxSilentSignalingRouter(transport, gate, signalSettings(), nowMs = { clock })
    clock = CLOCK + 60_000L
    router2.observeIncoming(PopopxSignalChatKind.DIRECT, 5L, 13L, wire)
    assertEquals(CLOCK + 60_000L, gate.inbounds.last().receivedAtMs)
  }

  @Test
  fun theRouterRefusesEveryGroupSendThatIsNotOneOfTheThreeWithoutTouchingTheHost() = runBlocking<Unit> {
    val transport = RecordingTransport()
    val router = PopopxSilentSignalingRouter(transport, ScriptedGate(), signalSettings(), nowMs = { CLOCK })
    val group = PopopxSignalTarget.Group(3L)
    for (kind in PopopxSignalKind.entries.filter { !it.acceptedInGroup }) {
      assertTrue(!router.sendSignal(PopopxSignal(kind, "body"), group), "${kind.raw} must be refused")
    }
    assertTrue(transport.sent.isEmpty(), "a refused send must not reach the transport at all")
    // The whitelist still goes out.
    assertTrue(router.sendRedPacketReceipt("p", group))
    assertEquals(1, transport.sent.size)
  }

  @Test
  fun theOneTimeRoundTripSendsTheStoredWireThenDeletesRowThenDropsContact() = runBlocking<Unit> {
    val transport = RecordingTransport()
    val gate = ScriptedGate()
    val settings = signalSettings()
    val router = PopopxSilentSignalingRouter(transport, gate, settings, nowMs = { CLOCK })

    // Commerce decoded and verified the `PPX1-…` code; this layer takes the envelope's two facts.
    val outcome = router.startExternalRedeem("voucher-7", "popopx://invite/one-time-link")
    assertIs<PopopxRedemptionOutcome.Initiated>(outcome)
    assertEquals(listOf(true to "popopx://invite/one-time-link"), transport.connected.map { it.incognito to it.connFullLink })
    assertTrue(transport.sent.isEmpty(), "the REQ cannot go out before the peer accepts (router header:23-28)")

    router.contactConnected(88L, 500L)
    val req = transport.sent.single()
    // The replayed wire is byte-identical to what startExternalRedeem stored (router:762-767).
    assertEquals(signalWire(PopopxSignalKind.EXTERNAL_REDEEM_REQ, "voucher-7"), req.text)
    assertEquals(500L, req.chatId)
    assertTrue(!req.isGroup)
    assertEquals(false, req.live)
    assertNull(req.ttlSeconds)

    // The ACK arrives, commerce verified it and it names this device's voucher: delete the row,
    // THEN drop the one-time contact, never notifying (router:337-342, in that order).
    gate.disposition = {
      PopopxSignalDisposition.SettleAck("voucher-7", PopopxRedemptionOutcome.Completed("voucher-7"))
    }
    val verdict = router.observeIncoming(
      PopopxSignalChatKind.DIRECT, 500L, 61L, signalWire(PopopxSignalKind.EXTERNAL_REDEEM_ACK, "grant-b64url"),
    )
    val handled = assertIs<PopopxInboundVerdict.Handled>(verdict)
    assertTrue(handled.rowDeleted)
    assertTrue(handled.contactDeleted)
    assertEquals(listOf(RecordingTransport.Deleted(500L, listOf(61L), PopopxSilentDeleteMode.INTERNAL)), transport.deleted)
    assertEquals(listOf(RecordingTransport.ContactDeleted(500L, false)), transport.contactsDeleted)
    assertIs<PopopxRedemptionOutcome.Completed>(router.lastOutcome)
  }

  @Test
  fun anAckWithNoMatchingInitiationIsDroppedAndNotEvenDeleted() = runBlocking<Unit> {
    // Router:318-321: signature validity proves "someone signed", not "this badge is for you".
    // An unmatched ACK is dropped and deletes nothing — we do not clean up somebody else's timeline.
    val transport = RecordingTransport()
    val gate = ScriptedGate {
      PopopxSignalDisposition.SettleAck("voucher-OTHER", PopopxRedemptionOutcome.Completed("voucher-OTHER"))
    }
    val router = PopopxSilentSignalingRouter(transport, gate, signalSettings(), nowMs = { CLOCK })
    router.redeemInChat("voucher-OURS", 500L) // an initiation exists — just not for this voucher
    val verdict = router.observeIncoming(PopopxSignalChatKind.DIRECT, 500L, 61L, signalWire(PopopxSignalKind.EXTERNAL_REDEEM_ACK, "grant"))
    assertIs<PopopxInboundVerdict.AckWithoutInitiation>(verdict)
    assertTrue(transport.deleted.isEmpty(), "we do not clean up somebody else's timeline")
    assertTrue(transport.contactsDeleted.isEmpty())

    // The real entry survived the mismatch: the correctly-named ACK settles afterwards.
    gate.disposition = { PopopxSignalDisposition.SettleAck("voucher-OURS", PopopxRedemptionOutcome.Completed("voucher-OURS")) }
    val settle = router.observeIncoming(PopopxSignalChatKind.DIRECT, 500L, 61L, signalWire(PopopxSignalKind.CHAT_REDEEM_ACK, "grant"))
    assertIs<PopopxInboundVerdict.Handled>(settle)
    assertEquals(1, transport.deleted.size)
  }

  @Test
  fun inChatRedemptionNeverDeletesTheFriend() = runBlocking<Unit> {
    // router:143-145, :404, :411: the contact IS the friend; `deletesContactAfterAck` is false here.
    val transport = RecordingTransport()
    val gate = ScriptedGate { PopopxSignalDisposition.SettleAck("v1", PopopxRedemptionOutcome.Completed("v1")) }
    val router = PopopxSilentSignalingRouter(transport, gate, signalSettings(), nowMs = { CLOCK })

    assertIs<PopopxRedemptionOutcome.Initiated>(router.redeemInChat("v1", 77L))
    assertEquals(signalWire(PopopxSignalKind.CHAT_REDEEM_REQ, "v1"), transport.sent.single().text)
    router.observeIncoming(PopopxSignalChatKind.DIRECT, 77L, 9L, signalWire(PopopxSignalKind.CHAT_REDEEM_ACK, "grant"))
    assertTrue(transport.contactsDeleted.isEmpty())
    assertEquals(1, transport.deleted.size)
  }

  @Test
  fun aFailedSettleRecordsTheFailureAndDeletesNothing() = runBlocking<Unit> {
    // Router:323-326, :333-336, :370-373: a refusal returns before any deletion.
    val transport = RecordingTransport()
    val gate = ScriptedGate { PopopxSignalDisposition.SettleAck("v1", PopopxRedemptionOutcome.Failed(PopopxSignalFailure.SIGNAL_REJECTED)) }
    val router = PopopxSilentSignalingRouter(transport, gate, signalSettings(), nowMs = { CLOCK })
    router.redeemInChat("v1", 77L)
    val verdict = router.observeIncoming(PopopxSignalChatKind.DIRECT, 77L, 9L, signalWire(PopopxSignalKind.CHAT_REDEEM_ACK, "grant"))
    val handled = assertIs<PopopxInboundVerdict.Handled>(verdict)
    assertTrue(!handled.rowDeleted)
    assertTrue(transport.deleted.isEmpty())
    assertIs<PopopxRedemptionOutcome.Failed>(router.lastOutcome)
  }

  @Test
  fun anAnsweredRequestDeletesTheReqRowOnlyWhenTheAckWentOut() = runBlocking<Unit> {
    // Router:272-280, :304-308: an ACK that could not be sent leaves the REQ row alone — answering
    // "success" on an unencoded or undeliverable grant would let the peer credit an unsigned number.
    val transport = RecordingTransport()
    val ack = PopopxSignal(PopopxSignalKind.EXTERNAL_REDEEM_ACK, "grant-b64url")
    val gate = ScriptedGate { PopopxSignalDisposition.AnswerRequest(ack) }
    val router = PopopxSilentSignalingRouter(transport, gate, signalSettings(), nowMs = { CLOCK })

    transport.delivers = false
    val failed = router.observeIncoming(PopopxSignalChatKind.DIRECT, 11L, 4L, signalWire(PopopxSignalKind.EXTERNAL_REDEEM_REQ, "v9"))
    val h1 = assertIs<PopopxInboundVerdict.Handled>(failed)
    assertEquals(false, h1.ackDelivered)
    assertTrue(transport.deleted.isEmpty())

    transport.delivers = true
    val ok = router.observeIncoming(PopopxSignalChatKind.DIRECT, 11L, 5L, signalWire(PopopxSignalKind.EXTERNAL_REDEEM_REQ, "v9"))
    val h2 = assertIs<PopopxInboundVerdict.Handled>(ok)
    assertEquals(true, h2.ackDelivered)
    assertTrue(h2.rowDeleted)
    assertEquals(signalWire(PopopxSignalKind.EXTERNAL_REDEEM_ACK, "grant-b64url"), transport.sent.last().text)
  }

  @Test
  fun pairingIsAProbeToARealEngineNotTheDocumentedSystemPairAck() = runBlocking<Unit> {
    // Task item 6, ported as measured rather than as documented: the requirement names
    // `NODE_CMD::system::pair_ack`, but the host's parser rejects any serviceId outside its ten
    // engines (MacNodeModels.swift:127-128 via DiscoverCatalogModels.swift:30-33), so iOS emits
    // edge_compute_mesh::status with the pairing probe body
    // (DiscoverSubscriptionManager.swift:502-514).
    val transport = RecordingTransport()
    val router = PopopxSilentSignalingRouter(transport, ScriptedGate(), signalSettings(), nowMs = { CLOCK })
    assertTrue(router.sendPairingProbe(21L))
    val text = transport.sent.single().text
    assertEquals("::popopx_sys::NODE_CMD::edge_compute_mesh::status::{\"probe\":\"pairing\"}", text)
    assertTrue(!text.contains("pair_ack"), "the documented spelling is the one the host refuses")
    // And the frame survives its own round trip with the host's inner separators intact.
    val parsed = assertNotNull(PopopxSysMarker.parse(text))
    assertEquals(PopopxSignalKind.NODE_CMD, parsed.kind)
    assertEquals("edge_compute_mesh::status::{\"probe\":\"pairing\"}", parsed.payload)
  }

  @Test
  fun theUnboundGateRefusesPayloadsButStillPutsControlRowsInTheFloor() = runBlocking<Unit> {
    // The default gate's promise: accept nothing, record it, and still delete the rows iOS deletes
    // without consulting any signature. An ACK is the exception — with no verifier it cannot be
    // told apart from somebody else's, which is drop-without-deleting territory (router:314-321).
    val transport = RecordingTransport()
    val gate = chat.popopx.common.signal.PopopxSignalUnboundGate()
    val router = PopopxSilentSignalingRouter(transport, gate, signalSettings(), nowMs = { CLOCK })
    router.observeIncoming(PopopxSignalChatKind.DIRECT, 1L, 2L, signalWire(PopopxSignalKind.PROFILE_UNLOCKED, "prof"))
    assertEquals(1, transport.deleted.size)

    val verdict = router.observeIncoming(PopopxSignalChatKind.DIRECT, 1L, 3L, signalWire(PopopxSignalKind.CHAT_REDEEM_ACK, "grant"))
    assertIs<PopopxInboundVerdict.Dropped>(verdict)
    assertEquals(1, transport.deleted.size, "the ACK row must NOT have been deleted")
    assertEquals(2, gate.recorded.size, "both refusals were recorded, not silently swallowed")
  }

  @Test
  fun aPendingRequestWrittenBeforeTheCrashStillRunsOnceThePeerAccepts() = runBlocking<Unit> {
    val transport = RecordingTransport()
    val settings = signalSettings()
    val first = PopopxSilentSignalingRouter(transport, ScriptedGate(), settings, nowMs = { CLOCK })
    first.startExternalCreditRedeem("vc", "popopx://invite/link2")
    assertIs<PopopxRedemptionOutcome.Initiated>(first.lastOutcome)

    // A new process reads the table back; the credit-family wire replays intact.
    val second = PopopxSilentSignalingRouter(transport, ScriptedGate(), settings, nowMs = { CLOCK })
    second.contactConnected(88L, 640L)
    assertEquals(signalWire(PopopxSignalKind.CREDIT_EXT_REDEEM_REQ, "vc"), transport.sent.single().text)

    // And the entry is consumed: a second contactConnected for the same connection sends nothing.
    second.contactConnected(88L, 641L)
    assertEquals(1, transport.sent.size)
  }

  @Test
  fun theOutcomeTableCeilingCollapsesToStrayEntriesAndKeepsInflightOnes() = runBlocking<Unit> {
    // Router:131-137 measured, INCLUDING the bite of the filter: at the ceiling the table is
    // reduced to the vouchers that still have an entry awaiting an ACK, then the new record is
    // added. The failed legs record nothing (router:393, :410 return before `record`), so the legs
    // here are recorded initiations whose REQ has NOT gone out — none of them is in flight, the
    // filter empties the table every time it bites, and one row survives: the newest. That is what
    // iOS does, so that is what is pinned.
    val transport = RecordingTransport()
    val router = PopopxSilentSignalingRouter(transport, ScriptedGate(), signalSettings(), nowMs = { CLOCK })
    for (i in 1..65) {
      assertIs<PopopxRedemptionOutcome.Initiated>(router.startExternalRedeem("v$i", "popopx://invite/link$i"))
    }
    assertTrue(transport.sent.isEmpty(), "the REQ waits for contactConnected; nothing is in flight")
    assertEquals(1, router.outcomesByVoucher.size)
    assertTrue("v65" in router.outcomesByVoucher)
    assertTrue("v64" !in router.outcomesByVoucher, "the filter dropped every non-inflight entry, as iOS does")

    // The other half of the rule: an entry that IS awaiting an ACK must survive the ceiling.
    transport.connectionId = 900L
    router.startExternalRedeem("inflight-v", "popopx://invite/x") // pending under conn 900
    router.contactConnected(900L, 700L) // REQ out → awaitingAcks[700] names inflight-v
    for (i in 100..165) {
      router.startExternalRedeem("v$i", "popopx://invite/link$i") // grows the table past the cap
    }
    assertTrue("inflight-v" in router.outcomesByVoucher, "an in-flight voucher is never cleared (router:134-136)")
  }

  @Test
  fun aSendThatTheTransportRefusesRollsTheInflightEntryBack() = runBlocking<Unit> {
    // Router:174-178: the REQ for a pending one-time connection failed to go out — remove the
    // entry (otherwise a later, unrelated ACK would settle a request nobody sent) and say so.
    val transport = RecordingTransport()
    val gate = ScriptedGate()
    val router = PopopxSilentSignalingRouter(transport, gate, signalSettings(), nowMs = { CLOCK })
    router.startExternalRedeem("v1", "popopx://invite/link")
    transport.delivers = false
    router.contactConnected(88L, 300L)
    assertIs<PopopxRedemptionOutcome.Failed>(router.lastOutcome)

    // The rolled-back contact has no entry any more: an ACK that would otherwise settle it cleanly
    // is refused as "never requested", and its row is left alone.
    gate.disposition = { PopopxSignalDisposition.SettleAck("v1", PopopxRedemptionOutcome.Completed("v1")) }
    val verdict = router.observeIncoming(PopopxSignalChatKind.DIRECT, 300L, 5L, signalWire(PopopxSignalKind.EXTERNAL_REDEEM_ACK, "grant"))
    assertIs<PopopxInboundVerdict.AckWithoutInitiation>(verdict)
    assertTrue(transport.deleted.isEmpty())
  }

  @Test
  fun mintingAsksForIncognitoConnectionsAndSaysNothingAboutSignatures() = runBlocking<Unit> {
    // Router:419-426: every mint opens a FRESH one-time connection, incognito, because a link can
    // only be accepted once and reuse opens the double-spend window. Envelope and signature are
    // the commerce package's; this seam only hands the link and the connection id back.
    val transport = RecordingTransport()
    val router = PopopxSilentSignalingRouter(transport, ScriptedGate(), signalSettings(), nowMs = { CLOCK })
    val a = assertNotNull(router.createEphemeralInvite())
    val b = assertNotNull(router.createEphemeralInvite())
    assertEquals(listOf(true, true), transport.addContactIncognito)
    assertEquals("popopx://invite/one-time-link", a.connFullLink)
    assertEquals(88L, b.connId)
  }

  @Test
  fun hostileInboundTextNeverThrowsAndIsNamedByItsReason() = runBlocking<Unit> {
    val transport = RecordingTransport()
    val router = PopopxSilentSignalingRouter(transport, ScriptedGate(), signalSettings(), nowMs = { CLOCK })
    val hostile = listOf(
      "plain text",
      "look at this: ${PopopxSysMarker.MARKER}NODE_CMD::a::b",
      PopopxSysMarker.MARKER,
      "${PopopxSysMarker.MARKER}::",
      "${PopopxSysMarker.MARKER}NODE_CMD::",
      "${PopopxSysMarker.MARKER}NOT_A_KIND::body",
      signalWire(PopopxSignalKind.CHAT_REDEEM_REQ, "x".repeat(PopopxSignalLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS * 10)),
      "${PopopxSysMarker.MARKER}EXT_REDEEM_REQ:single-colon",
    )
    for (text in hostile) {
      val verdict = router.observeIncoming(PopopxSignalChatKind.DIRECT, 1L, 1L, text)
      assertIs<PopopxInboundVerdict.NotASignal>(verdict, "[$text]")
    }
    assertTrue(transport.deleted.isEmpty(), "nothing that failed the parse may touch a row")
    assertTrue(transport.sent.isEmpty())
  }

  @Test
  fun aGroupReceivesOnlyTheThreeKindsBeforeAnyPayloadIsDispatched() = runBlocking<Unit> {
    val transport = RecordingTransport()
    val gate = ScriptedGate()
    val router = PopopxSilentSignalingRouter(transport, gate, signalSettings(), nowMs = { CLOCK })
    for (kind in PopopxSignalKind.entries) {
      router.observeIncoming(PopopxSignalChatKind.GROUP, 4L, 5L, signalWire(kind, "body"))
    }
    assertEquals(3, gate.inbounds.size, "only the whitelist even reached the payload gate")
    val reached = gate.inbounds.map { it.signal.kind }.toSet()
    assertEquals(
      setOf(PopopxSignalKind.REDPACKET_CLAIMED, PopopxSignalKind.CHANNEL_SUB_ACK, PopopxSignalKind.CHANNEL_PAY_RCPT),
      reached,
    )
  }
}
