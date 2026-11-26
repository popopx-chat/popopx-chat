package chat.popopx.common.copilot

import chat.popopx.common.discover.PopopxNodeCommand
import chat.popopx.common.discover.PopopxNodeServiceId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The preference filter and the civil-date arithmetic behind it.
 *
 * The dates are the interesting part: the engine's day resolution and the window sweep both count days
 * with Hinnant's algorithm rather than a library, so the fixtures assert against independently computed
 * values — 2026-11-26 is ordinal 20783 and a Thursday, and 20783*1440 = 29927520 is the epoch-minute
 * origin every other number in these suites is written against.
 */
class PopopxTimePreferencesTest {
  private val thursday = EcoDate(2026, 11, 26)
  private val saturday = EcoDate(2026, 11, 28)

  @Test
  fun theCalendarArithmeticAgreesWithTheRealWorld() {
    assertEquals(20783L, thursday.ordinal)
    assertEquals(4, thursday.dayOfWeek, "2026-11-26 is a Thursday")
    assertEquals(6, saturday.dayOfWeek)
    assertEquals(29_927_520L, thursday.ordinal * 1_440L)
    assertEquals("2026-11-26", thursday.iso())
    assertEquals(EcoDate(2026, 12, 1), thursday.plusDays(5))
    assertEquals(EcoDate(2026, 11, 25), thursday.plusDays(-1))
    // Round trips across a century boundary and a leap year, both of which the era arithmetic can get
    // wrong, including the two months that sit at the end of Hinnant's shifted year.
    listOf(
      EcoDate(1970, 3, 1), EcoDate(2000, 3, 1), EcoDate(1900, 3, 1), EcoDate(2100, 3, 1),
      EcoDate(2024, 3, 1), EcoDate(2026, 11, 26), EcoDate(2000, 2, 29), EcoDate(1900, 1, 31),
      EcoDate(2100, 2, 28), EcoDate(1969, 12, 31), EcoDate(1969, 1, 1),
    ).forEach { assertTrue(EcoDate.fromEpochDays(it.ordinal) == it, "round trip broke on $it") }
    assertEquals(0L, EcoDate(1970, 1, 1).ordinal)
    assertEquals(2, EcoDate(2024, 3, 1).ordinal - EcoDate(2024, 2, 28).ordinal, "2024 is a leap year")
    assertEquals(1, EcoDate(2100, 3, 1).ordinal - EcoDate(2100, 2, 28).ordinal, "2100 is not")
    assertEquals(29, EcoDate.daysInMonth(2000, 2))
    assertEquals(28, EcoDate.daysInMonth(2100, 2))
    assertNull(EcoDate.parse("2026-02-30"))
    assertEquals(thursday, EcoDate.parse("2026-11-26"))
  }

  /**
   * The regression pin for `civilFromDays`. Hinnant's algorithm ends with `y += (m <= 2)`, and without
   * that line every January and February day came back one year early — which mattered beyond round-trips,
   * because `PopopxTimePreferences.allowedRanges` reads the weekday through this function, so 「避开周末」
   * was shifted for two months of every year. These are the assertions that would have caught it.
   */
  @Test
  fun fromEpochDaysRoundTripsIntoJanuaryAndFebruary() {
    assertEquals(EcoDate(1970, 1, 1), EcoDate.fromEpochDays(0L), "the epoch itself")
    assertEquals(0L, EcoDate.fromEpochDays(0L).ordinal, "so the returned date round-trips")
    assertEquals(EcoDate(2026, 1, 5), EcoDate.fromEpochDays(EcoDate(2026, 1, 5).ordinal))
    assertEquals(1, EcoDate(2026, 1, 5).dayOfWeek, "2026-01-05 really is a Monday")
    assertEquals(1, EcoDate.fromEpochDays(EcoDate(2026, 1, 5).ordinal).dayOfWeek, "and the sweep sees the same Monday")
    // A year dropped in January is a year dropped across a leap day too, so this is the sharper edge.
    assertEquals(EcoDate(2024, 2, 29), EcoDate.fromEpochDays(EcoDate(2024, 2, 29).ordinal), "2024-02-29 exists")
    assertEquals(EcoDate(2026, 3, 5), EcoDate.fromEpochDays(EcoDate(2026, 3, 5).ordinal))
    // The user-visible consequence, with no events in the calendar at all: a Monday in January is a
    // working day, where the missing correction read it as the Sunday of the year before and refused it.
    val preferences = PopopxTimePreferences(
      workingMinutes = listOf(PopopxTimePreferences.MinuteRange(9 * 60, 18 * 60)),
      avoidWeekends = true,
      minimumSlotMinutes = 15,
    )
    val mondayStart = EcoDate(2026, 1, 5).ordinal * 1_440L + 9 * 60
    val monday = preferences.allowedRanges(mondayStart, mondayStart + 8 * 60)
    assertEquals(1, monday.size, "a Monday in January is kept as a weekday")
    assertEquals(mondayStart to mondayStart + 8 * 60, monday.single().startEpochMinutes to monday.single().endEpochMinutes)
    assertTrue(preferences.allowedRanges(EcoDate(2026, 1, 7).ordinal * 1_440L + 9 * 60, EcoDate(2026, 1, 7).ordinal * 1_440L + 17 * 60).isNotEmpty())
    // And the Saturday of that same week is still refused, which is what the flag is for.
    assertTrue(
      preferences.allowedRanges(EcoDate(2026, 1, 10).ordinal * 1_440L + 9 * 60, EcoDate(2026, 1, 10).ordinal * 1_440L + 17 * 60).isEmpty(),
      "2026-01-10 is a Saturday",
    )
  }

