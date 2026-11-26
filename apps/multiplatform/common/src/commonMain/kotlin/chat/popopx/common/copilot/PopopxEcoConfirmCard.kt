package chat.popopx.common.copilot

import kotlin.math.max
import kotlin.math.min

/**
 * The gate between an assistant turn and the system calendar.
 *
 * 「先生成待确认卡片 → 用户点击确认后才写入系统日历」 is a rule about ordering, and an ordering rule
 * in a feature like this is only worth what its enforcement is worth, so the write is not a callback
 * the UI may choose to call: it is the return value of [confirm], and there is no other way to
 * obtain a [PopopxCalendarWrite]. A proposal that was never confirmed produces nothing at all.
 *
 * The second reason is the model. The bundled engine is a tool caller whose `validation.ungrounded`
 * flag exists because it sometimes proposes something the user did not say. Proposals are therefore
 * the only representation the engine has, and the person is the only thing that can turn one into a
 * calendar entry.
 */
class PopopxEcoConfirmGate {
  /**
   * A proposal waiting for the tap, with the moment it was made: a card left on screen while the
   * user went elsewhere must not confirm against a calendar that has since changed.
   */
  data class Pending(val id: Int, val proposal: PopopxEcoProposal, val proposedAtEpochMinutes: Long)

  private var sequence = 0
  private val pending = LinkedHashMap<Int, Pending>()

  val proposals: List<Pending> get() = pending.values.toList()

  fun propose(proposal: PopopxEcoProposal, nowEpochMinutes: Long): Pending {
    val item = Pending(++sequence, proposal, nowEpochMinutes)
    pending[item.id] = item
    return item
  }

  /** The tap. The proposal leaves the pending set with it, so a double tap cannot double-write. */
  fun confirm(id: Int, nowEpochMinutes: Long, expiresAfterMinutes: Int = DEFAULT_CONFIRM_WINDOW_MINUTES): PopopxCalendarWrite? {
    val item = pending.remove(id) ?: return null
    if (nowEpochMinutes - item.proposedAtEpochMinutes > expiresAfterMinutes) return null
    return item.proposal.write()
  }

  fun dismiss(id: Int) {
    pending.remove(id)
  }

  /** Backgrounding the app drops every outstanding card; returning to it is not a confirmation. */
  fun expireAll() {
    pending.clear()
  }

  companion object {
    /** How long a card may wait: long enough to read, short enough that it describes today. */
    const val DEFAULT_CONFIRM_WINDOW_MINUTES = 30
  }
}

/**
 * What the assistant is offering to do, and the only thing it can do to the calendar.
 *
 * Each proposal knows how to describe itself to the person and, once confirmed, how to be executed.
 * [description] is deliberately the user's own words for a new event and a reference for an existing
 * one: an existing event's title is not carried here, because the sanitizer dropped it and a card
 * that showed it would leak the calendar back into the assistant's output.
 */
sealed interface PopopxEcoProposal {
  /** The sentence on the card. */
  val description: String

  /** The change, for the platform layer to apply. Only reachable through the gate. */
  fun write(): PopopxCalendarWrite

  /** The times shown in the user's own calendar app, for the card's second line. */
  val whenText: String
}

/** Book a new event. The title is what the user said, not something the model invented. */
data class EcoCreateEvent(val title: String, val start: EcoDateTime, val end: EcoDateTime) : PopopxEcoProposal {
  override val description: String get() = title
  override val whenText: String get() = "${start.isoLocal()} – ${end.isoLocal()}"
  override fun write(): PopopxCalendarWrite =
    PopopxCalendarWrite.Insert(title = title, startEpochMinutes = start.epochMinutes, endEpochMinutes = end.epochMinutes)
}

/**
 * Move an existing event.
 *
 * [eventRef] is the store id the platform read for it, and it is the only way this proposal names
 * the event: the title, location, attendees and notes stayed inside the sanitizer, so the card says
 * "move the 15:00 event on Friday" rather than quoting the calendar back.
 */
data class EcoRescheduleEvent(val eventRef: String, val newStart: EcoDateTime, val durationMinutes: Int) : PopopxEcoProposal {
  override val description: String get() = "Move event $eventRef"
  override val whenText: String get() = newStart.isoLocal()
  override fun write(): PopopxCalendarWrite =
    PopopxCalendarWrite.Update(eventId = eventRef, newStartEpochMinutes = newStart.epochMinutes, durationMinutes = durationMinutes)
}

