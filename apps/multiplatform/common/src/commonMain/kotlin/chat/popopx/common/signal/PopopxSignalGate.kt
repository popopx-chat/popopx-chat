package chat.popopx.common.signal

// Ported from apps/ios/Shared/Features/BadgeCredits/PopopxSilentSignalingRouter.swift:51-55, 190-193
// and PopopxBadgeCreditsModels.swift:1127-1133.
//
// Every rule here is a pure function of its inputs: no transport, no ChatModel, no coroutine — so
// the group gate is testable without any of them, which is the whole reason it is split out of the
// router instead of inlined at the call sites.

/** The typed refusals of the send gate. One variant per rule that exists, none invented at the call site. */
enum class PopopxSignalRefusalReason {
  /**
   * The only rule the send side has inside a group (Models:1131-1133, router:192 for the mirror on
   * the receive side): redemption legs would settle somebody else's pending entry, and a node
   * command in a group would push somebody's Mac around in front of an audience.
   */
  NOT_ACCEPTED_IN_GROUP,

  /** Router:589-592 — a threshold card is "the price the channel owner sets"; ordinary members cannot issue it. */
  CHANNEL_PUBLISH_REQUIRES_ACTIVE_ADMIN,
}

/** The send gate's answer for one kind into one target. */
sealed class PopopxSendDecision {
  data object Allowed : PopopxSendDecision()

  /** `kind` travels with the refusal so the ten refused kinds produce ten distinct outcomes. */
  data class Refused(val kind: PopopxSignalKind, val reason: PopopxSignalRefusalReason) : PopopxSendDecision()
}

/** The receive gate's answer. iOS `return`s silently here (router:190-193); this names what it returned. */
sealed class PopopxReceiveDecision {
  data class Allowed(val signal: PopopxSignal) : PopopxReceiveDecision()
  data object NotAConversation : PopopxReceiveDecision()
  data class RefusedInGroup(val kind: PopopxSignalKind) : PopopxReceiveDecision()
  data class NotASignal(val reason: PopopxSignalParseResult.NotSignal) : PopopxReceiveDecision()
}

object PopopxSilentSignalGate {
  /**
   * The group rule, enforced on the way OUT (task item 4). Inside a group only
   * `REDPACKET_CLAIMED`, `CHANNEL_SUB_ACK` and `CHANNEL_PAY_RCPT` may be sent; every other kind
   * comes back as `Refused` carrying its own kind and the reason.
   */
  fun allowSend(kind: PopopxSignalKind, target: PopopxSignalTarget): PopopxSendDecision =
    if (target.isGroup && !kind.acceptedInGroup) {
      PopopxSendDecision.Refused(kind, PopopxSignalRefusalReason.NOT_ACCEPTED_IN_GROUP)
    } else {
      PopopxSendDecision.Allowed
    }

  /**
   * The same whitelist on the way IN (router:192). Putting the criterion before the handler is so
   * that a signalling kind mis-delivered into a group is not even dispatched — on iOS it is not
   * even parsed a second time, because the frame already parsed here is dropped on the floor.
   */
  fun allowReceive(chatKind: PopopxSignalChatKind, text: String): PopopxReceiveDecision {
    if (chatKind == PopopxSignalChatKind.OTHER) return PopopxReceiveDecision.NotAConversation
    return when (val outcome = PopopxSysMarker.parseOutcome(text)) {
      is PopopxSignalParseResult.Parsed ->
        if (chatKind == PopopxSignalChatKind.GROUP && !outcome.signal.kind.acceptedInGroup) {
          PopopxReceiveDecision.RefusedInGroup(outcome.signal.kind)
        } else {
          PopopxReceiveDecision.Allowed(outcome.signal)
        }

      is PopopxSignalParseResult.NotSignal -> PopopxReceiveDecision.NotASignal(outcome)
    }
  }

  /**
   * The channel-threshold publish right, ported verbatim from the `GroupInfo` extension
   * (router:51-55): `isChannel && memberRole >= admin && memberCurrent`. The `memberCurrent` half
   * cannot be dropped — a demoted admin still holds the old conversation, and that branch must be
   * blocked too. Inputs are three booleans because this package must not read `ChatModel`; the app
   * layer computes them from `GroupInfo.membership` exactly as Swift does.
   */
  fun mayPublishChannelThreshold(isChannel: Boolean, memberRoleAtLeastAdmin: Boolean, memberCurrent: Boolean): Boolean =
    isChannel && memberRoleAtLeastAdmin && memberCurrent

  /** The publish guard as a typed decision, so the refusal the router:590-592 logs has a name. */
  fun allowChannelThresholdPublish(isChannel: Boolean, memberRoleAtLeastAdmin: Boolean, memberCurrent: Boolean): PopopxPublishDecision =
    if (mayPublishChannelThreshold(isChannel, memberRoleAtLeastAdmin, memberCurrent)) {
      PopopxPublishDecision.Allowed
    } else {
      PopopxPublishDecision.Refused(PopopxSignalRefusalReason.CHANNEL_PUBLISH_REQUIRES_ACTIVE_ADMIN)
    }
}

sealed class PopopxPublishDecision {
  data object Allowed : PopopxPublishDecision()
  data class Refused(val reason: PopopxSignalRefusalReason) : PopopxPublishDecision()
}
