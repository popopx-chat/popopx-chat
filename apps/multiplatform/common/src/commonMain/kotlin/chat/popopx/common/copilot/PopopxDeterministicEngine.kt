package chat.popopx.common.copilot

/**
 * A proleptic Gregorian date, kept as three integers so the assistant's time resolution has no timezone, no
 * library and no locale to disagree about. Civil-date arithmetic is inlined rather than pulled from
 * kotlinx-datetime because the whole feature must decide "next Thursday at 4" the same way on three platforms.
 */
data class EcoDate(val year: Int, val month: Int, val day: Int) : Comparable<EcoDate> {
  override fun compareTo(other: EcoDate) = compareValuesBy(this, other) { it.ordinal }

  val ordinal: Long get() = daysFromCivil(year, month, day)

  fun plusDays(days: Long): EcoDate = civilFromDays(ordinal + days)

  /** ISO 8601 day of the week: 1 is Monday. */
  val dayOfWeek: Int get() = (((ordinal + 3) % 7 + 7) % 7).toInt() + 1

  fun iso(): String = "${pad4(year)}-${pad2(month)}-${pad2(day)}"

  companion object {
    /** The date holding the given number of days since 1970-01-01, which is how the calendars count. */
    fun fromEpochDays(days: Long): EcoDate = civilFromDays(days)

    fun parse(text: String): EcoDate? {
      val match = Regex("""^(\d{4})-(\d{2})-(\d{2})$""").matchEntire(text.trim()) ?: return null
      val (y, m, d) = match.destructured
      val date = EcoDate(y.toInt(), m.toInt(), d.toInt())
      return if (date.month in 1..12 && date.day in 1..daysInMonth(date.year, date.month)) date else null
    }

    /**
     * Days from the start of its era to the first day of the March-based era year [yearOfEra].
     *
     * Both conversions below read this one function, which is the point: the pair was inconsistent before,
     * and an inconsistency here is invisible except on 29 February.
     */
    private fun eraYearStart(yearOfEra: Long): Long = 365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100

    /** Howard Hinnant's civil-days algorithm; the epoch is 1970-01-01 and the arithmetic is exact for any year. */
    internal fun daysFromCivil(y0: Int, m: Int, d: Int): Long {
      var y = y0.toLong()
      if (m <= 2) y -= 1
      val era = (if (y >= 0) y else y - 399) / 400
      val yearOfEra = y - era * 400
      val dayOfYear = (153 * (m + if (m > 2) -3 else 9) + 2) / 5 + d - 1
      return era * 146097 + eraYearStart(yearOfEra) + dayOfYear - 719468
    }

    internal fun civilFromDays(z: Long): EcoDate {
      val z0 = z + 719468
      val era = (if (z0 >= 0) z0 else z0 - 146096) / 146097
      val dayOfEra = z0 - era * 146097
      // The era year is searched rather than divided out. Hinnant's closed form —
      // `(doe - doe/1461 + doe/36524 - doe/146096) / 365`, which this line used to be — returns 400 for
      // every 29 February, because a March-based year that contains a leap day runs to day 365 while the
      // next era year already starts there. dayOfYear then goes negative and the caller gets day 0 of March.
      // `dayOfEra / 365` is an upper bound (each era year is at least 365 days) and is off by at most one
      // step, so the two loops below converge immediately; the clamp keeps it inside the era for the case
      // above, where the bound is 400.
      var yearOfEra = minOf(399L, dayOfEra / 365)
      while (eraYearStart(yearOfEra) > dayOfEra) yearOfEra -= 1
      while (yearOfEra < 399L && eraYearStart(yearOfEra + 1) <= dayOfEra) yearOfEra += 1
      val y = yearOfEra + era * 400
      val dayOfYear = dayOfEra - eraYearStart(yearOfEra)
      val shiftedMonth = (5 * dayOfYear + 2) / 153
      val d = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
      val m = shiftedMonth + if (shiftedMonth < 10) 3 else -9
      // Hinnant's last line: the era year counted from March, so January and February belong to the
      // year that has not finished yet. Omitting it returns the previous year for every date before
      // March 1, and a wrong year is a wrong day of the week.
      val year = y + (if (m <= 2) 1 else 0)
      return EcoDate(year.toInt(), m.toInt(), d.toInt())
    }

    fun daysInMonth(year: Int, month: Int): Int = when (month) {
      1, 3, 5, 7, 8, 10, 12 -> 31
      4, 6, 9, 11 -> 30
      else -> if (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) 29 else 28
    }
  }
}