  /**
   * Every day from 1901-01-01 to 2100-12-31 round-tripped, against epoch days measured outside this code.
   *
   * This is the proof for the fix, not the single leap-day assertion above: `civilFromDays` returned day 0
   * of March for every 29 February, and the year divisible by 400 needed one more correction because that
   * leap day is the last day of its era. A hand-picked date cannot show the rest of the range is clean, and
   * a sweep with a counted total cannot silently sweep nothing.
   */
  @Test
  fun everyDayOfTwoCenturiesRoundTripsThroughTheConversion() {
    // Ordinals and weekdays from `python3` over `datetime.date`, not from `daysFromCivil` — the sweep alone
    // would only prove the two halves agree with each other.
    val days = listOf(
      EcoDate(1901, 1, 1) to -25_202L,
      EcoDate(1969, 12, 31) to -1L,
      EcoDate(2000, 2, 29) to 11_016L,
      EcoDate(2024, 2, 29) to 19_782L,
      EcoDate(2026, 1, 5) to 20_458L,
      EcoDate(2100, 1, 1) to 47_482L,
      EcoDate(2100, 3, 1) to 47_541L,
      EcoDate(2100, 12, 31) to 47_846L,
    )
    days.forEach { (date, ordinal) ->
      assertEquals(ordinal, date.ordinal, "$date ordinal")
      assertEquals(date, EcoDate.fromEpochDays(ordinal), "$date round trip")
    }
    var swept = 0
    var previous: Long? = null
    for (year in 1901..2100) for (month in 1..12) for (day in 1..EcoDate.daysInMonth(year, month)) {
      val date = EcoDate(year, month, day)
      val ordinal = date.ordinal
      assertEquals(date, EcoDate.fromEpochDays(ordinal), "$date does not come back")
      val before = previous
      if (before != null) assertEquals(1L, ordinal - before, "$date does not follow ${EcoDate.fromEpochDays(before)}")
      previous = ordinal
      swept += 1
    }
    assertEquals(73_049, swept, "1901-01-01 through 2100-12-31 inclusive")
    assertEquals(2, EcoDate(1901, 1, 1).dayOfWeek, "1901-01-01 was a Tuesday")
    assertEquals(5, EcoDate(2100, 12, 31).dayOfWeek, "2100-12-31 was a Friday")
    assertEquals(2, EcoDate(2000, 2, 29).dayOfWeek, "2000-02-29 was a Tuesday")
    assertEquals(0L, EcoDate.fromEpochDays(0L).ordinal, "and the swept ordinals come back unchanged")
  }

  @Test
  fun plusMinutesOverMidnightRollsTheDate() {
    val eleven = EcoDateTime(thursday, 15 * 60)
    assertEquals("2026-11-26T15:00", eleven.isoLocal())
    assertEquals(29_928_420L, eleven.epochMinutes)

    val rolled = eleven.plusMinutes(900) // 15:00 + 15h = 06:00 the next day
    assertEquals(EcoDate(2026, 11, 27), rolled.date)
    assertEquals(360, rolled.minuteOfDay)
    assertEquals("2026-11-27T06:00", rolled.isoLocal())

    val toMidnight = EcoDateTime(thursday, 23 * 60 + 59).plusMinutes(1)
    assertEquals("2026-11-27T00:00", toMidnight.isoLocal())
    assertEquals(EcoDateTime(thursday, 1439).epochMinutes + 1, toMidnight.epochMinutes)

    val back = EcoDateTime.fromEpochMinutes(EcoDateTime(thursday, 0).epochMinutes - 1)
    assertEquals("2026-11-25T23:59", back.isoLocal())

    // Facts.at is the engine's own door to a day, and it also rolls.
    assertEquals(EcoDateTime(thursday, 1410), FIXTURE_FACTS.at(23 * 60 + 30))
    assertEquals(EcoDateTime(EcoDate(2026, 11, 27), 30), FIXTURE_FACTS.at(1470))
    assertEquals("2026-11-26", FIXTURE_FACTS.now.isoLocal().substringBefore("T"))
    assertEquals("2026-11-26T09:00", FIXTURE_FACTS.now.isoLocal())
  }

