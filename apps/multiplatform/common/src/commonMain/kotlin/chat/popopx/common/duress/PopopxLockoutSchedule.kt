package chat.popopx.common.duress

import kotlin.math.max
import kotlin.math.roundToLong

/**
 * The escalating cooldown behind a wrong code, and its human-readable remaining time.
 *
 * Mirrors `PopopxLockoutSchedule` (apps/ios/Shared/Features/AntiTheftDuress/PopopxDuressAuthManager.swift:621-655).
 *
 * The table is worth stating exactly, because the intuitive reading — "one minute, then five, then fifteen"
 * measured from when the lockouts start — is wrong by one attempt: the counter is the number of attempts
 * *already made*, so the 5th attempt (the first one past the four free tries) is the one that costs a minute.
 */
object PopopxLockoutSchedule {
  /** Attempts 1 through 4 only report the error; no lock. */
  const val FREE_ATTEMPTS: Int = 4

  /** The 10th attempt wipes the data when the switch is on. */
  const val WIPE_THRESHOLD: Int = 10

  /** From the 8th attempt on — and the ceiling when wiping is off. */
  const val FINAL_LOCK_SECONDS: Double = 3_600.0

  /**
   * Seconds locked out after `count` failed attempts.
   *
   * The shape is `..<(FREE_ATTEMPTS + 1) -> 0`, then 5/6/7 stepping up, then everything else at the ceiling — so
   * 0, a negative, and 8+ all land where the switch's own documentation says they should, and iOS's comment at
   * line 629 is the reason 8 and 9 are not distinct: only 5/6/7 "each lock one step higher".
   */
  fun lockoutSeconds(count: Int): Double = when {
    count < FREE_ATTEMPTS + 1 -> 0.0
    count == 5 -> 60.0
    count == 6 -> 300.0
    count == 7 -> 900.0
    else -> FINAL_LOCK_SECONDS
  }

  /**
   * The remaining time, split the way the three places that show it need it.
   *
   * iOS has one `phrase(_:)` for exactly that reason (line 640-643): the overlay countdown, the locked-out error
   * message and the settings table must not read the same duration as three different shapes, because the owner
   * would then suspect they are three different things. The words are assembled from these parts by the UI layer
   * through the app's own localized slots; the arithmetic — including the rounding — lives here so it can be
   * tested without a locale.
   *
   * Rounded **up**, and the reason is in the comment at line 645: a countdown that says "try again in 0 seconds"
   * while still locked is a lie the interface tells about its own state.
   */
  fun remaining(seconds: Double): PopopxLockoutRemaining {
    val whole = max(0L, seconds.roundToLongUp())
    return PopopxLockoutRemaining(
      hours = whole / 3_600L,
      minutes = (whole % 3_600L) / 60L,
      seconds = whole % 60L,
    )
  }

  /** Rounding up, but never down through zero: 0.4 s remaining is 1 s, and 0 s is 0 s. */
  private fun Double.roundToLongUp(): Long = if (this <= 0.0) 0L else ceilUp(this)

  private fun ceilUp(seconds: Double): Long {
    val floor = seconds.toLong()
    return if (seconds > floor.toDouble()) floor + 1L else floor
  }
}

/**
 * The three quantities a lockout message is made of, already reduced: a value is only set when the tier above it
 * has no remainder, which is what makes iOS's five format strings fall out of one structure instead of five
 * branches duplicated at every call site.
 */
data class PopopxLockoutRemaining(val hours: Long, val minutes: Long, val seconds: Long) {
  /** "%dh %dmin" / "%dh" — used only when [hours] is set. */
  val showsMinutesWithHours: Boolean get() = hours > 0L && minutes > 0L

  /** "%dmin %ds" / "%dmin" — used only when [hours] is zero and [minutes] is not. */
  val showsSecondsWithMinutes: Boolean get() = hours == 0L && minutes > 0L && seconds > 0L

  /** The bare-seconds reading, which is also what a zero remaining time prints. */
  val secondsOnly: Boolean get() = hours == 0L && minutes == 0L

  /**
   * The literal iOS hands to its formatter, in the same precedence order. Kept as a plain string so a test can
   * assert the shape without a resource bundle, and so the UI's localized version has one obvious thing to
   * substitute into.
   */
  fun debugPhrase(): String = when {
    hours > 0L && minutes > 0L -> "${hours}h ${minutes}min"
    hours > 0L -> "${hours}h"
    minutes > 0L && seconds > 0L -> "${minutes}min ${seconds}s"
    minutes > 0L -> "${minutes}min"
    else -> "${seconds}s"
  }
}