/** A wall-clock instant with no offset: a date plus minutes since midnight, which is all a proposal needs. */
data class EcoDateTime(val date: EcoDate, val minuteOfDay: Int) {
  val epochMinutes: Long get() = date.ordinal * MINUTES_PER_DAY + minuteOfDay

  fun isoLocal(): String = "${date.iso()}T${pad2(minuteOfDay.floorDiv(60))}:${pad2(minuteOfDay.mod(60))}"

  fun plusMinutes(minutes: Int): EcoDateTime {
    val total = minuteOfDay + minutes
    return EcoDateTime(date.plusDays(total.floorDiv(24 * 60).toLong()), total.mod(24 * 60))
  }

  companion object {
    fun fromEpochMinutes(minutes: Long): EcoDateTime =
      EcoDateTime(EcoDate.fromEpochDays(minutes.floorDiv(MINUTES_PER_DAY)), minutes.mod(MINUTES_PER_DAY).toInt())

    fun parse(text: String): EcoDateTime? {
      val match = Regex("""^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$""").matchEntire(text.trim()) ?: return null
      val (y, mo, d, h, mi) = match.destructured
      val date = EcoDate.parse("$y-$mo-$d") ?: return null
      val minute = h.toInt() * 60 + mi.toInt()
      if (h.toInt() > 23 || mi.toInt() > 59) return null
      return EcoDateTime(date, minute)
    }
  }
}

/** The facts the assistant is told before it resolves a time: what day it is, and how long to book by default. */
data class PopopxEcoFacts(
  val today: EcoDate,
  val defaultEventMinutes: Int = 60,
  val defaultWindowHours: Int = 24,
  /** Minutes past local midnight right now, so "in two hours" has somewhere to land. */
  val clockMinutes: Int = 9 * 60,
) {
  val now: EcoDateTime get() = EcoDateTime(today, clockMinutes)

  companion object {
    /** The facts for this instant on this device. */
    fun now(): PopopxEcoFacts = PopopxEcoFacts(today = popopxToday(), clockMinutes = popopxNowMinutesPastMidnight())
  }
  fun at(minutesPastMidnight: Int, day: EcoDate = today): EcoDateTime =
    if (minutesPastMidnight < 24 * 60) EcoDateTime(day, minutesPastMidnight) else EcoDateTime(day.plusDays(1), minutesPastMidnight - 24 * 60)
}

/**
 * Everything one platform can do with the messages it is allowed to read. The on-device engine and the
 * deterministic one implement the same shape so the UI never has to know which answered.
 */
interface PopopxEdgeCopilotEngine {
  val kind: Kind

  enum class Kind { Needle, Deterministic }

  /** Loads weights or warms tables. Called only on an explicit summon, and [release] must undo it. */
  fun ensureLoaded(): Boolean

  fun release()

  val isLoaded: Boolean

  fun parse(input: String, facts: PopopxEcoFacts): PopopxEcoEnvelope
}

/**
 * The engine that ships in this branch: a deterministic extractor over a bounded grammar.
 *
 * It is deliberately narrow. A turn that does not clearly ask for one of the five tools returns an empty
 * envelope, because a wrong calendar proposal costs the user more than a missed one. English is matched on
 * word boundaries; Chinese on the particles 点/号/周 and the verb pairs below, which is the input the product
 * actually sees in `zh-rCN`/`zh-rTW`. Other locales fall through to an empty envelope rather than being
 * guessed at from Latin keywords.
 */
class PopopxDeterministicEngine : PopopxEdgeCopilotEngine {
  override val kind = PopopxEdgeCopilotEngine.Kind.Deterministic
  override var isLoaded = true
    private set

  override fun ensureLoaded() = true

  override fun release() {
    isLoaded = true
  }

