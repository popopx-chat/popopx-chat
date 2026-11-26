package chat.popopx.common.copilot

/**
 * Fixtures shared by the copilot suites.
 *
 * Every number here is written out rather than computed from `System.currentTimeMillis()`, because the
 * whole feature is meant to be reproducible: the tests below assert on 2026-11-26 and nothing reads a
 * wall clock to get there.
 */

/** 2026-11-26T00:00 as minutes since the epoch — a Thursday, per `EcoDate(2026, 11, 26).dayOfWeek == 4`. */
internal const val THURSDAY = 29_927_520L

/** 2026-11-27T00:00, the day after. */
internal const val FRIDAY = 29_928_960L

/** Minutes since midnight, so `at(THURSDAY, 9, 30)` is Thursday 09:30. */
internal fun at(dayStart: Long, hour: Int, minute: Int = 0): Long = dayStart + hour * 60 + minute

/** The facts the engine is told: today is Thursday 2026-11-26, it is 09:00, events last an hour. */
internal val FIXTURE_FACTS = PopopxEcoFacts(
  today = EcoDate(2026, 11, 26),
  defaultEventMinutes = 60,
  defaultWindowHours = 24,
  clockMinutes = 9 * 60,
)

/** Words that must never appear outside the sanitizer: they live only in [PopopxRawCalendarEvent]. */
internal val SECRETS = listOf("Onco", "trial kickoff", "Clinic 4B", "dr.ellis@popopx.im", "NDA", "Biopsy")
