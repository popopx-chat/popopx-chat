package chat.popopx.common.copilot

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.TimeZone

/**
 * The system calendar, behind the one interface the assistant is allowed to hold.
 *
 * The privacy rule of this feature is that a title, a location, an attendee and a note exist in
 * exactly one place: inside [PopopxRawCalendarEvent], which [PopopxEcoAssistant.onMessage] feeds
 * straight into [PopopxCalendarPrivacy.busySlots] without ever naming the list. Nothing below this
 * class returns a String that came from a calendar row, with one deliberate exception and it is not a
 * leak — [resolveEventId] returns a store id, which is a number the assistant uses to point at the
 * row it is about to move or delete.
 *
 * Two clocks meet here and they do not agree, which is the reason for [toWallClockMinutes]. The
 * shared engine's `epochMinutes` is local wall-clock time with no zone carried anywhere
 * ([EcoDateTime.epochMinutes] is date-ordinal times 1440 plus minute-of-day). CalendarContract
 * indexes `Instances.BEGIN`/`Instances.END` as UTC milliseconds for a timed event and as local-midnight
 * milliseconds for an all-day one. Converting naively would book a 15:00 proposal at 07:00 on a
 * UTC+8 device, so every row is widened by its zone offset and every all-day row is taken as it
 * stands.
 */
class PopopxAndroidCalendar(private val context: Context) : PopopxEcoCalendarAccess {

  /** Both permissions, because a read-only grant still cannot complete the confirm tap. */
  override fun permissionsGranted(): Boolean =
    POPOPX_CALENDAR_PERMISSIONS.all {
      ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }

  /**
   * The events of the window, as raw rows.
   *
   * `Instances` rather than `Events`, because a recurring event is one `Events` row and many
   * occurrences, and 「查空闲」 is a question about occurrences. The id range on the URI is what the
   * provider indexes on, so the window is expressed there rather than in a selection string.
   */
  override suspend fun rawEvents(windowStartEpochMinutes: Long, windowEndEpochMinutes: Long): List<PopopxRawCalendarEvent> {
    if (!permissionsGranted()) return emptyList()
    return withContext(Dispatchers.IO) {
      val rows = queryInstances(windowStartEpochMinutes, windowEndEpochMinutes) { cursor ->
        val allDay = cursor.getIntOrNull(CalendarContract.Instances.ALL_DAY) == 1
        val zone = cursor.getStringOrNull(CalendarContract.Instances.EVENT_TIMEZONE)
        PopopxRawCalendarEvent(
          startEpochMinutes = toWallClockMinutes(cursor.getLong(CalendarContract.Instances.BEGIN), allDay, zone),
          endEpochMinutes = toWallClockMinutes(cursor.getLong(CalendarContract.Instances.END), allDay, zone),
          title = cursor.getStringOrNull(CalendarContract.Events.TITLE).orEmpty(),
          location = cursor.getStringOrNull(CalendarContract.Events.EVENT_LOCATION).orEmpty(),
          attendees = emptyList(),
          notes = cursor.getStringOrNull(CalendarContract.Events.DESCRIPTION).orEmpty(),
        )
      }
      // `attendees` is left empty because the projection below never reads the Attendees table: a
      // column that is not queried is a column that cannot leave this function, and free/busy needs
      // no roster. This is the only place in the app that a calendar title is held at all, and the
      // caller passes the list straight to PopopxCalendarPrivacy.busySlots.
      rows
    }
  }

  /**
   * The store id of the event the user's words point at — found by *time*, never by text.
   *
   * The order of preference is what makes this safe to hand a write to: an event that starts at the
   * minute the user named, then an event on the day they named, and if neither resolves, nothing. A
   * wrong id is a wrong write, so an ambiguous turn returns null and the caller produces no card.
   */
  override suspend fun resolveEventId(words: String, windowStartEpochMinutes: Long, windowEndEpochMinutes: Long): String? {
    if (!permissionsGranted()) return null
    val facts = PopopxEcoFacts.now()
    val target = PopopxDeterministicEngine.resolveTime(words, facts)
    val day = target?.first?.date ?: PopopxDeterministicEngine.resolveDay(words, facts.today)
    return withContext(Dispatchers.IO) {
      val candidates = queryInstances(windowStartEpochMinutes, windowEndEpochMinutes) { cursor ->
        val allDay = cursor.getIntOrNull(CalendarContract.Instances.ALL_DAY) == 1
        val zone = cursor.getStringOrNull(CalendarContract.Instances.EVENT_TIMEZONE)
        Triple(
          cursor.getLong(CalendarContract.Instances.EVENT_ID),
          toWallClockMinutes(cursor.getLong(CalendarContract.Instances.BEGIN), allDay, zone),
          toWallClockMinutes(cursor.getLong(CalendarContract.Instances.END), allDay, zone),
        )
      }
      val exact = target?.first
      candidates
        .firstOrNull { exact != null && it.second == exact.epochMinutes }
        ?.let { return@withContext it.first.toString() }
      if (day != null) {
        candidates
          .filter { EcoDateTime.fromEpochMinutes(it.second).date == day }
          .minByOrNull { it.second }
          ?.let { return@withContext it.first.toString() }
      }
      // No day and no time in the words: the only event that can be meant is the next one that has not
      // finished, and if the user has nothing scheduled the answer is "no card", not a guess.
      candidates
        .filter { it.third > facts.now.epochMinutes }
        .minByOrNull { it.second }
        ?.let { return@withContext it.first.toString() }
      null
    }
  }