  override fun parse(input: String, facts: PopopxEcoFacts): PopopxEcoEnvelope {
    val text = input.trim()
    if (text.isEmpty()) return PopopxEcoEnvelope.EMPTY
    val lowered = text.lowercase()
    val explicit = PopopxEcoCommand.parse(text)

    explicit?.let { command ->
      val resolved = resolveTime(text, facts)
      return when (command) {
        PopopxEcoCommand.CheckAvailability -> {
          val window = resolved ?: resolveDayWindow(text, facts)
          if (window != null) call(EcoGetAvailability(window.first.isoLocal(), window.second.isoLocal()), facts) else emptyWithReason("no window")
        }
        PopopxEcoCommand.BookTime -> resolved?.let { call(EcoProposeCreate(titleOf(text), it.first.isoLocal(), it.second.isoLocal()).normalized(facts, facts.defaultEventMinutes), facts) } ?: emptyWithReason("no time")
        PopopxEcoCommand.MoveTime -> resolved?.let { call(EcoProposeReschedule(refOf(text), it.first.isoLocal()), facts) } ?: emptyWithReason("no time")
        PopopxEcoCommand.CancelTime -> refOf(text).takeIf { it.isNotEmpty() }?.let { call(EcoProposeCancel(it), facts) } ?: emptyWithReason("no event")
        PopopxEcoCommand.SummarizeFile -> fileRefOf(text)?.let { call(EcoDispatchTask("summarize", it, null), facts) } ?: emptyWithReason("no file")
      }
    }

    val when_ = resolveTime(text, facts)
    val dayWindow = when_ ?: resolveDayWindow(text, facts)
    return when {
      CANCEL.containsMatchIn(lowered) && refOf(text).isNotEmpty() -> call(EcoProposeCancel(refOf(text)), facts)
      RESCHEDULE.containsMatchIn(lowered) && when_ != null -> call(EcoProposeReschedule(refOf(text), when_.first.isoLocal()), facts)
      DISPATCH.containsMatchIn(lowered) && fileRefOf(text) != null -> call(EcoDispatchTask("summarize", fileRefOf(text), null), facts)
      AVAILABILITY.containsMatchIn(lowered) && dayWindow != null -> call(EcoGetAvailability(dayWindow.first.isoLocal(), dayWindow.second.isoLocal()), facts)
      CREATE.containsMatchIn(lowered) && when_ != null -> call(EcoProposeCreate(titleOf(text), when_.first.isoLocal(), when_.second.isoLocal()).normalized(facts, facts.defaultEventMinutes), facts)
      else -> PopopxEcoEnvelope.EMPTY
    }
  }

  private fun call(c: PopopxEcoCall, facts: PopopxEcoFacts) =
    PopopxEcoEnvelope(listOf(c), emptyList(), 1.0, "deterministic match against ${facts.today.iso()}")

  private fun emptyWithReason(reason: String) = PopopxEcoEnvelope(emptyList(), emptyList(), 0.0, reason)

