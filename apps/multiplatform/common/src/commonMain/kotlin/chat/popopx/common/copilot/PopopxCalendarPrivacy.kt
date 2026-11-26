package chat.popopx.common.copilot

import kotlin.math.max
import kotlin.math.min

/**
 * An event exactly as the system calendar store hands it over: the platform layer reads the raw
 * row, and this type is the only thing in the app that carries a title, a location, an attendee or
 * a note.
 *
 * The assistant's privacy rule is that nothing but the two times ever leaves [PopopxCalendarPrivacy],
 * and what it returns holds no String at all. That makes 「计算完 Free/Busy 空闲时段后立即丢弃事件标题、
 * 地点、参会人与备注」 a shape the compiler enforces rather than a promise in a comment: to leak, the
 * sanitizer would have to convert a string into a number.
 */
data class PopopxRawCalendarEvent(
  val startEpochMinutes: Long,
  val endEpochMinutes: Long,
  val title: String = "",
  val location: String = "",
  val attendees: List<String> = emptyList(),
  val notes: String = "",
)

/** A busy or free interval, minutes since the epoch, UTC. */
data class PopopxEcoBusySlot(val startEpochMinutes: Long, val endEpochMinutes: Long) {
  val durationMinutes: Int get() = max(0, (endEpochMinutes - startEpochMinutes).toInt())

  fun contains(instant: EcoDateTime): Boolean =
    instant.epochMinutes >= startEpochMinutes && instant.epochMinutes < endEpochMinutes

  fun toLocalRange(): Pair<EcoDateTime, EcoDateTime> =
    EcoDateTime.fromEpochMinutes(startEpochMinutes) to EcoDateTime.fromEpochMinutes(endEpochMinutes)

  companion object {
    fun between(start: EcoDateTime, minutes: Int): PopopxEcoBusySlot =
      PopopxEcoBusySlot(start.epochMinutes, start.epochMinutes + minutes)
  }
}

