package chat.popopx.common.copilot

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The deterministic engine's five tools, in the two languages the product actually sees, against a fixed
 * Thursday. Nothing in these tests reads a clock: [FIXTURE_FACTS] is passed in, and the engine resolves
 * "tomorrow at 4" from it.
 */
class PopopxIntentParsingTest {
  private val engine = PopopxDeterministicEngine()

  private fun parse(input: String): PopopxEcoEnvelope = engine.parse(input, FIXTURE_FACTS)

  private fun onlyCall(input: String): PopopxEcoCall {
    val envelope = parse(input)
    assertEquals(1, envelope.calls.size, "expected exactly one call from: $input, got ${envelope.calls} (failure=${envelope.failure}, reasoning=${envelope.reasoning})")
    assertTrue(envelope.suppressed.isEmpty(), "nothing should be suppressed for: $input")
    assertEquals(1.0, envelope.confidence ?: -1.0, 0.0)
    assertEquals("deterministic match against 2026-11-26", envelope.reasoning)
    return envelope.calls.single()
  }

  @Test
  fun availabilityEnglishResolvesTheWindowTheUserGave() {
    val call = onlyCall("when am I free 14:00 to 16:00 tomorrow?")
    assertEquals(PopopxEcoTool.GetAvailability, call.tool)
    assertEquals("calendar.get_availability", call.tool.wireName)
    call as EcoGetAvailability
    // "tomorrow" against a Thursday fixture, and the second clock is the end rather than start+60.
    assertEquals("2026-11-27T14:00", call.from)
    assertEquals("2026-11-27T16:00", call.to)
    assertEquals("2026-11-27T14:00", call.argumentString("from"))
    assertEquals("2026-11-27T16:00", call.argumentString("to"))
  }

  @Test
  fun availabilityChineseUnderstandsSpokenHours() {
    val call = onlyCall("我明天下午三点有空吗")
    assertEquals(PopopxEcoTool.GetAvailability, call.tool)
    call as EcoGetAvailability
    assertEquals("2026-11-27T15:00", call.from)
    // One clock only, so the end is the default hour, not a guess at when the user stops being free.
    assertEquals("2026-11-27T16:00", call.to)
  }

  @Test
  fun createEnglishProposesWithADefaultedEnd() {
    val call = onlyCall("book a meeting tomorrow at 10am")
    assertEquals(PopopxEcoTool.ProposeCreate, call.tool)
    assertEquals("calendar.propose_create", call.tool.wireName)
    call as EcoProposeCreate
    assertEquals("2026-11-27T10:00", call.start)
    assertEquals("2026-11-27T11:00", call.end)
    assertEquals(60, call.durationMinutes())
    // titleOf strips the clock but keeps the user's own phrasing; it never invents a title.
    assertTrue(call.title?.startsWith("book a meeting") == true, "title was ${call.title}")
    assertEquals("10:00", call.argumentString("start")?.takeLast(5))
  }

  @Test
  fun createChineseFromASlashCommandKeepsTheUsersTitle() {
    val call = onlyCall("/约时间 明天下午三点 复盘会")
    assertEquals(PopopxEcoTool.ProposeCreate, call.tool)
    call as EcoProposeCreate
    assertEquals("复盘会", call.title)
    assertEquals("2026-11-27T15:00", call.start)
    assertEquals("2026-11-27T16:00", call.end)
  }

  @Test
  fun rescheduleMovesAnExistingEventAndDoesNotCreateOne() {
    val english = onlyCall("push the dentist to 4pm tomorrow")
    assertEquals(PopopxEcoTool.ProposeReschedule, english.tool)
    assertEquals("calendar.propose_reschedule", english.tool.wireName)
    assertEquals("2026-11-27T16:00", (english as EcoProposeReschedule).newStart)
    assertTrue(english.eventRef.contains("dentist"), "eventRef was ${english.eventRef}")

    val chinese = onlyCall("把牙医改到明天下午四点") as EcoProposeReschedule
    assertEquals("2026-11-27T16:00", chinese.newStart)
    assertTrue(chinese.eventRef.contains("牙医"), "eventRef was ${chinese.eventRef}")
  }

  @Test
  fun cancelCarriesAReferenceAndNoTime() {
    val english = onlyCall("cancel the dentist appointment")
    assertEquals(PopopxEcoTool.ProposeCancel, english.tool)
    assertEquals("calendar.propose_cancel", english.tool.wireName)
    assertEquals("the dentist appointment", (english as EcoProposeCancel).eventRef)

    val chinese = onlyCall("/取消日程 牙医的预约") as EcoProposeCancel
    assertEquals("牙医的预约", chinese.eventRef)
  }