  companion object {
    /**
     * The cancel verb.
     *
     * The Chinese alternatives sit OUTSIDE `\b`, deliberately: `java.util.regex` treats a CJK glyph as a
     * non-word character, so `\b取消\b` can only match when an ASCII word character touches it, and a
     * sentence like 「取消周五的会议」 would never match at all. On iOS the same string is compiled by ICU,
     * where CJK is a word character and the boundary form does match — a divergence documented in
     * `apps/ios/Shared/Features/Discover/DiscoverCatalogModels.swift` in the Copilot block, and the reason
     * the two engines are compared against shared vectors rather than trusted to agree.
     */
    private val CANCEL = Regex("""\b(cancel|call off|drop)\b|删除|取消|把.+(取消|删掉)""")
    private val RESCHEDULE = Regex("""\b(move|push|shift|reschedule|postpone)\b|改到|改期|挪到|推到""")
    private val DISPATCH = Regex("""\b(summari[sz]e|digest|read|translate|compress)\b|总结|摘要|翻译""")
    private val AVAILABILITY = Regex("""\b(free|available|busy|open|when can)\b|有空|有没空|查空闲|几点有空""")
    private val CREATE = Regex("""\b(meet|meeting|book|schedule|set up|reserve|add|grab)\b|约|安排|订|加个""")

    /** The words that introduce a request in Chinese, stripped from a file reference, never from a title. */
    private val LEADING_VERB = Regex("""^(帮我|请你|请|麻烦|把|将|给我|来|需要|想要|总结|摘要|翻译|压缩|处理|看一下|看看|打开)+""")

    /**
     * Finds the first time and the day it belongs to, and returns the start with a defaulted end. Returns null
     * when no clock time is present: a whole-day proposal guessed from "sometime next week" is not a booking.
     */
    fun resolveTime(text: String, facts: PopopxEcoFacts): Pair<EcoDateTime, EcoDateTime>? {
      val day = resolveDay(text, facts.today) ?: return null
      val clock = resolveClock(text) ?: return null
      val start = facts.at(clock, day)
      val end = if (clockRange(text) != null) facts.at(clockRange(text)!!, day) else start.plusMinutes(facts.defaultEventMinutes)
      return if (end.minuteOfDay <= start.minuteOfDay && end.date == start.date) start to start.plusMinutes(facts.defaultEventMinutes) else start to end
    }

    /**
     * The whole of the day the words point at, for a question that asks about availability rather
     * than a time. `resolveTime` refuses without a clock, and that refusal is right for a booking
     * and wrong for 「我明天有什么安排」, which is why this exists separately.
     */
    fun resolveDayWindow(text: String, facts: PopopxEcoFacts): Pair<EcoDateTime, EcoDateTime>? {
      val day = resolveDay(text, facts.today) ?: return null
      return EcoDateTime(day, 0) to EcoDateTime(day.plusDays(1), 0)
    }

    fun resolveDay(text: String, today: EcoDate): EcoDate? {
      val lowered = text.lowercase()
      when {
        Regex("""\btoday|今天|今日\b""").containsMatchIn(lowered) || lowered.contains("今天") || lowered.contains("今日") -> return today
        Regex("""\btomorrow|明天\b""").containsMatchIn(lowered) || lowered.contains("明天") -> return today.plusDays(1)
        Regex("""\bday after tomorrow|后天\b""").containsMatchIn(lowered) || lowered.contains("后天") -> return today.plusDays(2)
      }
      if (lowered.contains("下周") || lowered.contains("next week")) return nextWeekday(today, weekdayOf(lowered) ?: 1)
      weekdayOf(lowered)?.let { target ->
        val explicitNext = lowered.contains("next ") || lowered.contains("下周")
        val candidate = firstWeekdayOnOrAfter(today, target)
        return if (explicitNext && candidate.dayOfWeek == target && candidate == today) candidate.plusDays(7) else candidate
      }
      Regex("""(\d{1,2})\s*(?:日|号)""").find(text)?.let { m ->
        val day = m.groupValues[1].toIntOrNull() ?: return null
        // "27号" on the 26th means the 27th; on the 28th it means next month's 27th, and in December
        // next month is next year — a date in the past is not what the user asked for, so it is refused.
        if (day !in 1..31) return null
        return if (day >= today.day) EcoDate(today.year, today.month, day)
        else if (today.month < 12) EcoDate(today.year, today.month + 1, day)
        else EcoDate(today.year + 1, 1, day)
      }
      return null
    }

    private fun firstWeekdayOnOrAfter(today: EcoDate, isoWeekday: Int): EcoDate {
      var offset = 0L
      while (offset < 7) {
        val candidate = today.plusDays(offset)
        if (candidate.dayOfWeek == isoWeekday) return candidate
        offset += 1
      }
      return today.plusDays(7)
    }

    private fun nextWeekday(today: EcoDate, isoWeekday: Int) = firstWeekdayOnOrAfter(today.plusDays(1), isoWeekday)

    /**
     * The weekday the words point at, as an ISO day number.
     *
     * English is matched on word boundaries because the three-letter forms are inside common words —
     * "mon" in "month", "wed" in "wedding", "sat" in "satisfied" — and a booking on the wrong day is
     * worse than no booking. The longer English forms are tried first so "sunday" cannot be read as
     * "sun" plus noise. Chinese has no spaces, so its tokens are substring matches by necessity.
     */
    private fun weekdayOf(lowered: String): Int? {
      val english = listOf(
        Regex("""\b(monday|mon)\b""") to 1, Regex("""\b(tuesday|tue|tues)\b""") to 2,
        Regex("""\b(wednesday|wed)\b""") to 3, Regex("""\b(thursday|thur|thur|thu)\b""") to 4,
        Regex("""\b(friday|fri)\b""") to 5, Regex("""\b(saturday|sat)\b""") to 6,
        Regex("""\b(sunday|sun)\b""") to 7,
      )
      english.firstOrNull { it.first.containsMatchIn(lowered) }?.let { return it.second }
      val chinese = listOf(
        "星期一" to 1, "周一" to 1, "礼拜一" to 1,
        "星期二" to 2, "周二" to 2, "礼拜二" to 2,
        "星期三" to 3, "周三" to 3, "礼拜三" to 3,
        "星期四" to 4, "周四" to 4, "礼拜四" to 4, "周五" to 5, "星期五" to 5, "礼拜五" to 5,
        "星期六" to 6, "周六" to 6, "礼拜六" to 6,
        "星期日" to 7, "星期天" to 7, "周日" to 7, "礼拜天" to 7,
      )
      return chinese.firstOrNull { lowered.contains(it.first) }?.second
    }

    /** Minutes past midnight, or null. Understands `15:00`, `3pm`, `3:30 pm`, 三点半, 十五点 and 上午/下午 hints. */
    fun resolveClock(text: String): Int? {
      Regex("""(\d{1,2}):(\d{2})\s*(am|pm)?""").find(text.lowercase())?.let { m ->
        val (hour, minute, marker) = m.destructured
        return normalizeHour(hour.toInt(), minute.toInt(), marker, text)
      }
      Regex("""(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)""").find(text.lowercase())?.let { m ->
        val (hour, marker) = m.destructured
        return normalizeHour(hour.toInt(), 0, marker, text)
      }
      Regex("""(\d{1,2})\s*点(?:半|\d{1,2}分?)?""").find(text)?.let { m ->
        val spoken = m.groupValues[1].toIntOrNull() ?: return null
        val minutes = if (m.value.contains("半")) 30 else 0
        return normalizeHour(spoken, minutes, if (text.contains("下午") || text.contains("晚上")) "pm" else if (text.contains("上午") || text.contains("早上") || text.contains("中午")) "am" else "", text)
      }
      CHINESE_NUMERAL.find(text)?.let { m ->
        val hour = chineseNumber(m.value) ?: return null
        val minutes = if (text.substring(m.range.last() + 1).startsWith("半")) 30 else 0
        return normalizeHour(hour, minutes, if (text.contains("下午") || text.contains("晚上")) "pm" else "", text)
      }
      return null
    }

    private fun normalizeHour(hour: Int, minute: Int, marker: String, text: String): Int? {
      if (hour !in 1..24 || minute !in 0..59) return null
      val pm = marker.lowercase().startsWith("p") || text.contains("下午") || text.contains("晚上")
      val adjusted = when {
        pm && hour < 12 -> hour + 12
        !pm && hour == 12 -> 0
        else -> hour % 24
      }
      return adjusted * 60 + minute
    }

    private fun clockRange(text: String): Int? {
      val matches = Regex("""(?:\d{1,2}:\d{2}|\d{1,2}\s*(?:点|am|pm))""").findAll(text.lowercase()).toList()
      if (matches.size < 2) return null
      val second = resolveClock(matches[1].value) ?: return null
      return second
    }

    private val CHINESE_NUMERAL = Regex("""[一二两三四五六七八九十]{1,3}(?=点)""")

    private fun chineseNumber(text: String): Int? = when (text) {
      "一" -> 1; "二" -> 2; "两" -> 2; "三" -> 3; "四" -> 4; "五" -> 5; "六" -> 6; "七" -> 7; "八" -> 8; "九" -> 9; "十" -> 10
      "十一" -> 11; "十二" -> 12; "十三" -> 13; "十四" -> 14; "十五" -> 15; "十六" -> 16; "十七" -> 17; "十八" -> 18; "十九" -> 19; "二十" -> 20
      else -> null
    }

    /** The words the user called the thing, with the trigger and the clock stripped. Never invents a title. */
    internal fun titleOf(text: String): String? {
      val cleaned = text.replace(Regex("""@助理|/[^\s]+"""), " ").replace(Regex("""\d{1,2}(:\d{2})?\s*(am|pm|点|半)"""), " ")
        .replace(Regex("""[一二两三四五六七八九十]{1,3}点(半|\d{1,2}分?)?"""), " ").replace(Regex("""今天|明天|后天|下周|上午|下午|晚上|早上"""), " ")
        .replace(Regex("""\s+"""), " ").trim()
      if (cleaned.isEmpty()) return null
      return cleaned.split(Regex("""[,，.。;；]""")).firstOrNull { it.isNotBlank() }?.trim()?.takeIf { it.length in 2..60 }
    }

    internal fun refOf(text: String): String {
      val stripped = text.replace(Regex("""@助理|/[^\s]+"""), " ").replace(CANCEL, " ").replace(RESCHEDULE, " ")
        .replace(Regex("""\b(cancel|move|reschedule|postpone|shift|push|delete|drop|call off)\b""", RegexOption.IGNORE_CASE), " ")
        .replace(Regex("""取消|删除|改到|改期|挪到|推到|把"""), " ").replace(Regex("""\d{1,2}(:\d{2})?\s*(am|pm)"""), " ")
        .replace(Regex("""[一二两三四五六七八九十]{1,3}点(半)?"""), " ")
        .replace(Regex("""today|tomorrow|明天|今天|后天|周[一二三四五六日天]|星期[一二三四五六日天]""", RegexOption.IGNORE_CASE), " ")
        .replace(Regex("""\s+"""), " ").trim().trim('?', '？', '!', '.', '。')
      return stripped.takeIf { it.isNotEmpty() }?.take(60) ?: ""
    }

    /** Only a real file reference counts: the assistant never queues work over a word that happens to be "pdf". */
    internal fun fileRefOf(text: String): String? {
      Regex("""([\w \-]+\.(pdf|docx?|txt|md|csv|pptx|xlsx|epub|png|jpe?g))""", RegexOption.IGNORE_CASE).find(text)?.let { return it.groupValues[1].trim() }
      Regex("""(.+?(?:文件|文档|pdf|合同|报告|说明书))""").find(text)?.let {
        // The non-greedy group starts wherever the sentence starts, so the request verb travels with it:
        // 「总结这份文档」 would otherwise be filed as a reference named "总结这份文档". Only a leading verb run is
        // cut, never anything after the noun.
        val candidate = it.groupValues[1].trim().replace(LEADING_VERB, "").trim()
        if (candidate.length in 2..80) return candidate
      }
      Regex("""\b(?:the|my|this)\s+([\w \-]{2,60}?(?:document|file|report|contract|pdf|doc))""", RegexOption.IGNORE_CASE).find(text)?.let { return it.groupValues[1].trim() }
      return null
    }
  }
}

/** Slash commands, which are the unambiguous half of the summon path. */
enum class PopopxEcoCommand(val literal: String) {
  CheckAvailability("/查空闲"),
  BookTime("/约时间"),
  MoveTime("/改时间"),
  CancelTime("/取消日程"),
  SummarizeFile("/总结文件");

  companion object {
    fun parse(text: String): PopopxEcoCommand? = entries.firstOrNull { text.contains(it.literal) }

    /** `@助理` is the summon, not a command: it authorizes a turn without choosing the tool. */
    fun isSummon(text: String) = text.contains("@助理") || text.contains("@assistant", ignoreCase = true)
  }
}


/** The two-digit and four-digit zero padding the ISO forms need, without `String.format` (JVM-only). */
internal fun pad2(value: Int): String = if (value < 10) "0$value" else "$value"

internal fun pad4(value: Int): String = value.toString().padStart(4, '0')

internal const val MINUTES_PER_DAY = 1_440L

/**
 * The clock, from the platform. A day and a minute-of-day are the only facts the engine needs, and
 * both are read on each turn rather than captured, because a long-lived assistant must answer
 * "tomorrow at 3" correctly the next morning.
 */
expect fun popopxToday(): EcoDate

expect fun popopxNowMinutesPastMidnight(): Int