  @Test
  fun workingHoursAndLunchShapeTheAllowedRanges() {
    val preferences = PopopxTimePreferences(
      workingMinutes = listOf(PopopxTimePreferences.MinuteRange(9 * 60, 18 * 60)),
      lunch = PopopxTimePreferences.MinuteRange(12 * 60, 13 * 60),
      minimumSlotMinutes = 15,
    )
    val ranges = preferences.allowedRanges(at(THURSDAY, 8), at(THURSDAY, 20))
    assertEquals(
      listOf(
        PopopxEcoBusySlot(at(THURSDAY, 9), at(THURSDAY, 12)),
        PopopxEcoBusySlot(at(THURSDAY, 13), at(THURSDAY, 18)),
      ),
      ranges,
    )
    // Positive: a slot inside working hours is allowed. Negative: 08:30 and the lunch hour are not.
    assertTrue(preferences.allows(PopopxEcoBusySlot(at(THURSDAY, 14), at(THURSDAY, 15)), at(THURSDAY, 8), at(THURSDAY, 20)))
    assertFalse(preferences.allows(PopopxEcoBusySlot(at(THURSDAY, 8), at(THURSDAY, 9)), at(THURSDAY, 8), at(THURSDAY, 20)))
    assertFalse(preferences.allows(PopopxEcoBusySlot(at(THURSDAY, 12), at(THURSDAY, 13)), at(THURSDAY, 8), at(THURSDAY, 20)))
    // A slot that straddles lunch is not inside any permitted interval, even though both halves are.
    assertFalse(preferences.allows(PopopxEcoBusySlot(at(THURSDAY, 11, 30), at(THURSDAY, 13, 30)), at(THURSDAY, 8), at(THURSDAY, 20)))
    // And a slot that is merely long enough for the minimum is refused when the user asked for more.
    val tight = preferences.copy(minimumSlotMinutes = 121)
    assertFalse(tight.allows(PopopxEcoBusySlot(at(THURSDAY, 14), at(THURSDAY, 15)), at(THURSDAY, 8), at(THURSDAY, 20)))
  }

  @Test
  fun lunchIsExcludedFromFreeSlotsEvenWithNothingBooked() {
    val free = PopopxCalendarPrivacy.freeSlots(
      events = emptyList(),
      windowStart = at(THURSDAY, 9),
      windowEnd = at(THURSDAY, 18),
      preferences = PopopxTimePreferences(
        workingMinutes = listOf(PopopxTimePreferences.MinuteRange(9 * 60, 18 * 60)),
        lunch = PopopxTimePreferences.MinuteRange(12 * 60, 13 * 60),
        minimumSlotMinutes = 15,
      ),
      eventMinutes = 60,
    )
    assertEquals(listOf(PopopxEcoBusySlot(at(THURSDAY, 9), at(THURSDAY, 12)), PopopxEcoBusySlot(at(THURSDAY, 13), at(THURSDAY, 18))), free)
    // No lunch preference means the day is one continuous range.
    val noLunch = PopopxCalendarPrivacy.freeSlots(emptyList(), at(THURSDAY, 9), at(THURSDAY, 18), PopopxTimePreferences(workingMinutes = listOf(PopopxTimePreferences.MinuteRange(9 * 60, 18 * 60)), minimumSlotMinutes = 15), 60)
    assertEquals(listOf(PopopxEcoBusySlot(at(THURSDAY, 9), at(THURSDAY, 18))), noLunch)
    // A lunch entirely outside the window changes nothing.
    val elsewhere = PopopxCalendarPrivacy.freeSlots(emptyList(), at(THURSDAY, 14), at(THURSDAY, 18), PopopxTimePreferences(workingMinutes = listOf(PopopxTimePreferences.MinuteRange(9 * 60, 18 * 60)), lunch = PopopxTimePreferences.MinuteRange(12 * 60, 13 * 60), minimumSlotMinutes = 15), 60)
    assertEquals(listOf(PopopxEcoBusySlot(at(THURSDAY, 14), at(THURSDAY, 18))), elsewhere)
  }

  @Test
  fun avoidWeekendsDropsSaturdayAndKeepsThursday() {
    val base = PopopxTimePreferences(
      workingMinutes = listOf(PopopxTimePreferences.MinuteRange(9 * 60, 18 * 60)),
      minimumSlotMinutes = 15,
    )
    val saturdayWindow = THURSDAY + 2 * 1_440L + 9 * 60 // 2026-11-28 is a Saturday
    assertTrue(base.copy(avoidWeekends = false).allowedRanges(saturdayWindow, saturdayWindow + 8 * 60).isNotEmpty(), "weekday hours exist on Saturday when the user allows them")
    assertTrue(base.copy(avoidWeekends = true).allowedRanges(saturdayWindow, saturdayWindow + 8 * 60).isEmpty(), "avoidWeekends must empty Saturday")
    assertEquals(
      listOf(PopopxEcoBusySlot(saturdayWindow, saturdayWindow + 8 * 60)),
      base.copy(avoidWeekends = false).allowedRanges(saturdayWindow, saturdayWindow + 8 * 60),
    )
    assertTrue(base.copy(avoidWeekends = true).allowedRanges(at(THURSDAY, 9), at(THURSDAY, 17)).isNotEmpty(), "Thursday is a weekday")
    // No events, weekend excluded: nothing is offered for a Saturday window.
    assertTrue(PopopxCalendarPrivacy.freeSlots(emptyList(), saturdayWindow, saturdayWindow + 8 * 60, base.copy(avoidWeekends = true), 60).isEmpty())
  }

