package chat.popopx.common.copilot

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The calendar the assistant is allowed to see, as an interface the platform implements.
 *
 * It is deliberately [PopopxRawCalendarEvent]-shaped rather than "give me free slots", because the
 * privacy rule needs a single place where titles, locations, attendees and notes exist: the events
 * come out of here, go through [PopopxCalendarPrivacy.busySlots], and the result is the only thing
 * the assistant keeps. A platform that returned busy slots directly would be a nicer API and a worse
 * guarantee.
 */
interface PopopxEcoCalendarAccess {
  /** The raw rows of the window, from EventKit or CalendarContract. */
  suspend fun rawEvents(windowStartEpochMinutes: Long, windowEndEpochMinutes: Long): List<PopopxRawCalendarEvent>

  /**
   * The store id of the event the user's words point at, or null when nothing matches. Ids are the
   * only handle a write may use, so an unresolved reference means no card rather than a wrong write.
   */
  suspend fun resolveEventId(words: String, windowStartEpochMinutes: Long, windowEndEpochMinutes: Long): String?

  /** Apply a confirmed change. The platform must refuse when [write] did not come from the gate. */
  suspend fun apply(write: PopopxCalendarWrite): Boolean

  /** Whether the OS has granted the calendar permissions right now; false means the user is asked. */
  fun permissionsGranted(): Boolean
}

/** What one assistant turn produced. */
data class PopopxEcoReply(
  /** The sentence shown in the private bar; null when the turn produced only a card. */
  val text: String?,
  /** Proposals waiting for the tap, empty for a turn that asked for nothing. */
  val proposals: List<PopopxEcoProposal> = emptyList(),
  /** True when the bundled engine could not be loaded and the deterministic engine answered. */
  val usedFallback: Boolean = false,
)

/**
 * The turn: read the calendar, drop it, plan, and hand back a card.
 *
 * The mutex exists because a turn queries a live calendar store. Two overlapping turns — a summon
 * while a real-time message arrives — would otherwise plan against two different snapshots, and the
 * user would see a card whose free slot had already been filled by the other turn's confirmation.
 * A turn is milliseconds of in-memory work plus one query, so serializing them costs nothing the
 * user can feel.
 */
class PopopxEcoAssistant(
  private val state: PopopxEcoAssistantState,
  private val calendar: PopopxEcoCalendarAccess,
  private val preferences: () -> PopopxTimePreferences = { PopopxTimePreferences.DEFAULT },
) {
  private val gate = PopopxEcoConfirmGate()
  private val turnLock = Mutex()

  val pendingProposals: List<PopopxEcoConfirmGate.Pending> get() = gate.proposals

  /** The confirm tap; the write is what the platform applies, and null means there was nothing to apply. */
  suspend fun confirm(id: Int): Boolean = turnLock.withLock {
    val facts = PopopxEcoFacts.now()
    val write = gate.confirm(id, facts.now.epochMinutes) ?: return@withLock false
    calendar.apply(write)
  }

  fun dismiss(id: Int) = gate.dismiss(id)

  /**
   * One turn of the assistant.
   *
   * [PopopxCalendarPrivacy.busySlots] is called once, immediately, and its input is an expression
   * that is never named — after that line nothing in this class can reach a title, a location, an
   * attendee or a note again, because the only value kept is the list of numbers.
   */
  suspend fun onMessage(text: String, history: List<String>): PopopxEcoReply = turnLock.withLock {
    val facts = PopopxEcoFacts.now()
    val windowStart = facts.now.epochMinutes
    val windowEnd = windowStart + facts.defaultWindowHours.toLong() * PopopxTimePreferences.DAY_MINUTES
    val loaded = state.ensureEngineLoaded()
    val envelope = state.engine.parse(state.contextWindow(history, text).joinToString("\n"), facts)

    val busy = PopopxCalendarPrivacy.busySlots(calendar.rawEvents(windowStart, windowEnd), windowStart, windowEnd)

    var answer: String? = null
    val proposals = ArrayList<PopopxEcoProposal>()
    for (call in envelope.suggestions()) {
      when (val plan = PopopxEcoPlanner.plan(call, facts, busy)) {
        is PopopxEcoPlan.Answer -> answer = plan.text
        is PopopxEcoPlan.Reject -> Unit
        is PopopxEcoPlan.Card -> proposals.add(plan.proposal.withResolvedRef(calendar, windowStart, windowEnd) ?: continue)
        is PopopxEcoPlan.Conflict -> proposals.add(plan.proposal.withResolvedRef(calendar, windowStart, windowEnd) ?: continue)
      }
    }
    proposals.forEach { gate.propose(it, facts.now.epochMinutes) }

    PopopxEcoReply(
      text = answer ?: if (proposals.isEmpty() && !envelope.isEmpty) envelope.reasoning else null,
      proposals = proposals,
      usedFallback = !loaded || state.engine.kind == PopopxEdgeCopilotEngine.Kind.Deterministic,
    )
  }

  /** Called by the platform when the app leaves the foreground. */
  fun enteredBackground() {
    state.enteredBackground()
    gate.expireAll()
  }

  /** The two opt-ins the user can see; nothing else in the app may call this. */
  fun observe(sessionId: String, mode: PopopxEcoObserverMode) {
    when (mode) {
      PopopxEcoObserverMode.OFF -> state.stopRealtime()
      PopopxEcoObserverMode.SUMMON_LAST_MESSAGES -> state.summon(sessionId)
      PopopxEcoObserverMode.REALTIME_SESSION -> state.toggleRealtime(sessionId)
    }
  }

  val liveIndicatorVisible: Boolean get() = state.showsLiveIndicator

  fun permissionsNeeded(): Boolean = !calendar.permissionsGranted()

  private suspend fun PopopxEcoProposal.withResolvedRef(
    calendar: PopopxEcoCalendarAccess,
    windowStart: Long,
    windowEnd: Long,
  ): PopopxEcoProposal? = when (this) {
    is EcoRescheduleEvent -> calendar.resolveEventId(eventRef, windowStart, windowEnd)?.let { copy(eventRef = it) }
    is EcoCancelEvent -> calendar.resolveEventId(eventRef, windowStart, windowEnd)?.let { copy(eventRef = it) }
    else -> this
  }
}