/** Delete an existing event. */
data class EcoCancelEvent(val eventRef: String) : PopopxEcoProposal {
  override val description: String get() = "Cancel event $eventRef"
  override val whenText: String get() = ""
  override fun write(): PopopxCalendarWrite = PopopxCalendarWrite.Delete(eventId = eventRef)
}

/**
 * A confirmed calendar change, in the only form the platform layer accepts.
 *
 * Note what is absent: there is no field for a note, a location, an attendee or a reminder, so the
 * assistant cannot reach any of them even by accident. `Insert` carries a title because it is the
 * title of the event being created, taken from the user's own message.
 */
sealed interface PopopxCalendarWrite {
  data class Insert(val title: String, val startEpochMinutes: Long, val endEpochMinutes: Long) : PopopxCalendarWrite
  data class Update(val eventId: String, val newStartEpochMinutes: Long, val durationMinutes: Int) : PopopxCalendarWrite
  data class Delete(val eventId: String) : PopopxCalendarWrite
}

/**
 * A card the UI can render, or the reason there is no card.
 *
 * The rejection is a value rather than a silent no-op because the user has to be told why the
 * assistant did nothing: 「日程标题缺失」 and 「日历里没有这条日程」 are different sentences, and only
 * the second one suggests trying again with the calendar app open.
 */
sealed interface PopopxEcoPlan {
  data class Card(val proposal: PopopxEcoProposal, val reason: String?) : PopopxEcoPlan

  /** The proposal collides with a busy interval, which the card then says out loud. */
  data class Conflict(val proposal: PopopxEcoProposal, val with: PopopxEcoBusySlot) : PopopxEcoPlan

  data class Reject(val reason: String) : PopopxEcoPlan

  /** Nothing to do: the turn asked a question rather than proposing a change. */
  data class Answer(val text: String) : PopopxEcoPlan
}

object PopopxEcoPlanner {
  /**
   * Turns a parsed call into a proposal. [busy] is what the sanitizer already returned, so the
   * planner can warn about a collision without ever reading an event itself.
   */
  fun plan(call: PopopxEcoCall, facts: PopopxEcoFacts, busy: List<PopopxEcoBusySlot> = emptyList()): PopopxEcoPlan {
    return when (call) {
      is EcoGetAvailability -> PopopxEcoPlan.Answer(freeText(facts, busy))

      is EcoProposeCreate -> {
        val normalized = call.normalized(facts)
        val title = normalized.title?.takeIf { it.isNotBlank() } ?: return PopopxEcoPlan.Reject("the proposal has no event title")
        val start = EcoDateTime.parse(normalized.start) ?: return PopopxEcoPlan.Reject("the proposal has no start time")
        val end = normalized.end?.let { EcoDateTime.parse(it) } ?: start.plusMinutes(facts.defaultEventMinutes)
        if (end.epochMinutes <= start.epochMinutes) return PopopxEcoPlan.Reject("the proposal ends before it starts")
        val proposal = EcoCreateEvent(title, start, end)
        val collision = busy.firstOrNull { it.startEpochMinutes < end.epochMinutes && start.epochMinutes < it.endEpochMinutes }
        if (collision == null) PopopxEcoPlan.Card(proposal, null) else PopopxEcoPlan.Conflict(proposal, collision)
      }

      is EcoProposeReschedule -> {
        val normalized = call.normalized(facts) ?: return PopopxEcoPlan.Reject("the new time is not a time")
        val start = EcoDateTime.parse(normalized.newStart) ?: return PopopxEcoPlan.Reject("the new time is not a time")
        val reference = normalized.eventRef.takeIf { it.isNotBlank() } ?: return PopopxEcoPlan.Reject("the proposal names no event")
        PopopxEcoPlan.Card(EcoRescheduleEvent(reference, start, facts.defaultEventMinutes), null)
      }

      is EcoProposeCancel -> {
        val reference = call.eventRef.takeIf { it.isNotBlank() } ?: return PopopxEcoPlan.Reject("the proposal names no event")
        PopopxEcoPlan.Card(EcoCancelEvent(reference), null)
      }

      is EcoDispatchTask -> PopopxEcoPlan.Reject("a compute task is not a calendar change")
    }
  }