  @Test
  fun minimumSlotAndEventLengthBothGateTheOffer() {
    val window = at(THURSDAY, 9)..at(THURSDAY, 9, 45) // a 45-minute window
    val anyHours = PopopxTimePreferences(minimumSlotMinutes = 15)
    assertEquals(listOf(PopopxEcoBusySlot(window.start, window.endInclusive)), PopopxCalendarPrivacy.freeSlots(emptyList(), window.start, window.endInclusive, anyHours, eventMinutes = 30))
    // 45 minutes of gap cannot hold a 60-minute event.
    assertTrue(PopopxCalendarPrivacy.freeSlots(emptyList(), window.start, window.endInclusive, anyHours, eventMinutes = 60).isEmpty())
    // And a user who only books two-hour blocks is not offered a 45-minute gap either.
    assertTrue(PopopxCalendarPrivacy.freeSlots(emptyList(), window.start, window.endInclusive, PopopxTimePreferences(minimumSlotMinutes = 120), eventMinutes = 15).isEmpty())
    // Degenerate inputs are refusals, not infinite loops.
    assertTrue(PopopxCalendarPrivacy.freeSlots(emptyList(), window.start, window.start, anyHours, 60).isEmpty())
    assertTrue(PopopxCalendarPrivacy.freeSlots(emptyList(), window.start, window.endInclusive, anyHours, 0).isEmpty())
  }

  /**
   * A night shift is one range, not two, and the sweep now honors it. [PopopxTimePreferences.MinuteRange.valid]
   * asks only that the range be non-empty — an ordered test would have been `endMinute > startMinute`, which is
   * false for 22:00–06:00 and silently dropped every night shift — because [PopopxTimePreferences.allowedRanges]
   * splits a wrapping range into the two segments of the day grid it actually covers. The pin is that the
   * wrapping spelling and the explicit split spelling produce the same intervals.
   */
  @Test
  fun awrappingWorkingRangeIsSweptAsTwoSegmentsOfTheDay() {
    val night = PopopxTimePreferences(
      workingMinutes = listOf(PopopxTimePreferences.MinuteRange(22 * 60, 6 * 60)),
      minimumSlotMinutes = 15,
    )
    assertTrue(night.workingMinutes.single().covers(23 * 60), "23:00 is on shift")
    assertTrue(night.workingMinutes.single().covers(3 * 60), "03:00 is on shift")
    assertFalse(night.workingMinutes.single().covers(12 * 60), "midday is not")
    assertTrue(night.workingMinutes.single().valid, "a wrapping range is still a range")
    val expected = listOf(
      PopopxEcoBusySlot(at(THURSDAY, 0), at(THURSDAY, 6)),
      PopopxEcoBusySlot(at(THURSDAY, 22), at(THURSDAY, 0) + 1_440L),
    )
    assertEquals(expected, night.allowedRanges(at(THURSDAY, 0), at(THURSDAY, 0) + 1_440L), "the shift reaches both ends of the day")
    // Two non-wrapping ranges describe the same shift, and must agree with it rather than be the only form that works.
    val split = night.copy(workingMinutes = listOf(PopopxTimePreferences.MinuteRange(0, 6 * 60), PopopxTimePreferences.MinuteRange(22 * 60, 24 * 60)))
    assertEquals(expected, split.allowedRanges(at(THURSDAY, 0), at(THURSDAY, 0) + 1_440L))
    assertFalse(PopopxTimePreferences.MinuteRange(10 * 60, 10 * 60).valid, "an empty range is not a range")
  }
}

/**
 * The Whisper Bar state machine: 「默认零监听」, the five-message summon window, and what leaving the
 * foreground does to a loaded model.
 */
class PopopxObserverStateTest {
  private val session = "chat.popopx:session-1"

  @Test
  fun startsOffAndSeesNothingButTheTypedMessage() {
    val state = PopopxEcoAssistantState()
    assertEquals(PopopxEcoObserverMode.OFF, state.observer)
    assertNull(state.realtimeSession)
    assertFalse(state.showsLiveIndicator)
    assertEquals(listOf("typed"), state.contextWindow(listOf("one", "two", "three"), "typed"))
    assertEquals(listOf("typed"), state.contextWindow(emptyList(), "typed"))
    // OFF is not a suggestion: even a summon token does not widen it until the user acts.
    state.contextWindow((1..50).map { "m$it" }, "typed").let { assertEquals(1, it.size) }
  }

  @Test
  fun summonFeedsFivePreviousMessagesPlusTheTypedOne() {
    val state = PopopxEcoAssistantState()
    assertEquals(PopopxEcoObserverMode.SUMMON_LAST_MESSAGES, state.summon(session))
    assertNull(state.realtimeSession, "a summon is not a real-time subscription")
    assertFalse(state.showsLiveIndicator)
    val history = (1..9).map { "m$it" }
    assertEquals(listOf("m5", "m6", "m7", "m8", "m9", "typed"), state.contextWindow(history, "typed"))
    assertEquals(5, PopopxEcoAssistantState.CONTEXT_WINDOW)
    // Fewer than five messages exist, so all of them are in scope — the window is a maximum, not a padding.
    assertEquals(listOf("m1", "m2", "typed"), state.contextWindow(listOf("m1", "m2"), "typed"))
  }