/** What the user has said about when they are willing to be booked. */
data class PopopxTimePreferences(
  /** Local minute-of-day ranges; an empty list means "any hour", which is the onboarding default. */
  val workingMinutes: List<MinuteRange> = emptyList(),
  val lunch: MinuteRange? = null,
  val avoidWeekends: Boolean = false,
  /**
   * Kept free on either side of a new event. Applied by widening the busy set rather than by
   * shrinking candidates, so a buffer also protects the time around events already in the calendar.
   */
  val bufferMinutes: Int = 0,
  val minimumSlotMinutes: Int = 15,
) {
  data class MinuteRange(val startMinute: Int, val endMinute: Int) {
    val valid: Boolean get() = endMinute != startMinute

    /** A range that wraps midnight (a night shift) holds the hours at either end of the day. */
    fun covers(minutesPastMidnight: Int): Boolean =
      if (endMinute >= startMinute) {
        minutesPastMidnight in startMinute until endMinute
      } else {
        minutesPastMidnight >= startMinute || minutesPastMidnight < endMinute
      }

    fun clamp(start: Long, end: Long, dayStart: Long): Pair<Long, Long>? {
      val from = max(start, dayStart + startMinute)
      val to = min(end, dayStart + (if (endMinute >= startMinute) endMinute.toLong() else DAY_MINUTES.toLong()))
      return if (to > from) from to to else null
    }
  }

  /**
   * The permitted intervals of `[windowStart, windowEnd)`: working hours minus lunch, day by day,
   * clipped and sorted. A wrapping working range (a night shift) becomes two segments of the day
   * grid, because the thing being asked is "which minutes are bookable", not "which ranges exist".
   */
  fun allowedRanges(windowStart: Long, windowEnd: Long): List<PopopxEcoBusySlot> {
    val out = ArrayList<PopopxEcoBusySlot>()
    val ranges = if (workingMinutes.isEmpty()) listOf(MinuteRange(0, 24 * 60)) else workingMinutes
    var day = windowStart.floorDiv(DAY_MINUTES)
    while (day * DAY_MINUTES < windowEnd) {
      val dayStart = day * DAY_MINUTES
      if (!avoidWeekends || EcoDate.fromEpochDays(day).dayOfWeek <= 5) {
        for (range in ranges.filter { it.valid }) {
          val segments = if (range.endMinute >= range.startMinute) {
            listOf(dayStart + range.startMinute to dayStart + range.endMinute)
          } else {
            listOf(dayStart + range.startMinute to dayStart + DAY_MINUTES, dayStart to dayStart + range.endMinute)
          }
          for (segment in segments) {
            val from = max(segment.first, windowStart)
            val to = min(segment.second, windowEnd)
            if (to > from) out.addAll(subtractLunch(from, to, dayStart))
          }
        }
      }
      day++
    }
    return out.sortedWith(compareBy({ it.startEpochMinutes }, { it.endEpochMinutes }))
  }

  private fun subtractLunch(from: Long, to: Long, dayStart: Long): List<PopopxEcoBusySlot> {
    // A wrapping LUNCH is not a thing, so unlike [MinuteRange.valid] this asks for order, not emptiness:
    // a range that ends before it starts would cut the wrong minutes out of the day.
    val lunch = this.lunch?.takeIf { it.endMinute > it.startMinute } ?: return listOf(PopopxEcoBusySlot(from, to))
    val cutStart = max(from, dayStart + lunch.startMinute)
    val cutEnd = min(to, dayStart + lunch.endMinute)
    if (cutEnd <= cutStart) return listOf(PopopxEcoBusySlot(from, to))
    return listOfNotNull(
      if (from < cutStart) PopopxEcoBusySlot(from, cutStart) else null,
      if (cutEnd < to) PopopxEcoBusySlot(cutEnd, to) else null,
    )
  }

  /** True when the slot fits entirely inside one permitted interval and is long enough to offer. */
  fun allows(slot: PopopxEcoBusySlot, windowStart: Long, windowEnd: Long): Boolean =
    slot.durationMinutes >= minimumSlotMinutes &&
      allowedRanges(windowStart, windowEnd).any {
        it.startEpochMinutes <= slot.startEpochMinutes && slot.endEpochMinutes <= it.endEpochMinutes
      }

  companion object {
    const val DAY_MINUTES = 24L * 60

    /** The defaults 「本地时间偏好」 starts with before the user has said anything. */
    val DEFAULT = PopopxTimePreferences(
      workingMinutes = listOf(MinuteRange(9 * 60, 18 * 60)),
      lunch = MinuteRange(12 * 60, 13 * 60),
      avoidWeekends = false,
      bufferMinutes = 0,
      minimumSlotMinutes = 15,
    )
  }
}

/**
 * Free/busy computation, and the only place raw calendar events are read.
 *
 * Every function here takes events and returns numbers. Nothing in the returned types can hold a
 * word, so the desensitisation is structural: the caller drops the event list after one call, and
 * the assistant's later turns never see a title, a location, an attendee or a note.
 */
object PopopxCalendarPrivacy {
  const val DAY_MINUTES = PopopxTimePreferences.DAY_MINUTES

  /** Busy intervals clipped to the window and merged, so a day block beside a meeting is one answer. */
  fun busySlots(events: List<PopopxRawCalendarEvent>, windowStart: Long, windowEnd: Long): List<PopopxEcoBusySlot> =
    merge(
      events
        .map { PopopxEcoBusySlot(max(it.startEpochMinutes, windowStart), min(it.endEpochMinutes, windowEnd)) }
        .filter { it.startEpochMinutes < it.endEpochMinutes }
    )

