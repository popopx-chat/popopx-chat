package chat.popopx.common.copilot

import chat.popopx.common.discover.PopopxNodeServiceId
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

/**
 * The five things the on-device assistant is allowed to ask for. The names are the wire contract with the
 * bundled engine's `tools_json`, so they are spelled exactly as the schema declares them.
 */
enum class PopopxEcoTool(val wireName: String) {
  GetAvailability("calendar.get_availability"),
  ProposeCreate("calendar.propose_create"),
  ProposeReschedule("calendar.propose_reschedule"),
  ProposeCancel("calendar.propose_cancel"),
  DispatchTask("node.dispatch_task");

  companion object {
    fun fromWireName(name: String): PopopxEcoTool? = entries.firstOrNull { it.wireName == name }
  }
}

sealed interface PopopxEcoCall {
  val tool: PopopxEcoTool
  val arguments: JsonObject

  fun argumentString(key: String): String? = (arguments[key] as? JsonPrimitive)?.takeIf { !it.isNil }?.content?.trim()?.takeIf { it.isNotEmpty() }

  fun argumentInt(key: String): Int? = argumentString(key)?.toIntOrNull()
}

/** A window whose free time the user wants to know about; both bounds are local, no timezone is inferred. */
data class EcoGetAvailability(val from: String, val to: String) : PopopxEcoCall {
  override val tool = PopopxEcoTool.GetAvailability
  override val arguments = jsonObject("from" to from, "to" to to)
}

/**
 * A proposal, never a write: `start`/`end` are local date-times and `title` is the words the user used.
 * The engine sometimes answers `16:00` where the schema asks for a date-time; [normalize] is the only place
 * that gap is closed, because a proposal that reaches the calendar writer with a half-resolved time is worse
 * than a refusal.
 */
data class EcoProposeCreate(val title: String?, val start: String, val end: String?) : PopopxEcoCall {
  override val tool = PopopxEcoTool.ProposeCreate
  override val arguments = buildJsonObject {
    if (title != null) put("title", title)
    put("start", start)
    if (end != null) put("end", end)
  }

  /**
   * Resolves what the engine said into local date-times the card can show. A bare `16:00` is dated
   * with [facts]; a value that is not a time at all is left as it came, so [PopopxEcoPlanner] refuses
   * to plan it rather than guessing a day.
   */
  fun normalized(facts: PopopxEcoFacts, fallbackDurationMinutes: Int = DEFAULT_EVENT_MINUTES): EcoProposeCreate {
    val start = start.withDateOf(facts.today) ?: start.normalizeDateTime() ?: start
    val end = end?.withDateOf(facts.today) ?: start.defaultEnd(fallbackDurationMinutes)
    return EcoProposeCreate(title, start, end)
  }

  /** The booked length, from the pair of times if the engine gave both. */
  fun durationMinutes(fallback: Int = DEFAULT_EVENT_MINUTES): Int {
    val from = EcoDateTime.parse(start) ?: return fallback
    val to = end?.let { EcoDateTime.parse(it) } ?: return fallback
    return ((to.epochMinutes - from.epochMinutes).coerceAtLeast(1L)).toInt()
  }
}

data class EcoProposeReschedule(val eventRef: String, val newStart: String) : PopopxEcoCall {
  override val tool = PopopxEcoTool.ProposeReschedule
  override val arguments = jsonObject("event_ref" to eventRef, "new_start" to newStart)

  /** The new time, widened to today when the engine gave a clock without a day; null if it is not a time. */
  fun normalized(facts: PopopxEcoFacts): EcoProposeReschedule? {
    val start = newStart.withDateOf(facts.today) ?: newStart.normalizeDateTime() ?: return null
    return EcoProposeReschedule(eventRef, start)
  }
}

data class EcoProposeCancel(val eventRef: String) : PopopxEcoCall {
  override val tool = PopopxEcoTool.ProposeCancel
  override val arguments = jsonObject("event_ref" to eventRef)
}

/**
 * A heavy job handed to the paired Mac Node; the payload reference is a file name, never file contents.
 *
 * The engine emits `task` as one token, and the app's own dotted form for "a service and a thing it can
 * do" already exists ([chat.popopx.common.discover.PopopxNodeMenuAction.id]), so the token is parsed
 * against the paired service's accepted actions rather than being forwarded as free text.
 */