  private fun freeText(facts: PopopxEcoFacts, busy: List<PopopxEcoBusySlot>): String {
    if (busy.isEmpty()) return "nothing is booked in the next ${facts.defaultWindowHours} hours"
    val free = ArrayList<String>(busy.size + 1)
    var cursor = facts.now.epochMinutes
    val horizon = cursor + facts.defaultWindowHours.toLong() * 60
    for (slot in busy) {
      if (slot.startEpochMinutes > cursor) free.add(span(cursor, min(slot.startEpochMinutes, horizon)))
      cursor = max(cursor, slot.endEpochMinutes)
    }
    if (cursor < horizon) free.add(span(cursor, horizon))
    return if (free.isEmpty()) "no free time in the next ${facts.defaultWindowHours} hours" else free.joinToString(", ")
  }

  private fun span(from: Long, to: Long): String =
    "${EcoDateTime.fromEpochMinutes(from).isoLocal()} – ${EcoDateTime.fromEpochMinutes(to).isoLocal()}"
}

/**
 * RFC 5545 for a confirmed proposal, so the user can save or share what the assistant booked instead
 * of only seeing it inside the app.
 *
 * The output is written with the CRLF the spec requires, not the platform's own line ending, because
 * `.ics` files are read by other vendors' software and a folded `\n` is not valid there. Long values
 * are folded at 75 octets with a leading space, and text is escaped the way the spec's `TEXT` rule
 * asks — backslash first, then semicolon and comma, then newline, in that order.
 */
object PopopxEcoICS {
  fun calendar(proposal: PopopxEcoProposal, stampEpochMinutes: Long, productId: String = "-//POPOPX//Copilot//EN"): String =
    buildString {
      emit("BEGIN:VCALENDAR")
      emit("VERSION:2.0")
      emit("PRODID:$productId")
      emit("CALSCALE:GREGORIAN")
      emit("METHOD:PUBLISH")
      emit("BEGIN:VEVENT")
      emit("UID:popopx-copilot-${proposal.toString().hashCode()}@popopx.im")
      emit("DTSTAMP:${stamp(stampEpochMinutes)}")
      when (proposal) {
        is EcoCreateEvent -> {
          emit("DTSTART:${local(proposal.start)}")
          emit("DTEND:${local(proposal.end)}")
        }

        is EcoRescheduleEvent -> {
          emit("DTSTART:${local(proposal.newStart)}")
          emit("DTEND:${local(proposal.newStart.plusMinutes(proposal.durationMinutes))}")
          emit("SEQUENCE:1")
        }

        is EcoCancelEvent -> Unit
      }
      emit("SUMMARY:${escape(proposal.description)}")
      if (proposal is EcoCancelEvent) emit("STATUS:CANCELLED")
      emit("END:VEVENT")
      emit("END:VCALENDAR")
    }

  private fun StringBuilder.emit(value: String) {
    // A content line is at most 75 octets; a continuation line begins with one space, so the first
    // chunk is 75 and every later chunk is 74. This app's text is ASCII in practice, so counting
    // characters is counting octets here.
    var rest = value
    var first = true
    while (rest.isNotEmpty()) {
      val width = if (first) LINE_LIMIT else LINE_LIMIT - 1
      val chunk = rest.take(width)
      rest = rest.drop(width)
      if (!first) append(' ')
      append(chunk).append(CRLF)
      first = false
    }
    if (value.isEmpty()) append(CRLF)
  }

  /**
   * `20261127T150000` — the times are the user's local ones, so no `Z` and no timezone is claimed. The
   * seconds are spelled even though they are always zero: RFC 5545's `DATE-TIME` is
   * `YYYYMMDDTHHMMSS`, and `20261127T1500` is a value no conforming reader parses, so a calendar built
   * by [PopopxEcoPlanner] would be rejected by the very client the card promised to feed.
   */
  private fun local(instant: EcoDateTime): String = instant.isoLocal().withSeconds().ics()

  private fun stamp(epochMinutes: Long): String =
    EcoDateTime.fromEpochMinutes(epochMinutes).isoLocal().withSeconds().ics() + "Z"

  /** [EcoDateTime.isoLocal] is 16 characters whenever the engine gave a clock without seconds. */
  private fun String.withSeconds(): String = if (length == 16) "$this:00" else this

  private fun String.ics(): String = replace("-", "").replace(":", "")

  private fun escape(value: String): String = value
    .replace("\\", "\\\\")
    .replace(";", "\\;")
    .replace(",", "\\,")
    .replace("\n", "\\n")

  private const val CRLF = "\r\n"
  private const val LINE_LIMIT = 75
}
