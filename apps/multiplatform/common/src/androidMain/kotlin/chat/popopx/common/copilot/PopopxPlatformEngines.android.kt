package chat.popopx.common.copilot

/**
 * The engines Android can offer, best first.
 *
 * [NeedleCactusEngine] is listed ahead of [PopopxDeterministicEngine] because
 * [PopopxEcoAssistantState.ensureEngineLoaded] takes the first candidate whose `ensureLoaded()`
 * returns true, and the real model should win when it is available. Today it never is:
 * [NEEDLE_CACTUS_ENABLED] is false and the native shim is not in the apk, so `ensureLoaded()` returns
 * false on the first line and the deterministic engine answers. That ordering is what makes "dormant
 * by default, one flag from live" a property of this list rather than a change to the assistant.
 */
actual fun popopxPlatformEngines(facts: PopopxEcoFacts): List<PopopxEdgeCopilotEngine> =
  listOf(NeedleCactusEngine, PopopxDeterministicEngine())