data class EcoDispatchTask(val task: String, val payloadRef: String?, val priority: Int?) : PopopxEcoCall {
  val service: PopopxNodeServiceId?
    get() = task.substringBeforeLast('.', "").takeIf { it.isNotEmpty() }?.let { head ->
      PopopxNodeServiceId.entries.firstOrNull { it.rawValue == head }
    }

  /** The action segment, and only when the token actually carries one. */
  val action: String?
    get() = task.substringAfterLast('.', "").takeIf { task.contains('.') && it.isNotEmpty() }

  override val tool = PopopxEcoTool.DispatchTask
  override val arguments = buildJsonObject {
    put("task", task)
    if (payloadRef != null) put("payload_ref", payloadRef)
    if (priority != null) put("priority", priority)
  }
}

/**
 * What the engine said about one turn. [suppressed] is not an error: the engine withholds a call it is not
 * confident about and puts it here, which is the same shape as the confirm-first rule this feature runs on, so
 * the UI turns a suppressed call into a card and an emitted call into nothing more.
 */
data class PopopxEcoEnvelope(
  val calls: List<PopopxEcoCall>,
  val suppressed: List<PopopxEcoCall>,
  val confidence: Double?,
  val reasoning: String?,
  val failure: String? = null,
) {
  val isEmpty: Boolean get() = calls.isEmpty() && suppressed.isEmpty()

  /** The calls worth showing a card for: emitted first, then withheld, each deduplicated by tool name. */
  fun suggestions(): List<PopopxEcoCall> {
    val seen = HashSet<PopopxEcoTool>()
    return (calls + suppressed).filter { seen.add(it.tool) }
  }

  companion object {
    val EMPTY = PopopxEcoEnvelope(emptyList(), emptyList(), null, null)

    /**
     * Parses the engine's own JSON. Unknown tool names and unreadable arguments are dropped rather than guessed
     * at, so a malformed model reply can never widen the set of things the app will do.
     */
    fun fromEngineJson(json: String): PopopxEcoEnvelope {
      val root = runCatching { Json.parseToJsonElement(json).jsonObject }.getOrNull() ?: return EMPTY.copy(failure = "unparseable engine reply")
      val error = root.stringOrNull("error")
      return PopopxEcoEnvelope(
        calls = parseCalls(root["function_calls"]),
        suppressed = parseCalls(root["suppressed_calls"]),
        confidence = (root["confidence"] as? JsonPrimitive)?.content?.toDoubleOrNull(),
        reasoning = root.stringOrNull("reasoning"),
        failure = error,
      )
    }

    private fun parseCalls(element: JsonElement?): List<PopopxEcoCall> {
      val array = element as? JsonArray ?: return emptyList()
      return array.mapNotNull { entry ->
        val obj = entry as? JsonObject ?: return@mapNotNull null
        val name = obj.stringOrNull("name") ?: return@mapNotNull null
        val args = obj["arguments"] as? JsonObject ?: return@mapNotNull null
        when (PopopxEcoTool.fromWireName(name)) {
          PopopxEcoTool.GetAvailability -> EcoGetAvailability(args.stringOrNull("from") ?: return@mapNotNull null, args.stringOrNull("to") ?: return@mapNotNull null)
          PopopxEcoTool.ProposeCreate -> EcoProposeCreate(args.stringOrNull("title"), args.stringOrNull("start") ?: return@mapNotNull null, args.stringOrNull("end"))
          PopopxEcoTool.ProposeReschedule -> EcoProposeReschedule(args.stringOrNull("event_ref") ?: return@mapNotNull null, args.stringOrNull("new_start") ?: return@mapNotNull null)
          PopopxEcoTool.ProposeCancel -> EcoProposeCancel(args.stringOrNull("event_ref") ?: return@mapNotNull null)
          PopopxEcoTool.DispatchTask -> EcoDispatchTask(args.stringOrNull("task") ?: return@mapNotNull null, args.stringOrNull("payload_ref"), args.stringOrNull("priority")?.toIntOrNull())
          null -> null
        }
      }
    }
  }
}

/** The schema the engine is given at load. Kept in code so the shipped tools and the parser cannot drift apart. */
fun popopxEcoToolsJson(): String = buildJsonArray {
  PopopxEcoTool.entries.forEach { tool ->
    add(
      buildJsonObject {
        put("name", tool.wireName)
        put("description", tool.description)
        put("parameters", tool.schema)
      }
    )
  }
}.toString()