  @Test
  fun realtimeIsPerSessionAndAToggleTurnsItBackOff() {
    val state = PopopxEcoAssistantState()
    assertEquals(PopopxEcoObserverMode.REALTIME_SESSION, state.toggleRealtime(session))
    assertEquals(session, state.realtimeSession)
    assertTrue(state.showsLiveIndicator, "the green indicator belongs to exactly this state")
    assertEquals(listOf("m5", "m6", "m7", "m8", "m9", "typed"), state.contextWindow((1..9).map { "m$it" }, "typed"))

    // A second toggle with the same session is the user turning the assist off.
    assertEquals(PopopxEcoObserverMode.OFF, state.toggleRealtime(session))
    assertNull(state.realtimeSession)
    assertFalse(state.showsLiveIndicator)
    assertEquals(listOf("typed"), state.contextWindow((1..9).map { "m$it" }, "typed"))

    // Moving to another session re-arms it, and only one session is live at a time.
    assertEquals(PopopxEcoObserverMode.REALTIME_SESSION, state.toggleRealtime("other"))
    assertEquals("other", state.realtimeSession)
    assertTrue(state.showsLiveIndicator)
    // Toggling the old session id while a different one is live switches rather than stops.
    assertEquals(PopopxEcoObserverMode.REALTIME_SESSION, state.toggleRealtime(session))
    assertEquals(session, state.realtimeSession)
  }

  @Test
  fun liveIndicatorNeedsBothTheModeAndTheSession() {
    // REALTIME without a session is reachable only through the constructor, and must not light the bar.
    val orphan = PopopxEcoAssistantState(PopopxEcoObserverMode.REALTIME_SESSION)
    assertEquals(PopopxEcoObserverMode.REALTIME_SESSION, orphan.observer)
    assertNull(orphan.realtimeSession)
    assertFalse(orphan.showsLiveIndicator, "an indicator without a session would claim to be listening to nothing")
    // A session string without the mode is the other half of the same rule.
    val summon = PopopxEcoAssistantState(PopopxEcoObserverMode.SUMMON_LAST_MESSAGES)
    summon.summon(session)
    assertFalse(summon.showsLiveIndicator)
    assertEquals(PopopxEcoObserverMode.SUMMON_LAST_MESSAGES, summon.observer)
  }

  @Test
  fun backgroundingReleasesTheModelAndEndsTheRealtimeWatch() {
    val state = PopopxEcoAssistantState()
    state.toggleRealtime(session)
    assertTrue(state.showsLiveIndicator)
    state.enteredBackground()
    assertEquals(PopopxEcoObserverMode.OFF, state.observer, "a real-time assist does not survive the background")
    assertNull(state.realtimeSession)
    assertFalse(state.showsLiveIndicator)
    // The deterministic engine's release() keeps it usable, so returning to the foreground still works.
    assertTrue(state.engine.isLoaded)
    assertTrue(state.ensureEngineLoaded())
    assertEquals(PopopxEdgeCopilotEngine.Kind.Deterministic, state.engine.kind)

    // A summon is a single turn, so backgrounding leaves the mode alone but clears any session.
    val summoned = PopopxEcoAssistantState()
    summoned.summon(session)
    summoned.enteredBackground()
    assertEquals(PopopxEcoObserverMode.SUMMON_LAST_MESSAGES, summoned.observer)
    assertNull(summoned.realtimeSession)

    summoned.turnOff()
    assertEquals(PopopxEcoObserverMode.OFF, summoned.observer)
    assertEquals(listOf("typed"), summoned.contextWindow(listOf("a"), "typed"))
  }
}

/** The gate is the only door to a calendar write, so its refusal cases are the point of the test. */
class PopopxConfirmGateTest {
  private val origin = FIXTURE_FACTS.now.epochMinutes // 2026-11-26T09:00
  private val start = EcoDateTime(EcoDate(2026, 11, 27), 15 * 60)
  private val end = EcoDateTime(EcoDate(2026, 11, 27), 16 * 60)
  private val proposal = EcoCreateEvent("复盘会", start, end)

  @Test
  fun aWriteExistsOnlyAfterTheTap() {
    val gate = PopopxEcoConfirmGate()
    val pending = gate.propose(proposal, origin)
    assertEquals(1, pending.id)
    assertEquals(origin, pending.proposedAtEpochMinutes)
    assertEquals(1, gate.proposals.size)
    // Nothing is writable while the card waits.
    assertEquals(PopopxCalendarWrite.Insert("复盘会", start.epochMinutes, end.epochMinutes), proposal.write())

    val write = gate.confirm(pending.id, origin + 10)
    assertEquals(PopopxCalendarWrite.Insert("复盘会", 29_929_860L, 29_929_920L), write)
    assertEquals(0, gate.proposals.size, "the proposal leaves the pending set with the tap")
    // Double-confirm yields only one write.
    assertNull(gate.confirm(pending.id, origin + 11))
    assertNull(gate.confirm(999_999, origin + 11), "unknown id")
  }