  @Test
  fun dispatchNamesAFileAndNothingElse() {
    // The ASCII file grammar is `[\w -]+\.(pdf|…)`, which lets a space through, so a bare sentence keeps its
    // verb inside the reference — "summarize onboarding.pdf" is what the token actually was. The Chinese
    // branch has no such ambiguity (a file name does not contain a space in practice) and cuts the leading
    // verb run, so 「帮我总结」 does not travel into the reference.
    val english = onlyCall("summarize onboarding.pdf")
    assertEquals(PopopxEcoTool.DispatchTask, english.tool)
    assertEquals("node.dispatch_task", english.tool.wireName)
    english as EcoDispatchTask
    assertEquals("summarize", english.task)
    assertEquals("summarize onboarding.pdf", english.payloadRef)
    assertNull(english.priority)
    // The engine emits a bare verb, so it cannot satisfy the dispatcher's service/action gate by itself.
    assertNull(english.service)
    assertNull(english.action)

    val clean = onlyCall("/总结文件 onboarding.pdf") as EcoDispatchTask
    assertEquals("onboarding.pdf", clean.payloadRef)

    val chinese = onlyCall("帮我总结季度报告.pdf") as EcoDispatchTask
    assertEquals("季度报告", chinese.payloadRef, "the request verb is not part of the document's name")
    assertEquals("summarize", chinese.task)
  }

  @Test
  fun availabilityWithoutAClockAsksForTheWholeDay() {
    // 「查空闲」 is a question, not a booking: no clock is needed, and the answer is the day's span.
    val command = onlyCall("/查空闲 明天") as EcoGetAvailability
    assertEquals("2026-11-27T00:00", command.from)
    assertEquals("2026-11-28T00:00", command.to)

    val spoken = onlyCall("are you free on Monday") as EcoGetAvailability
    assertEquals("2026-11-30T00:00", spoken.from, "the first Monday on or after Thursday 2026-11-26")
    assertEquals("2026-12-01T00:00", spoken.to)
  }

  @Test
  fun refusesToGuessWhatItWasNotTold() {
    assertTrue(parse("").isEmpty, "empty input")
    assertTrue(parse("   ").isEmpty, "blank input")
    assertTrue(parse("what is the weather like").isEmpty, "no tool, no time")
    // A booking still needs a clock, even when the day is named.
    assertTrue(parse("book a meeting sometime next week").isEmpty, "week without a clock")
    // A cancel with nothing to point at stays a refusal.
    assertTrue(parse("cancel").isEmpty, "no event reference")
  }

  @Test
  fun aDefaultedEndCrossingMidnightRollsOntoTheNextDate() {
    val late = engine.parse("book a call today at 23:30", FIXTURE_FACTS).calls.single() as EcoProposeCreate
    assertEquals("2026-11-26T23:30", late.start)
    assertEquals("2026-11-27T00:30", late.end)

    val noon = engine.parse("meet at 12pm today", FIXTURE_FACTS).calls.single() as EcoProposeCreate
    assertEquals("2026-11-26T12:00", noon.start)
    assertEquals("2026-11-26T13:00", noon.end)
  }

  @Test
  fun theWireSchemaDeclaresExactlyTheFiveTools() {
    val json = popopxEcoToolsJson()
    PopopxEcoTool.entries.forEach { assertTrue(json.contains("\"${it.wireName}\""), "missing ${it.wireName}") }
    assertEquals(5, PopopxEcoTool.entries.size)
    assertEquals(PopopxEcoTool.GetAvailability, PopopxEcoTool.fromWireName("calendar.get_availability"))
    assertNull(PopopxEcoTool.fromWireName("calendar.delete_everything"))
  }

  @Test
  fun anUnknownToolInTheEngineReplyIsDroppedRatherThanGuessed() {
    val envelope = PopopxEcoEnvelope.fromEngineJson(
      """
        {"function_calls":[
          {"name":"calendar.delete_everything","arguments":{}},
          {"name":"calendar.propose_cancel","arguments":{"event_ref":"evt-9"}}],
         "confidence":0.42,"reasoning":"needle"}
      """.trimIndent(),
    )
    assertEquals(1, envelope.calls.size, envelope.calls.toString())
    assertEquals(PopopxEcoTool.ProposeCancel, envelope.calls.single().tool)
    assertEquals("evt-9", (envelope.calls.single() as EcoProposeCancel).eventRef)
    assertEquals(0.42, envelope.confidence ?: -1.0, 0.0)
    assertEquals("needle", envelope.reasoning)
    assertNull(envelope.failure)

    assertEquals("unparseable engine reply", PopopxEcoEnvelope.fromEngineJson("{not json").failure)
    assertTrue(PopopxEcoEnvelope.fromEngineJson("{}").isEmpty)
    // A suppressed call still becomes a card, and only one card per tool.
    val deduped = PopopxEcoEnvelope.fromEngineJson(
      """{"function_calls":[{"name":"calendar.propose_cancel","arguments":{"event_ref":"a"}}],
        "suppressed_calls":[{"name":"calendar.propose_cancel","arguments":{"event_ref":"b"}}]}""",
    )
    assertEquals(2, deduped.calls.size + deduped.suppressed.size)
    assertEquals(1, deduped.suggestions().size)
  }
}