private val PopopxEcoTool.description: String
  get() = when (this) {
    PopopxEcoTool.GetAvailability -> "Check when the user is free. Use for questions about availability or a proposed time. Never creates or changes an event."
    PopopxEcoTool.ProposeCreate -> "Book a NEW event that does not exist yet. Use only when the user asks to add, schedule or set up something new."
    PopopxEcoTool.ProposeReschedule -> "MOVE an event that already exists to a different time. Use when the user says move, push, shift or postpone. The event is not cancelled and not new."
    PopopxEcoTool.ProposeCancel -> "Delete an event that already exists. Use when the user says cancel, drop or call off."
    PopopxEcoTool.DispatchTask -> "Hand a heavy job such as summarising a document to the user's paired Mac computer. Use only when a file or document is named."
  }

private val PopopxEcoTool.schema: JsonObject
  get() = when (this) {
    PopopxEcoTool.GetAvailability -> objectSchema(
      "from" to stringProperty("window start, ISO 8601"),
      "to" to stringProperty("window end, ISO 8601"),
      required = listOf("from", "to"),
    )
    PopopxEcoTool.ProposeCreate -> objectSchema(
      "title" to stringProperty("short name for the event, in the user's words"),
      "start" to stringProperty("ISO 8601 local date-time"),
      "end" to stringProperty("ISO 8601 local date-time"),
      required = listOf("start", "end"),
    )
    PopopxEcoTool.ProposeReschedule -> objectSchema(
      "event_ref" to stringProperty("words identifying the existing event"),
      "new_start" to stringProperty("ISO 8601 local date-time"),
      required = listOf("event_ref", "new_start"),
    )
    PopopxEcoTool.ProposeCancel -> objectSchema(
      "event_ref" to stringProperty("words identifying the existing event"),
      required = listOf("event_ref"),
    )
    PopopxEcoTool.DispatchTask -> objectSchema(
      "task" to stringProperty("what to do, for example summarize"),
      "payload_ref" to stringProperty("the file or document named in the request"),
      required = listOf("task"),
    )
  }

private fun stringProperty(description: String) = buildJsonObject {
  put("type", "string")
  put("description", description)
}

private fun objectSchema(vararg properties: Pair<String, JsonObject>, required: List<String>) = buildJsonObject {
  put("type", "object")
  put("properties", buildJsonObject { properties.forEach { (key, value) -> put(key, value) } })
  put("required", JsonArray(required.map { JsonPrimitive(it) }))
}

private fun jsonObject(vararg entries: Pair<String, String>) = buildJsonObject { entries.forEach { (key, value) -> put(key, value) } }

private fun JsonObject.stringOrNull(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { !it.isNil }?.content?.trim()?.takeIf { it.isNotEmpty() }

private val JsonPrimitive.isNil: Boolean get() = !isString && content == "null"

/** A proposal with no end time is booked for this long; the same default the confirm card shows. */
internal const val DEFAULT_EVENT_MINUTES = 60

/**
 * Accepts what the engine actually emits for a time and returns a local date-time, or null when the value is
 * not a time at all. The engine writes `2026-11-27T15:00:00`, sometimes `16:00`, and occasionally a date with no
 * time; only the first two are resolved here, because inventing a time is how a wrong event gets booked.
 */
internal fun String.normalizeDateTime(): String? {
  val text = trim()
  if (Regex("""\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?""").matches(text)) return text.take(16)
  if (Regex("""\d{1,2}:\d{2}""").matches(text)) return text.padStart(5, '0')
  return null
}

/**
 * The end of a proposal whose engine reply gave no end time. A bare `16:00` stays bare, because the day is not
 * known here either; a full date-time gets the default duration added with real civil-date rollover.
 */
internal fun String.defaultEnd(minutes: Int): String? {
  val normalized = normalizeDateTime() ?: return null
  if (normalized.length == 5) return null
  val instant = EcoDateTime.parse(normalized) ?: return null
  return instant.plusMinutes(minutes).isoLocal()
}

/**
 * The start of a proposal whose engine reply was a bare clock time is not a start, so the caller keeps the
 * value it already has; this only widens `HH:mm` into a full local date-time when the date was resolved.
 */
internal fun String.withDateOf(date: EcoDate): String? {
  val normalized = normalizeDateTime() ?: return null
  return if (normalized.length == 5) "${date.iso()}T$normalized" else normalized
}
