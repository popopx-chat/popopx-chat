package chat.popopx.common.signal

// Ported from apps/ios/Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift:1152-1205.
//
// Why `parse` requires whole-string equality rather than contains (Models:1153-1156): `contains`
// would turn a sentence like "look at this screenshot of ::popopx_sys::" into an executable
// signaling message. The trim-then-prefix boundary is the only safe one, and the renderer's
// suppression logic shares it — there is one copy of the criterion, [isSignalText].

/** Every way a `::popopx_sys::` frame can be hostile, named rather than swallowed (task item 7). */
sealed class PopopxSignalParseResult {
  data class Parsed(val signal: PopopxSignal) : PopopxSignalParseResult()

  sealed class NotSignal : PopopxSignalParseResult() {
    /** Models:1166 — the text does not start with the marker, including prose that merely quotes it. */
    data object MissingPrefix : NotSignal()

    /** Models:1171 — no `::` after the marker at all, e.g. the bare marker or `KIND:abc`. */
    data object MissingBodySeparator : NotSignal()

    /**
     * Models:1175 — the kind text is not one of the thirteen, byte for byte. `kindText` is kept
     * for the log line only; it is hostile input and is never echoed into a send.
     */
    data class UnknownKind(val kindText: String) : NotSignal()

    /** Models:1176 — `KIND::` with nothing after the separator. */
    data object EmptyBody : NotSignal()

    /** Models:1177 — above [PopopxSignalLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS]; never decoded. */
    data class OversizeBody(val characters: Int) : NotSignal()
  }
}

/** Codec for `::popopx_sys::`. Pure: nothing here can throw, whatever the input is. */
object PopopxSysMarker {
  const val MARKER = "::popopx_sys::"

  /** The separator between kind and body. A kind name never contains one (Models:1168). */
  const val BODY_SEPARATOR = "::"

  /** Models:1160-1162 — `marker + kind + "::" + payload`, one spelling, shared by both directions. */
  fun wireString(signal: PopopxSignal): String = MARKER + signal.kind.raw + BODY_SEPARATOR + signal.payload

  fun wireString(kind: PopopxSignalKind, payload: String): String = wireString(PopopxSignal(kind, payload))

  /**
   * Typed parse. Mirrors Models:1164-1180 step for step:
   * trim whitespace (Swift `.whitespacesAndNewlines`, :1165), require the marker prefix (:1166),
   * drop the marker (:1167), split on the FIRST `::` only (:1171-1173) — a single colon is not a
   * separator, and `split(maxSplits:)` would have accepted `EXT_REDEEM_REQ:abc` by slicing a kind
   * that does not exist (Models:1168-1170) — then the three body guards (:1174-1178).
   *
   * The first-`::` split is what lets a `NODE_CMD` payload keep the host's own inner separators
   * (`shadow_cos::briefing::{...}`) and arrive unmangled (Models:1117-1119).
   */
  fun parseOutcome(wholeText: String): PopopxSignalParseResult {
    val trimmed = wholeText.trim { it.isWhitespace() }
    if (!trimmed.startsWith(MARKER)) return PopopxSignalParseResult.NotSignal.MissingPrefix
    val rest = trimmed.substring(MARKER.length)
    val separator = rest.indexOf(BODY_SEPARATOR)
    if (separator < 0) return PopopxSignalParseResult.NotSignal.MissingBodySeparator
    val kindText = rest.substring(0, separator)
    val payload = rest.substring(separator + BODY_SEPARATOR.length)
    val kind = PopopxSignalKind.from(kindText)
      ?: return PopopxSignalParseResult.NotSignal.UnknownKind(kindText)
    if (payload.isEmpty()) return PopopxSignalParseResult.NotSignal.EmptyBody
    if (payload.signalLength() > PopopxSignalLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS) {
      return PopopxSignalParseResult.NotSignal.OversizeBody(payload.signalLength())
    }
    return PopopxSignalParseResult.Parsed(PopopxSignal(kind, payload))
  }

  /** The nil-returning shape the Swift uses everywhere (`parse(wholeText:)`, Models:1164). */
  fun parse(wholeText: String): PopopxSignal? =
    (parseOutcome(wholeText) as? PopopxSignalParseResult.Parsed)?.signal

  /**
   * The render-suppression criterion, shared by the conversation row, the chat-list preview and
   * the notification banner (router header:10-12 — the banner needs it separately because it fires
   * synchronously before the delete).
   *
   * Divergence stated: iOS spells this as four OR-ed criteria (Models:1201-1204: this marker, the
   * eco control frame, the eco uplinks, and the server-config pair). Only the marker this package
   * owns is judged here; the app layer composes the union via [popopxSysSignalSuppression] so one
   * site carries all four and they cannot drift apart.
   */
  fun isSignalText(text: String): Boolean = parse(text) != null
}

/**
 * The composition the three UI sites should install. This package supplies only its own term:
 * the app layer adds the eco control frame, the eco uplinks and the server-config pair, which
 * iOS ORs into one criterion (Models:1201-1204) — one site carrying all four is the only shape
 * that cannot drift.
 */
fun interface PopopxRenderSuppression {
  fun suppresses(text: String): Boolean
}

fun popopxSysSignalSuppression(extra: (String) -> Boolean = { false }): PopopxRenderSuppression =
  PopopxRenderSuppression { PopopxSysMarker.isSignalText(it) || extra(it) }