/**
 * The digest helper and the fail-closed asset gate.
 *
 * Both reference digests were measured with `shasum -a 256` (empty input, and the string `abc`) rather
 * than copied from a comment, and the model constants were measured over the weights file itself.
 */
class PopopxNeedleAssetsTest {
  @Test
  fun sha256MatchesTheReferenceDigests() {
    assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", popopxSha256Hex(ByteArray(0)))
    assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", popopxSha256Hex("abc".encodeToByteArray()))
    val hex = popopxSha256Hex("popopx".encodeToByteArray())
    // The 64-char lowercase-hex shape is what the constant-time comparison assumes.
    assertEquals(64, hex.length)
    assertTrue(hex.all { it in '0'..'9' || it in 'a'..'f' }, "not lowercase hex: $hex")
    assertEquals(hex, popopxSha256Hex("popopx".encodeToByteArray()), "digest must be stable across calls")
    assertNotEquals(hex, popopxSha256Hex("pOpOpX".encodeToByteArray()))
    assertNotEquals(hex, popopxSha256Hex("popopx ".encodeToByteArray()))
  }

  @Test
  fun assetConstantsDescribeARealFile() {
    assertEquals("assets/needle3.cact", PopopxNeedleAssets.modelPath)
    assertEquals(64, PopopxNeedleAssets.modelSha256.length)
    assertTrue(PopopxNeedleAssets.modelSha256.all { it in '0'..'9' || it in 'a'..'f' })
    assertEquals(35_335_380L, PopopxNeedleAssets.modelBytes)
    assertEquals("c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38", PopopxNeedleAssets.modelSha256)
  }

  @Test
  fun verificationRefusesBytesThatAreNotTheBundle() {
    assertFalse(popopxBundledModelAccepts(ByteArray(0)), "empty bytes")
    assertFalse(popopxBundledModelAccepts("abc".encodeToByteArray()), "wrong size and wrong digest")
    // Right length, wrong contents: the length check alone must not be what lets bytes through.
    assertFalse(popopxBundledModelAccepts(ByteArray(PopopxNeedleAssets.modelBytes.toInt())))
    assertFalse(popopxBundledModelAccepts(ByteArray(1)), "one byte")
  }

  @Test
  fun loadRefusesWhenTheBundleIsAbsentAndNeverHandsUnverifiedBytesToAnEngine() {
    if (!PopopxNeedleAssets.bundledModelPresent()) {
      // The asset is not in the tree yet on this machine: absence must refuse, never fabricate.
      val failure = assertFailsWith<IllegalStateException> { PopopxNeedleAssets.loadVerifiedModel() }
      assertTrue(failure.message?.contains("not present") == true, failure.message ?: "no message")
      return
    }
    val model = PopopxNeedleAssets.loadVerifiedModel()
    assertEquals(PopopxNeedleAssets.modelBytes, model.bytes.size.toLong())
    assertEquals(PopopxNeedleAssets.modelSha256, popopxSha256Hex(model.bytes))
    // Desktop ships no Needle runtime, so the verified bytes come back with the engine this platform uses.
    assertEquals(PopopxEdgeCopilotEngine.Kind.Deterministic, model.engine.kind)
    assertTrue(model.engine.ensureLoaded())
    assertTrue(model.engine.isLoaded)

    // Flip one byte: same length, different digest, and the gate must notice.
    val tampered = model.bytes.copyOf().also { it[0] = (it[0].toInt() xor 0xFF).toByte() }
    assertEquals(PopopxNeedleAssets.modelBytes, tampered.size.toLong())
    assertFalse(popopxBundledModelAccepts(tampered))
    assertNotEquals(PopopxNeedleAssets.modelSha256, popopxSha256Hex(tampered))
  }