  /**
   * Executes a confirmed change.
   *
   * The type is the gate: a [PopopxCalendarWrite] exists only as the return value of
   * [PopopxEcoConfirmGate.confirm], so reaching this function at all means the person tapped. What the
   * function adds is the refusal — no writable calendar on the device, an id that is not a number, a
   * provider that rejects the row — each of them `false` rather than an exception, because the UI says
   * "not written" and the user's calendar stays theirs.
   */
  override suspend fun apply(write: PopopxCalendarWrite): Boolean {
    if (!permissionsGranted()) return false
    return withContext(Dispatchers.IO) {
      when (write) {
        is PopopxCalendarWrite.Insert -> insert(write)
        is PopopxCalendarWrite.Update -> update(write)
        is PopopxCalendarWrite.Delete -> delete(write)
      }
    }
  }

  // --- writes -------------------------------------------------------------------------------------

  private fun insert(write: PopopxCalendarWrite.Insert): Boolean {
    val calendar = writableCalendar() ?: return false
    val zone = TimeZone.getDefault().id
    val values = android.content.ContentValues().apply {
      put(CalendarContract.Events.CALENDAR_ID, calendar)
      put(CalendarContract.Events.TITLE, write.title)
      // Local wall-clock minutes to the epoch millis the provider stores for a timed event.
      put(CalendarContract.Events.DTSTART, fromWallClockMinutes(write.startEpochMinutes))
      put(CalendarContract.Events.DTEND, fromWallClockMinutes(write.endEpochMinutes))
      put(CalendarContract.Events.EVENT_TIMEZONE, zone)
      put(CalendarContract.Events.STATUS, CalendarContract.Events.STATUS_CONFIRMED)
      put(CalendarContract.Events.ACCESS_LEVEL, CalendarContract.Events.ACCESS_DEFAULT)
    }
    val uri = runCatching { context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values) }.getOrNull()
    return uri != null
  }

  private fun update(write: PopopxCalendarWrite.Update): Boolean {
    val eventId = write.eventId.toLongOrNull() ?: return false
    val calendarId = calendarIdOf(eventId) ?: return false
    val zone = TimeZone.getDefault().id
    val values = android.content.ContentValues().apply {
      // The provider refuses an event update that does not say which calendar owns the row.
      put(CalendarContract.Events.CALENDAR_ID, calendarId)
      put(CalendarContract.Events.DTSTART, fromWallClockMinutes(write.newStartEpochMinutes))
      put(CalendarContract.Events.DTEND, fromWallClockMinutes(write.newStartEpochMinutes + write.durationMinutes.coerceAtLeast(1)))
      put(CalendarContract.Events.EVENT_TIMEZONE, zone)
    }
    val client = context.contentResolver.acquireContentProviderClient(CalendarContract.Events.CONTENT_URI) ?: return false
    return try {
      client.update(ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId), values, null, null) == 1
    } catch (error: Throwable) {
      false
    } finally {
      runCatching { if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) client.close() else client.release() }
    }
  }

  private fun delete(write: PopopxCalendarWrite.Delete): Boolean {
    val eventId = write.eventId.toLongOrNull() ?: return false
    val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId)
    return runCatching { context.contentResolver.delete(uri, null, null) }.getOrDefault(0) >= 1
  }

  /** The first calendar the device will accept a write into. Null means the assistant cannot book anything. */
  private fun writableCalendar(): Long? {
    val projection = arrayOf(CalendarContract.Calendars._ID, CalendarContract.Calendars.ACCOUNT_TYPE)
    // CONTRIBUTOR (200) is the floor: below it the provider rejects the insert outright. A local,
    // unsynced calendar is preferred so a booking stays on the device unless there is nothing else.
    val selection = "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ? AND ${CalendarContract.Calendars.VISIBLE} = 1"
    val args = arrayOf(CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR.toString())
    val local = runCatching {
      context.contentResolver.query(CalendarContract.Calendars.CONTENT_URI, projection, selection, args, null)?.use { cursor ->
        while (cursor.moveToNext()) {
          if (cursor.getStringOrNull(CalendarContract.Calendars.ACCOUNT_TYPE) == CalendarContract.ACCOUNT_TYPE_LOCAL) {
            return@use cursor.getLong(CalendarContract.Calendars._ID)
          }
        }
        null
      }
    }.getOrNull()
    if (local != null) return local
    return runCatching {
      context.contentResolver.query(CalendarContract.Calendars.CONTENT_URI, projection, selection, args, null)?.use { cursor ->
        if (cursor.moveToNext()) cursor.getLong(CalendarContract.Calendars._ID) else null
      }
    }.getOrNull()
  }

  private fun calendarIdOf(eventId: Long): Long? = runCatching {
    context.contentResolver.query(
      ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId),
      arrayOf(CalendarContract.Events.CALENDAR_ID),
      null,
      null,
      null,
    )?.use { cursor -> if (cursor.moveToNext()) cursor.getLong(CalendarContract.Events.CALENDAR_ID) else null }
  }.getOrNull()

  // --- reads --------------------------------------------------------------------------------------

  /**
   * One `Instances` query over the window, mapped by [read].
   *
   * The window is widened by more than any timezone offset on the device before conversion, because
   * the bounds arrive in local wall-clock minutes and the provider indexes UTC. Widening is safe:
   * [PopopxCalendarPrivacy.busySlots] clips every slot to the requested window and drops what is left
   * over after clipping, so an occurrence that only appeared because of the margin contributes nothing.
   */
  private fun <T> queryInstances(windowStartEpochMinutes: Long, windowEndEpochMinutes: Long, read: (Cursor) -> T): List<T> {
    val builder = CalendarContract.Instances.CONTENT_URI.buildUpon()
    ContentUris.appendId(builder, fromWallClockMinutes(windowStartEpochMinutes) - CLOCK_MARGIN_MILLIS)
    ContentUris.appendId(builder, fromWallClockMinutes(windowEndEpochMinutes) + CLOCK_MARGIN_MILLIS)
    val out = ArrayList<T>()
    val cursor = runCatching {
      context.contentResolver.query(builder.build(), INSTANCE_PROJECTION, null, null, null)
    }.getOrNull() ?: return out
    cursor.use {
      while (it.moveToNext()) out.add(read(it))
    }
    return out
  }

  /** UTC millis on the provider → minutes since the epoch in the user's local wall clock. */
  private fun toWallClockMinutes(millis: Long, allDay: Boolean, zoneId: String?): Long {
    val zone = if (zoneId.isNullOrBlank()) TimeZone.getDefault() else TimeZone.getTimeZone(zoneId)
    // An all-day row is already stored at local midnight of its own zone, so adding the offset again
    // would shift a day-block by eight hours on a UTC+8 device.
    return if (allDay) millis.floorDiv(60_000L) else (millis + zone.getOffset(millis)).floorDiv(60_000L)
  }

  /** Local wall-clock minutes → the UTC millis the provider compares against. */
  private fun fromWallClockMinutes(minutes: Long): Long {
    val zone = TimeZone.getDefault()
    val naive = minutes * 60_000L
    // Two passes converge for every offset a real zone uses, including a DST boundary inside the day.
    var utc = naive - zone.rawOffset
    repeat(2) { utc = naive - zone.getOffset(utc) }
    return utc
  }

  private fun Cursor.getLong(columnName: String): Long {
    val index = getColumnIndex(columnName)
    return if (index < 0 || isNull(index)) 0L else getLong(index)
  }

  private fun Cursor.getIntOrNull(columnName: String): Int? {
    val index = getColumnIndex(columnName)
    return if (index < 0 || isNull(index)) null else getInt(index)
  }

  private fun Cursor.getStringOrNull(columnName: String): String? {
    val index = getColumnIndex(columnName)
    return if (index < 0 || isNull(index)) null else getString(index)
  }

  companion object {
    /** READ and WRITE together, in this order: the request dialog shows them as one pair. */
    val POPOPX_CALENDAR_PERMISSIONS = arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR)

    /** More than any timezone offset in use (UTC+14), so a widened window cannot miss a real event. */
    private const val CLOCK_MARGIN_MILLIS = 26L * 60 * 60 * 1000

    /**
     * The occurrence, its store id, and the three text columns the sanitizer is specified to discard.
     * Attendees are deliberately absent from this projection: a column that is never read is a column
     * that cannot reach [PopopxRawCalendarEvent], and the free/busy answer needs no participant list.
     */
    private val INSTANCE_PROJECTION = arrayOf(
      CalendarContract.Instances.EVENT_ID,
      CalendarContract.Instances.BEGIN,
      CalendarContract.Instances.END,
      CalendarContract.Instances.ALL_DAY,
      CalendarContract.Instances.EVENT_TIMEZONE,
      CalendarContract.Events.TITLE,
      CalendarContract.Events.EVENT_LOCATION,
      CalendarContract.Events.DESCRIPTION,
    )
  }
}
