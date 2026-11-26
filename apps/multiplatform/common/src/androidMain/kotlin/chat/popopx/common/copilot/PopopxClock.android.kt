package chat.popopx.common.copilot

import java.util.Calendar
import java.util.TimeZone

/**
 * The device's local calendar day.
 *
 * [Calendar] rather than `java.time` because it needs no API-level guard, and the local timezone on
 * purpose: [EcoDate] carries no offset, and the whole assistant resolves 「明天下午三点」 against the
 * wall clock the user's calendar app shows them.
 */
actual fun popopxToday(): EcoDate {
  val now = Calendar.getInstance(TimeZone.getDefault())
  return EcoDate(now.get(Calendar.YEAR), now.get(Calendar.MONTH) + 1, now.get(Calendar.DAY_OF_MONTH))
}

/** Minutes since local midnight, which is what `PopopxEcoFacts.clockMinutes` asks for. */
actual fun popopxNowMinutesPastMidnight(): Int {
  val now = Calendar.getInstance(TimeZone.getDefault())
  return now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)
}
