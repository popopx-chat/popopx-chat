package chat.popopx.common.cfgsec

// The decision half of the signed cluster configuration, ported from
// apps/ios/Shared/Features/ServerConfigSync/PopopxServerConfigSignalHandler.swift:55-248.
//
// Split from the effectful half on purpose: iOS makes `decide` and `classify` `nonisolated static` for the same
// reason, and states it outright — the app cannot sign, so a test target cannot reach the decision through a real
// frame. Keeping the arithmetic free of the store, the chat model and the core is what makes every branch of the
// anti-downgrade rule provable without the production key.

/** What this device already knows, as data rather than as a call into the store. */
class PopopxServerConfigDecisionState(
  /** Per signing key, the highest generation this device has acted on. */
  val floors: Map<String, Long> = emptyMap(),
  /** Generations applied and then rolled back, spelled `kid|seq`. The breaker suppresses exactly those and
   * nothing newer, so a corrected generation from the same key still lands. */
  val broken: List<String> = emptyList(),
) {
  /** A key the device has never heard of starts at zero, which is what admits its first generation. */
  fun floor(kid: String): Long = floors[kid] ?: 0L

  fun isBroken(kid: String, seq: Long): Boolean = broken.contains("$kid|$seq")

  companion object {
    /** The persisted state, read once so the decision itself stays free of storage. */
    fun current(store: PopopxServerConfigStore = PopopxServerConfigStore.shared): PopopxServerConfigDecisionState =
      PopopxServerConfigDecisionState(
        floors = store.floors.associate { it.kid to it.seq },
        broken = store.brokenEntries,
      )
  }
}

/** The conversation a frame arrived in, and where a receipt for it would have to go. */
class PopopxServerConfigSource(val chatType: PopopxServerConfigSourceChat, val chatApiId: Long) {
  /**
   * A receipt can only be addressed to the operator, and the operator's side of this product is a one-to-one
   * chat. Everything else — a group, a broadcast channel, a sender this device does not have in its contact
   * list — receives nothing.
   */
  val maySendReceipt: Boolean get() = chatType == PopopxServerConfigSourceChat.DIRECT
}

/** What one probe look concluded about the introduced cluster. */
enum class PopopxServerConfigProbeVerdict {
  REACHABLE,
  UNREACHABLE,

  /** Silence, not failure. Never a reason to roll back. */
  INCONCLUSIVE,
}

/** What the device does with a line that looked like a configuration frame. */
sealed class PopopxServerConfigDecision {
  /** Failed a check. The reason is logged, never sent to the sender or shown in the interface. */
  class Refused(val reason: PopopxServerConfigRejection) : PopopxServerConfigDecision()

  /**
   * Verified, but not actionable: a generation the device will not act on, or one whose roster has just been
   * rolled back. Still carries the frame, because the revocation floor it contains must be honoured and a
   * receipt may still be owed.
   */
  class Stale(val frame: PopopxServerConfigFrame) : PopopxServerConfigDecision()

  /** Verified, unexpired, newer than the floor for its key, and ready to be installed. */
  class Ready(val frame: PopopxServerConfigFrame) : PopopxServerConfigDecision()

  val frameOrNull: PopopxServerConfigFrame? get() = (this as? Stale)?.frame ?: (this as? Ready)?.frame
}

object PopopxServerConfigDecisionEngine {
  /**
   * Verification, revocation and floor, decided apart from every side effect.
   *
   * The floor the comparison uses is not simply the stored one: a frame's own `pol.ms` voids every generation
   * below it, which is how the operator keeps a device that already moved forward from sliding back to an older
   * cluster. Reading the frame first and the store second is what makes that possible without a second pass.
   */
  fun decide(text: String, now: Long, state: PopopxServerConfigDecisionState): PopopxServerConfigDecision =
    when (val decoded = PopopxServerConfigWire.decodeConfigFrame(text, now)) {
      is PopopxServerConfigDecode.Refused -> PopopxServerConfigDecision.Refused(decoded.reason)
      is PopopxServerConfigDecode.Accepted -> classify(decoded.frame, state)
    }

  /**
   * The same decision over a frame that has already verified, split out because the app cannot sign: no test
   * target can reach `decide` past the signature, so the arithmetic below would otherwise be provable only on
   * a device holding the production key.
   *
   * The floor is `max(stored, ms - 1)`: a revocation may only raise the baseline this key has already left
   * behind, never lower it. The `min` reading made a withdrawal of generation 9 deliverable to a device that had
   * moved to 12, and with the shipped `min_seq: 1` it drove every comparison to zero, so any still-unexpired
   * older generation could be replayed back onto the device by whoever holds the signing key. The corrected
   * cluster a withdrawal is followed by always carries a higher generation, so nothing the operator has to be
   * able to do depends on that downward move.
   */
  fun classify(frame: PopopxServerConfigFrame, state: PopopxServerConfigDecisionState): PopopxServerConfigDecision {
    val payload = frame.payload
    val effectiveFloor = effectiveFloor(payload.keyId, payload.policy.minSeq, state)
    return if (payload.seq > effectiveFloor && !state.isBroken(payload.keyId, payload.seq)) {
      PopopxServerConfigDecision.Ready(frame)
    } else {
      PopopxServerConfigDecision.Stale(frame)
    }
  }

  fun effectiveFloor(kid: String, minSeq: Long, state: PopopxServerConfigDecisionState): Long =
    maxOf(state.floor(kid), maxOf(minSeq - 1, 0L))

  /**
   * Whether this frame obliges the device to send a receipt, in the conversation it arrived in.
   *
   * Both halves are required and both belong to this single question rather than to each of the four places a
   * receipt is owed: the operator asked for acknowledgements, and the frame came from a one-to-one with the
   * config bot. A group or a broadcast channel never qualifies — that is stated once instead of four times,
   * where four chances to drift is four ways for an acknowledgements storm to come back.
   */
  fun owesReceipt(policy: PopopxServerConfigPolicy, source: PopopxServerConfigSource): Boolean =
    policy.ack && source.maySendReceipt
}
