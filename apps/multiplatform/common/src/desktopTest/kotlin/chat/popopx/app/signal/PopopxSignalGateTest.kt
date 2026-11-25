package chat.popopx.app.signal

import chat.popopx.common.signal.PopopxPublishDecision
import chat.popopx.common.signal.PopopxReceiveDecision
import chat.popopx.common.signal.PopopxSendDecision
import chat.popopx.common.signal.PopopxSignalChatKind
import chat.popopx.common.signal.PopopxSignalKind
import chat.popopx.common.signal.PopopxSignalRefusalReason
import chat.popopx.common.signal.PopopxSignalTarget
import chat.popopx.common.signal.PopopxSilentSignalGate
import chat.popopx.common.signal.PopopxSysMarker
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

// The group rule as a pure function, against PopopxSilentSignalingRouter.swift:190-193 and
// PopopxBadgeCreditsModels.swift:1127-1133 — no transport, no model, no coroutine.

class PopopxSignalGateTest {
  private val whitelist = setOf(
    PopopxSignalKind.REDPACKET_CLAIMED,
    PopopxSignalKind.CHANNEL_SUB_ACK,
    PopopxSignalKind.CHANNEL_PAY_RCPT,
  )

  @Test
  fun aGroupMayCarryExactlyThreeKinds() {
    for (kind in PopopxSignalKind.entries) {
      val decision = PopopxSilentSignalGate.allowSend(kind, PopopxSignalTarget.Group(42L))
      if (kind in whitelist) {
        assertIs<PopopxSendDecision.Allowed>(decision, "${kind.raw} is a whitelisted group kind")
      } else {
        val refused = assertIs<PopopxSendDecision.Refused>(decision, "${kind.raw} must be refused in a group")
        // Distinct refusals: the decision names the kind it refused, so ten refusals are ten
        // different values, not one anonymous "no".
        assertEquals(kind, refused.kind)
        assertEquals(PopopxSignalRefusalReason.NOT_ACCEPTED_IN_GROUP, refused.reason)
      }
    }
    assertEquals(10, PopopxSignalKind.entries.count { !it.acceptedInGroup })
    assertEquals(3, whitelist.size)
  }

  @Test
  fun aDirectChatMaySendEveryKind() {
    for (kind in PopopxSignalKind.entries) {
      assertIs<PopopxSendDecision.Allowed>(
        PopopxSilentSignalGate.allowSend(kind, PopopxSignalTarget.Contact(7L)),
        "direct may send ${kind.raw}",
      )
    }
  }

  @Test
  fun theReceiveSideRefusesTheSameTenBeforeDispatch() {
    // Router:192 — mis-delivered kinds are dropped before their payload is ever dispatched.
    for (kind in PopopxSignalKind.entries) {
      val text = signalWire(kind, "body")
      val decision = PopopxSilentSignalGate.allowReceive(PopopxSignalChatKind.GROUP, text)
      if (kind in whitelist) {
        val allowed = assertIs<PopopxReceiveDecision.Allowed>(decision)
        assertEquals(kind, allowed.signal.kind)
      } else {
        val refused = assertIs<PopopxReceiveDecision.RefusedInGroup>(decision)
        assertEquals(kind, refused.kind)
      }
    }
  }

  @Test
  fun conversationsWithoutACounterpartAreNotConsideredAtAll() {
    // Router:190 — notes, contact requests, channels: there is no "person on the other side".
    val text = signalWire(PopopxSignalKind.REDPACKET_CLAIMED, "p1")
    assertIs<PopopxReceiveDecision.NotAConversation>(
      PopopxSilentSignalGate.allowReceive(PopopxSignalChatKind.OTHER, text),
    )
  }

  @Test
  fun hostileTextReachesTheHandlerAsItsNamedRejection() {
    val cases = listOf(
      "just prose",
      PopopxSysMarker.MARKER,
      signalWire(PopopxSignalKind.NODE_CMD, ""),
    )
    for (text in cases) {
      val decision = PopopxSilentSignalGate.allowReceive(PopopxSignalChatKind.DIRECT, text)
      assertIs<PopopxReceiveDecision.NotASignal>(decision, "[$text] must not dispatch")
    }
    // Sanity in the other direction, so the three rejections above are not an always-no gate.
    assertIs<PopopxReceiveDecision.Allowed>(
      PopopxSilentSignalGate.allowReceive(PopopxSignalChatKind.DIRECT, signalWire(PopopxSignalKind.REDPACKET_CLAIMED, "p")),
    )
  }

  @Test
  fun theChannelPublishRightIsAllThreeHalves() {
    // Router:51-55: isChannel && memberRole >= admin && memberCurrent. Every single-false row is a
    // refusal; the demoted-admin row (router:48-49) is the one that must not be dropped.
    assertTrue(PopopxSilentSignalGate.mayPublishChannelThreshold(true, true, true))
    assertFalse(PopopxSilentSignalGate.mayPublishChannelThreshold(false, true, true))
    assertFalse(PopopxSilentSignalGate.mayPublishChannelThreshold(true, false, true))
    assertFalse(PopopxSilentSignalGate.mayPublishChannelThreshold(true, true, false))
    val refused = assertIs<PopopxPublishDecision.Refused>(
      PopopxSilentSignalGate.allowChannelThresholdPublish(true, true, false),
    )
    assertEquals(PopopxSignalRefusalReason.CHANNEL_PUBLISH_REQUIRES_ACTIVE_ADMIN, refused.reason)
    assertIs<PopopxPublishDecision.Allowed>(PopopxSilentSignalGate.allowChannelThresholdPublish(true, true, true))
  }
}