  @Test
  fun desktopOffersOnlyTheDeterministicEngine() {
    val engines = popopxPlatformEngines(FIXTURE_FACTS)
    assertEquals(1, engines.size)
    assertEquals(PopopxEdgeCopilotEngine.Kind.Deterministic, engines.single().kind)
    assertTrue(engines.single().ensureLoaded())
    // No Needle engine on desktop: nothing here may claim that kind.
    assertTrue(engines.none { it.kind == PopopxEdgeCopilotEngine.Kind.Needle })
  }
}

/**
 * THE desensitisation rule. These events are saturated with words that must not survive the sanitizer,
 * and the assertion reads every String the returned values can produce — including the sentences the
 * planner and the confirm card would show — rather than trusting the type shapes.
 */
class PopopxCalendarPrivacyTest {
  private val windowStart = at(THURSDAY, 8)
  private val windowEnd = at(THURSDAY, 18)

  private fun event(start: Long, end: Long, title: String, location: String, attendees: List<String>, notes: String) =
    PopopxRawCalendarEvent(start, end, title, location, attendees, notes)

  private val events = listOf(
    // 07:00–08:30: hangs off the front of the window, so it exercises clipping.
    event(at(THURSDAY, 7), at(THURSDAY, 8, 30), "Onco trial kickoff", "Clinic 4B", listOf("dr.ellis@popopx.im"), "NDA"),
    // 09:00–10:30 and 10:00–11:00: overlapping, so they must merge into one busy interval.
    event(at(THURSDAY, 9), at(THURSDAY, 10, 30), "Biopsy review", "Clinic 4B", listOf("dr.ellis@popopx.im"), "NDA"),
    event(at(THURSDAY, 10), at(THURSDAY, 11), "Onco follow-up", "Room 2", emptyList(), "trial kickoff"),
    // 20:00–21:00: entirely past the window, so it must be dropped by the clip and not by luck.
    event(at(THURSDAY, 20), at(THURSDAY, 21), "NDA signing", "Onco suite", listOf("dr.ellis@popopx.im"), "Biopsy"),
  )

  @Test
  fun busySlotsClipToTheWindowAndMergeOverlaps() {
    val busy = PopopxCalendarPrivacy.busySlots(events, windowStart, windowEnd)
    assertEquals(
      listOf(
        // 07:00–08:30 clipped at the window start
        PopopxEcoBusySlot(at(THURSDAY, 8), at(THURSDAY, 8, 30)),
        // 09:00–10:30 merged with 10:00–11:00
        PopopxEcoBusySlot(at(THURSDAY, 9), at(THURSDAY, 11)),
      ),
      busy,
    )
    assertEquals(30, busy[0].durationMinutes)
    assertEquals(120, busy[1].durationMinutes)
    assertTrue(busy.none { it.startEpochMinutes >= windowEnd }, "the 20:00 event leaked: $busy")
  }

  @Test
  fun bufferWidensExistingEventsAndCanAbsorbASlotEntirely() {
    val buffered = PopopxCalendarPrivacy.busySlotsWithBuffer(events, windowStart, windowEnd, bufferMinutes = 15)
    // 08:00–08:45 (clipped buffer) meets 08:45–11:15 (widened merge) at exactly 08:45, so they become one.
    assertEquals(listOf(PopopxEcoBusySlot(at(THURSDAY, 8), at(THURSDAY, 11, 15))), buffered)
    assertEquals(195, buffered.single().durationMinutes)

    val free = PopopxCalendarPrivacy.freeSlots(events, windowStart, windowEnd, preferences(buffer = 15), eventMinutes = 60)
    // Without the buffer 11:00–12:00 is free; the buffer leaves 45 minutes, which is under an hour.
    assertEquals(listOf(PopopxEcoBusySlot(at(THURSDAY, 13), at(THURSDAY, 18))), free)
  }

  @Test
  fun freeSlotsAreTheGapsUnderWorkingHoursMinusLunch() {
    val free = PopopxCalendarPrivacy.freeSlots(events, windowStart, windowEnd, preferences(buffer = 0), eventMinutes = 60)
    assertEquals(
      listOf(
        PopopxEcoBusySlot(at(THURSDAY, 11), at(THURSDAY, 12)),
        PopopxEcoBusySlot(at(THURSDAY, 13), at(THURSDAY, 18)),
      ),
      free,
    )
    assertEquals("2026-11-26T11:00", free[0].toLocalRange().first.isoLocal())
    assertEquals("2026-11-26T18:00", free[1].toLocalRange().second.isoLocal())
    // An event longer than the gap removes it: 11:00–12:00 is an hour, so 90 minutes cannot fit.
    val longer = PopopxCalendarPrivacy.freeSlots(events, windowStart, windowEnd, preferences(buffer = 0), eventMinutes = 90)
    assertEquals(listOf(PopopxEcoBusySlot(at(THURSDAY, 13), at(THURSDAY, 18))), longer)
  }