  @Test
  fun aStaleCardConfirmsToNothing() {
    val gate = PopopxEcoConfirmGate()
    val pending = gate.propose(proposal, origin)
    assertNull(gate.confirm(pending.id, origin + 31), "the default window is ${PopopxEcoConfirmGate.DEFAULT_CONFIRM_WINDOW_MINUTES} minutes")
    // The expired tap consumed the card, so it cannot be retried inside the window either.
    assertNull(gate.confirm(pending.id, origin + 32))
    assertEquals(0, gate.proposals.size)

    val other = PopopxEcoConfirmGate()
    val boundary = other.propose(proposal, origin)
    assertNotNull(other.confirm(boundary.id, origin + 30))
  }

  @Test
  fun dismissedAndExpiredCardsNeverYieldAWrite() {
    val gate = PopopxEcoConfirmGate()
    val first = gate.propose(proposal, origin)
    val second = gate.propose(EcoCancelEvent("evt-7"), origin)
    gate.dismiss(first.id)
    assertNull(gate.confirm(first.id, origin + 1))
    assertEquals(1, gate.proposals.size)
    assertEquals(PopopxCalendarWrite.Delete("evt-7"), gate.confirm(second.id, origin + 1))

    gate.expireAll()
    assertTrue(gate.proposals.isEmpty())
    assertNull(gate.confirm(second.id, origin + 2))
  }

  @Test
  fun everyProposalKindMapsToExactlyOneWrite() {
    val rescheduled = EcoRescheduleEvent("evt-7", start, 90)
    assertEquals("Move event evt-7", rescheduled.description)
    assertEquals("2026-11-27T15:00", rescheduled.whenText)
    assertEquals(PopopxCalendarWrite.Update("evt-7", 29_929_860L, 90), rescheduled.write())

    val cancelled = EcoCancelEvent("evt-7")
    assertEquals("Cancel event evt-7", cancelled.description)
    assertEquals("", cancelled.whenText)
    assertEquals(PopopxCalendarWrite.Delete("evt-7"), cancelled.write())

    // The planner refuses a compute task as a calendar change, so no write is reachable for it.
    val plan = PopopxEcoPlanner.plan(EcoDispatchTask("shadow_cos.briefing", null, null), FIXTURE_FACTS)
    assertIs<PopopxEcoPlan.Reject>(plan)
    assertEquals("a compute task is not a calendar change", plan.reason)
  }

  @Test
  fun thePlannerWarnsAboutACollisionInsteadOfSilentlyBookingIt() {
    val busy = listOf(PopopxEcoBusySlot(start.epochMinutes, end.epochMinutes))
    val collision = PopopxEcoPlanner.plan(EcoProposeCreate("复盘会", start.isoLocal(), end.isoLocal()), FIXTURE_FACTS, busy)
    assertIs<PopopxEcoPlan.Conflict>(collision)
    assertEquals(busy.single(), collision.`with`)

    val clear = PopopxEcoPlanner.plan(EcoProposeCreate("复盘会", end.isoLocal(), end.plusMinutes(60).isoLocal()), FIXTURE_FACTS, busy)
    assertIs<PopopxEcoPlan.Card>(clear)
    // An untitled proposal is refused rather than titled by the machine.
    assertEquals("the proposal has no event title", (PopopxEcoPlanner.plan(EcoProposeCreate(null, start.isoLocal(), end.isoLocal()), FIXTURE_FACTS, busy) as PopopxEcoPlan.Reject).reason)
    assertEquals("the proposal has no start time", (PopopxEcoPlanner.plan(EcoProposeCreate("x", "sometime", null), FIXTURE_FACTS, busy) as PopopxEcoPlan.Reject).reason)
    assertEquals(
      "the proposal ends before it starts",
      (PopopxEcoPlanner.plan(EcoProposeCreate("x", start.isoLocal(), start.isoLocal()), FIXTURE_FACTS, busy) as PopopxEcoPlan.Reject).reason,
    )
  }
}

/** RFC 5545 output for a confirmed proposal: CRLF, floating local times, escaping, and folding. */
class PopopxEcoIcsTest {
  private val create = EcoCreateEvent("复盘会", EcoDateTime(EcoDate(2026, 11, 27), 15 * 60), EcoDateTime(EcoDate(2026, 11, 27), 16 * 60))

  @Test
  fun linesEndInCrlfAndNeverInALoneLf() {
    val ics = PopopxEcoICS.calendar(create, FIXTURE_FACTS.now.epochMinutes)
    assertTrue(ics.contains("\r\n"))
    assertFalse(ics.replace("\r\n", "").contains("\n"), "a lone LF is not a valid content-line break")
    assertFalse(ics.replace("\r\n", "").contains("\r"), "a lone CR is not a valid content-line break")
    val lines = ics.split("\r\n").filter { it.isNotEmpty() }
    assertEquals("BEGIN:VCALENDAR", lines.first())
    assertEquals("END:VCALENDAR", lines.last())
    assertEquals(1, lines.count { it == "BEGIN:VEVENT" })
    assertEquals(1, lines.count { it == "END:VEVENT" })
    assertTrue(lines.contains("VERSION:2.0"))
    assertTrue(lines.contains("CALSCALE:GREGORIAN"))
    assertTrue(lines.contains("METHOD:PUBLISH"))
  }