  /** The same busy set widened by the user's buffer, which is how a buffer protects existing events too. */
  fun busySlotsWithBuffer(
    events: List<PopopxRawCalendarEvent>,
    windowStart: Long,
    windowEnd: Long,
    bufferMinutes: Int,
  ): List<PopopxEcoBusySlot> =
    if (bufferMinutes <= 0) {
      busySlots(events, windowStart, windowEnd)
    } else {
      merge(
        busySlots(events, windowStart - bufferMinutes, windowEnd + bufferMinutes)
          .map { PopopxEcoBusySlot(max(it.startEpochMinutes - bufferMinutes, windowStart), min(it.endEpochMinutes + bufferMinutes, windowEnd)) }
          .filter { it.startEpochMinutes < it.endEpochMinutes }
      )
    }

  private fun merge(slots: List<PopopxEcoBusySlot>): List<PopopxEcoBusySlot> {
    val out = ArrayList<PopopxEcoBusySlot>(slots.size)
    for (slot in slots.sortedBy { it.startEpochMinutes }) {
      val last = out.lastOrNull()
      if (last != null && slot.startEpochMinutes <= last.endEpochMinutes) {
        out[out.size - 1] = PopopxEcoBusySlot(last.startEpochMinutes, max(last.endEpochMinutes, slot.endEpochMinutes))
      } else out.add(slot)
    }
    return out
  }

  /**
   * The free intervals of the window, earliest first, each at least `eventMinutes` long.
   *
   * `eventMinutes` is the length of the meeting being proposed: the subtraction happens against the
   * whole length, so a ten-minute gap in front of a blocked hour is never offered for an hour.
   */
  fun freeSlots(
    events: List<PopopxRawCalendarEvent>,
    windowStart: Long,
    windowEnd: Long,
    preferences: PopopxTimePreferences = PopopxTimePreferences.DEFAULT,
    eventMinutes: Int = DEFAULT_EVENT_MINUTES,
  ): List<PopopxEcoBusySlot> {
    if (windowEnd <= windowStart || eventMinutes <= 0) return emptyList()
    val busy = busySlotsWithBuffer(events, windowStart, windowEnd, preferences.bufferMinutes)
    val out = ArrayList<PopopxEcoBusySlot>()
    for (allowed in preferences.allowedRanges(windowStart, windowEnd)) {
      var cursor = allowed.startEpochMinutes
      for (block in busy.filter { it.endEpochMinutes > cursor && it.startEpochMinutes < allowed.endEpochMinutes }) {
        addAtLeast(out, cursor, min(block.startEpochMinutes, allowed.endEpochMinutes), eventMinutes, preferences.minimumSlotMinutes)
        cursor = max(cursor, block.endEpochMinutes)
      }
      addAtLeast(out, cursor, allowed.endEpochMinutes, eventMinutes, preferences.minimumSlotMinutes)
    }
    return out
  }

  private fun addAtLeast(
    out: MutableList<PopopxEcoBusySlot>,
    from: Long,
    to: Long,
    eventMinutes: Int,
    minimumMinutes: Int,
  ) {
    if (to - from >= max(eventMinutes, minimumMinutes).toLong()) out.add(PopopxEcoBusySlot(from, to))
  }

  /** Whether a proposal at `start` for `minutes` collides with anything already in the calendar. */
  fun conflicts(
    events: List<PopopxRawCalendarEvent>,
    start: EcoDateTime,
    minutes: Int,
    bufferMinutes: Int = 0,
  ): PopopxEcoBusySlot? {
    val slot = PopopxEcoBusySlot.between(start, minutes)
    return busySlotsWithBuffer(events, slot.startEpochMinutes, slot.endEpochMinutes, bufferMinutes)
      .firstOrNull { it.contains(start) || slot.startEpochMinutes < it.endEpochMinutes && it.startEpochMinutes < slot.endEpochMinutes }
  }

  /** The window 「查空闲」 reads: [hours] of real time from `from`, no rounding to invent. */
  fun window(from: EcoDateTime, hours: Int): Pair<Long, Long> = from.epochMinutes to from.epochMinutes + hours.toLong() * 60
}