  @Test
  fun noStringReachableFromTheSanitizerHoldsAnEventWord() {
    val busy = PopopxCalendarPrivacy.busySlotsWithBuffer(events, windowStart, windowEnd, bufferMinutes = 15)
    val free = PopopxCalendarPrivacy.freeSlots(events, windowStart, windowEnd, preferences(buffer = 15, weekends = true), eventMinutes = 60)

    val surfaces = ArrayList<String>()
    (busy + free).forEach { slot ->
      surfaces.add(slot.toString())
      surfaces.add("${slot.startEpochMinutes}/${slot.endEpochMinutes}/${slot.durationMinutes}")
      val (from, to) = slot.toLocalRange()
      surfaces.add(from.isoLocal())
      surfaces.add(to.isoLocal())
      surfaces.add("${from.epochMinutes}")
      surfaces.add("${slot.contains(from)}")
    }
    surfaces.add(PopopxCalendarPrivacy.window(FIXTURE_FACTS.now, 24).toString())

    // The sentences the assistant would actually show, built from numbers and from the user's own words.
    val availability = PopopxEcoPlanner.plan(EcoGetAvailability(FIXTURE_FACTS.now.isoLocal(), FIXTURE_FACTS.now.plusMinutes(60).isoLocal()), FIXTURE_FACTS, busy)
    surfaces.add((availability as PopopxEcoPlan.Answer).text)

    val proposals = listOf(
      EcoCreateEvent("复盘会", EcoDateTime(EcoDate(2026, 11, 27), 15 * 60), EcoDateTime(EcoDate(2026, 11, 27), 16 * 60)),
      EcoRescheduleEvent("evt-42", EcoDateTime(EcoDate(2026, 11, 27), 16 * 60), 60),
      EcoCancelEvent("evt-42"),
    )
    proposals.forEach { proposal ->
      surfaces.add(proposal.description)
      surfaces.add(proposal.whenText)
      surfaces.add(proposal.write().toString())
      surfaces.add(PopopxEcoICS.calendar(proposal, FIXTURE_FACTS.now.epochMinutes))
      surfaces.add(PopopxEcoPlanner.plan(EcoProposeCancel("evt-42"), FIXTURE_FACTS, busy).toString())
    }

    val haystack = surfaces.joinToString("|").lowercase()
    // Word boundaries, because a raw substring scan hits "…vCalendar" for "NDA" and "…Monday" for "DA".
    val leaked = SECRETS.filter { secret -> Regex("""\b${Regex.escape(secret)}\b""", RegexOption.IGNORE_CASE).containsMatchIn(haystack) }
    assertTrue(leaked.isEmpty(), "leaked $leaked into: ${haystack.take(600)}")
    // The busy set is still described in words — with times, and only times.
    assertTrue(haystack.contains("2026-11-26t"), "expected local times in the answer text: $haystack")
    assertTrue(surfaces.size >= 25, "expected many surfaces to check, was ${surfaces.size}")
  }

  @Test
  fun conflictsReportTheIntervalThatCollidedAndBufferChangesTheAnswer() {
    // Clipped to the proposed slot, which is the honest shape of the answer: 09:00–10:00 of a 09:00–11:00 block.
    assertEquals(
      PopopxEcoBusySlot(at(THURSDAY, 9), at(THURSDAY, 10)),
      PopopxCalendarPrivacy.conflicts(events, EcoDateTime(EcoDate(2026, 11, 26), 9 * 60), 60),
    )
    // 11:00 is free by twenty minutes of margin, and a 15-minute buffer takes it away.
    assertNull(PopopxCalendarPrivacy.conflicts(events, EcoDateTime(EcoDate(2026, 11, 26), 11 * 60), 30))
    assertEquals(
      PopopxEcoBusySlot(at(THURSDAY, 11), at(THURSDAY, 11, 15)),
      PopopxCalendarPrivacy.conflicts(events, EcoDateTime(EcoDate(2026, 11, 26), 11 * 60), 30, bufferMinutes = 15),
    )
  }

  private fun preferences(buffer: Int, weekends: Boolean = false) = PopopxTimePreferences(
    workingMinutes = listOf(PopopxTimePreferences.MinuteRange(9 * 60, 18 * 60)),
    lunch = PopopxTimePreferences.MinuteRange(12 * 60, 13 * 60),
    avoidWeekends = weekends,
    bufferMinutes = buffer,
    minimumSlotMinutes = 15,
  )
}