  @Test
  fun dtstartIsTheFloatingLocalFormWithoutAnOffset() {
    val lines = PopopxEcoICS.calendar(create, FIXTURE_FACTS.now.epochMinutes).split("\r\n")
    val dtstart = lines.single { it.startsWith("DTSTART:") }
    val dtend = lines.single { it.startsWith("DTEND:") }
    // RFC 5545's GeneralizedTime needs seconds, and `isoLocal()` does not carry them, so the writer pads:
    // the exact form is pinned because `T1500` is otherwise a prefix of `T150000` and startsWith would pass it.
    assertEquals("20261127T150000", dtstart.removePrefix("DTSTART:"))
    assertTrue(dtstart.removePrefix("DTSTART:").startsWith("20261127T1500"))
    assertFalse(dtstart.endsWith("Z"), "the event time is the user's wall clock, not UTC")
    assertFalse(dtstart.contains("TZID"), "no timezone is claimed")
    assertEquals("20261127T160000", dtend.removePrefix("DTEND:"))
    assertFalse(dtend.endsWith("Z"))
    // The stamp is the exception: it is the moment of generation and it is marked as such.
    val stamp = lines.single { it.startsWith("DTSTAMP:") }
    assertTrue(stamp.endsWith("Z"), stamp)
    assertTrue(stamp.removePrefix("DTSTAMP:").startsWith("20261126T0900"))
  }

  @Test
  fun summaryEscapesTheThreeCharactersThatBreakATextValue() {
    val nasty = EcoCreateEvent("Q3; review, big\\doc", EcoDateTime(EcoDate(2026, 11, 27), 15 * 60), EcoDateTime(EcoDate(2026, 11, 27), 16 * 60))
    val line = PopopxEcoICS.calendar(nasty, FIXTURE_FACTS.now.epochMinutes).split("\r\n").single { it.startsWith("SUMMARY:") }
    assertEquals("SUMMARY:Q3\\; review\\, big\\\\doc", line)
    // A newline in the source text becomes the literal two-character escape, not a line break.
    val multiline = EcoCreateEvent("a\nb", EcoDateTime(EcoDate(2026, 11, 27), 15 * 60), EcoDateTime(EcoDate(2026, 11, 27), 16 * 60))
    val summary = PopopxEcoICS.calendar(multiline, FIXTURE_FACTS.now.epochMinutes).split("\r\n").single { it.startsWith("SUMMARY:") }
    assertEquals("SUMMARY:a\\nb", summary)
  }

  @Test
  fun aLongLineIsFoldedAt75OctetsWithALeadingSpace() {
    val long = EcoCreateEvent("x".repeat(100), EcoDateTime(EcoDate(2026, 11, 27), 15 * 60), EcoDateTime(EcoDate(2026, 11, 27), 16 * 60))
    val ics = PopopxEcoICS.calendar(long, FIXTURE_FACTS.now.epochMinutes)
    val lines = ics.split("\r\n").filter { it.isNotEmpty() }
    val offenders = lines.filter { it.toByteArray().size > 75 }
    assertTrue(offenders.isEmpty(), "line over 75 octets: $offenders")
    val index = lines.indexOfFirst { it.startsWith("SUMMARY:") }
    assertTrue(index >= 0)
    assertEquals(75, lines[index].toByteArray().size, "the first chunk is 75 octets")
    assertEquals("SUMMARY:" + "x".repeat(67), lines[index])
    assertEquals(" " + "x".repeat(33), lines[index + 1], "a continuation line begins with exactly one space")
    // Unfolding drops the CRLF and the single leading space together (RFC 5545 §3.1).
    val unfolded = ics.replace("\r\n ", "")
    assertTrue(unfolded.contains("SUMMARY:" + "x".repeat(100)), unfolded)
    assertEquals(100, unfolded.split("\r\n").single { it.startsWith("SUMMARY:") }.removePrefix("SUMMARY:").length)
  }

  @Test
  fun aCancellationIsTheSameCalendarWithAStatusAndNoTimes() {
    val ics = PopopxEcoICS.calendar(EcoCancelEvent("evt-7"), FIXTURE_FACTS.now.epochMinutes)
    val lines = ics.split("\r\n").filter { it.isNotEmpty() }
    assertTrue(lines.contains("STATUS:CANCELLED"))
    assertTrue(lines.none { it.startsWith("DTSTART:") }, "there is no time to publish for a deletion")
    assertTrue(lines.none { it.startsWith("DTEND:") })
    assertTrue(lines.contains("SUMMARY:Cancel event evt-7"))
    assertTrue(lines.single { it.startsWith("UID:") }.startsWith("UID:popopx-copilot-"))
    // A reschedule publishes the new pair plus a sequence bump.
    val moved = PopopxEcoICS.calendar(EcoRescheduleEvent("evt-7", EcoDateTime(EcoDate(2026, 11, 27), 16 * 60), 90), FIXTURE_FACTS.now.epochMinutes)
      .split("\r\n").filter { it.isNotEmpty() }
    assertTrue(moved.contains("SEQUENCE:1"))
    assertTrue(moved.single { it.startsWith("DTSTART:") }.removePrefix("DTSTART:").startsWith("20261127T1600"))
    assertTrue(moved.single { it.startsWith("DTEND:") }.removePrefix("DTEND:").startsWith("20261127T1730"))
    assertTrue(moved.contains("PRODID:-//POPOPX//Copilot//EN"))
  }
}

/** `node.dispatch_task` may only reach a service the user paired, on an action that service offers. */
class PopopxMacNodeDispatcherTest {
  private fun dispatcher(paired: List<PopopxNodeServiceId>, send: (PopopxNodeCommand) -> Boolean = { true }) =
    PopopxEcoMacNodeDispatcher(pairedServices = { paired }, send = send)

  @Test
  fun aPairedServiceAndARealMenuTokenAreAccepted() {
    val service = PopopxNodeServiceId.ShadowCos
    val action = service.menuActions.first().action
    assertEquals("briefing", action, "the catalog's first Shadow Cos action")
    val result = dispatcher(listOf(service)).dispatch(EcoDispatchTask("${service.rawValue}.$action", "notes.pdf", 1))
    val queued = assertIs<PopopxEcoMacNodeDispatcher.Result.Queued>(result)
    assertEquals(service, queued.command.serviceId)
    assertEquals(action, queued.command.action)
    // The payload is fixed: a local file reference never becomes content.
    assertEquals("{}", queued.command.payload)
    assertEquals("shadow_cos::briefing::{}", queued.command.signalPayload)
    assertTrue(queued.command.isAcceptedByNode)
  }

  @Test
  fun anUnpairedServiceIsRefusedBeforeAnySenderIsConsulted() {
    var asked = false
    val result = dispatcher(listOf(PopopxNodeServiceId.ShadowCos), send = { asked = true; true })
      .dispatch(EcoDispatchTask("morning_tv.digest", null, null))
    val rejected = assertIs<PopopxEcoMacNodeDispatcher.Result.Rejected>(result)
    assertTrue(rejected.reason.contains("not paired"), rejected.reason)
    assertEquals("morning_tv is not paired on this device", rejected.reason)
    assertFalse(asked, "a refusal must not reach the transport")
  }

  @Test
  fun anActionTheServiceDoesNotOfferIsRefused() {
    val service = PopopxNodeServiceId.ShadowCos
    assertFalse(service.menuActions.any { it.action == "digest" }, "the fixture depends on Shadow Cos not offering digest")
    val result = dispatcher(listOf(service)).dispatch(EcoDispatchTask("${service.rawValue}.digest", null, null))
    val rejected = assertIs<PopopxEcoMacNodeDispatcher.Result.Rejected>(result)
    assertEquals("digest is not an action shadow_cos offers", rejected.reason)
  }

  @Test
  fun aTokenWithoutBothHalvesIsNotACommand() {
    // This is what the deterministic engine emits today: a bare verb, so it never dispatches on its own.
    val noService = assertIs<PopopxEcoMacNodeDispatcher.Result.Rejected>(dispatcher(listOf(PopopxNodeServiceId.ShadowCos)).dispatch(EcoDispatchTask("summarize", "onboarding.pdf", null)))
    assertEquals("no Mac Node service was named", noService.reason)
    val noAction = assertIs<PopopxEcoMacNodeDispatcher.Result.Rejected>(dispatcher(listOf(PopopxNodeServiceId.ShadowCos)).dispatch(EcoDispatchTask("shadow_cos.", null, null)))
    assertEquals("no Mac Node action was named", noAction.reason)
    // A token with no separator at all is unnamed on the service side.
    assertEquals(
      "no Mac Node service was named",
      assertIs<PopopxEcoMacNodeDispatcher.Result.Rejected>(dispatcher(listOf(PopopxNodeServiceId.ShadowCos)).dispatch(EcoDispatchTask("shadow_cos", null, null))).reason,
    )
    // An id the catalog does not know resolves to no service at all, so it is refused as unnamed.
    val unknown = assertIs<PopopxEcoMacNodeDispatcher.Result.Rejected>(dispatcher(listOf(PopopxNodeServiceId.ShadowCos)).dispatch(EcoDispatchTask("not_a_service.briefing", null, null)))
    assertEquals("no Mac Node service was named", unknown.reason)
  }

  @Test
  fun anUnreachableNodeIsReportedAsARefusalNotAQueue() {
    val result = dispatcher(listOf(PopopxNodeServiceId.ShadowCos), send = { false }).dispatch(EcoDispatchTask("shadow_cos.briefing", null, null))
    val rejected = assertIs<PopopxEcoMacNodeDispatcher.Result.Rejected>(result)
    assertEquals("the node is not reachable right now", rejected.reason)
  }
}
