package chat.popopx.common.discover

/**
 * The grammar of a node command (DiscoverCatalogModels.swift:50-98).
 *
 * A command travels as the marker body of an ordinary invisible text, so the prefix is stripped
 * or re-added by whoever talks to the wire, exactly as iOS does
 * (`PopopxBadgeCreditsModels.swift:1157-1167`, `PopopxSilentSignalingRouter.swift:643-646`).
 */
object PopopxNodeWire {
  /** `PopopxSysMarker.marker` (PopopxBadgeCreditsModels.swift:1157) plus `NODE_CMD` (DiscoverCatalogModels.swift:53). Displayed to the user as "silent signal", never as this string. */
  const val COMMAND_PREFIX = "::popopx_sys::NODE_CMD::"

  /** `PopopxNodeWire.commandPrefixLength`, DiscoverCatalogModels.swift:54: the literal is 24 characters. */
  const val COMMAND_PREFIX_LENGTH = 24

  /** `PopopxNodeWire.segmentSeparator`, DiscoverCatalogModels.swift:59. */
  const val SEGMENT_SEPARATOR = "::"

  /** `PopopxNodeWire.pairingCodePrefix`, DiscoverCatalogModels.swift:62. */
  const val PAIRING_CODE_PREFIX = "PPXNODE1"

  /**
   * `PopopxNodeWire.deterministicLockAction`, DiscoverCatalogModels.swift:64-67. Phantom Sentinel
   * owns no model in its path, and this is the action that makes that true: the card for it can be
   * produced offline and is byte-identical on every run, which is the whole point of the button.
   */
  const val DETERMINISTIC_LOCK_ACTION = "lock_all"

  /** The transport ceiling every message in this app inherits from the commerce codec. */
  val maximumSignalPayloadCharacters: Int get() = PopopxDiscoverLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS

  /**
   * `PopopxNodeWire.isAcceptedByNode` (DiscoverCatalogModels.swift:92-97), measured exactly:
   * the action and the payload must be non-empty, and the three SEGMENTS together with their two
   * separators must fit the 1024-character payload ceiling — the `::popopx_sys::NODE_CMD::` prefix
   * is NOT counted, so the full wire line may reach 1024 + 24 = 1048 characters.
   *
   * DEVIATION FROM THE BRIEF, stated rather than papered over: the brief described the budget as
   * "1024 minus 20". No such number exists in the Swift. `used + 4 <= 1024` is the measured rule
   * (`(segmentCount - 1) * segmentSeparator.count`, :92-97), 1024 is `maximumSignalPayloadCharacters`
   * (PopopxBadgeCreditsModels.swift:47, enforced at :1177), and 24 is the prefix length. Porting the
   * measured computation; a 1004-character limit would silently reject ~20 characters of payload the
   * host accepts, which is the kind of unannounced tightening this port is not for.
   */
  fun isAccepted(command: PopopxNodeCommand): Boolean {
    val used = command.serviceId.rawValue.length + command.action.length + command.payload.length
    return command.action.isNotEmpty() && command.payload.isNotEmpty() &&
      used + (PopopxDiscoverLimits.SEGMENT_COUNT - 1) * SEGMENT_SEPARATOR.length <=
      PopopxDiscoverLimits.MAXIMUM_SIGNAL_PAYLOAD_CHARACTERS
  }
}

/**
 * A structured command to an official node, carried as an invisible text
 * (DiscoverCatalogModels.swift:120-163).
 *
 * The payload is the node's problem, not the app's: iOS documents that the client cannot know
 * which token is meaningful offline, so `payload` stays `"{}"` for every menu button
 * (:130-133) — and a non-empty payload is required to even be accepted, so it is always at least
 * two characters (:93-95).
 */
data class PopopxNodeCommand(
  val serviceId: PopopxNodeServiceId,
  val action: String,
  val payload: String = "{}",
) {
  /** `signalPayload` (:123-124): the three segments, no prefix — what the codec counts. */
  val signalPayload: String
    get() = serviceId.rawValue + PopopxNodeWire.SEGMENT_SEPARATOR + action + PopopxNodeWire.SEGMENT_SEPARATOR + payload

  /** `wireString` (:126-128): prefix + [signalPayload] — what a transport sees. */
  val wireString: String get() = PopopxNodeWire.COMMAND_PREFIX + signalPayload

  /** `isAcceptedByNode` (:92-97, :156-158). */
  val isAcceptedByNode: Boolean get() = PopopxNodeWire.isAccepted(this)

  /** The wire line, but only if the node would accept it: null means "do not send this". */
  fun encode(): String? = if (isAcceptedByNode) wireString else null

  companion object {
    /**
     * `init?(signalPayload:)` (DiscoverCatalogModels.swift:137-154), split on `::` EXACTLY TWICE.
     *
     * The Swift splits in a bounded loop and appends whatever is left as the last segment, so a
     * `::` inside the payload survives instead of mangling the segment count. A naive
     * `split("::")` here would do the opposite, so this loop is deliberate, and
     * `payloadWithDoubleColonRoundTrips` pins it.
     *
     * `serviceId` and `action` are whitespace-trimmed; the payload is NOT (:143-146) — an
     * insignificant change to a JSON body would break a node that hashes it.
     */
    fun parse(signalPayload: String): PopopxNodeCommand? {
      val separator = PopopxNodeWire.SEGMENT_SEPARATOR
      val segmentCount = PopopxDiscoverLimits.SEGMENT_COUNT
      var remaining = signalPayload
      val segments = ArrayList<String>(segmentCount)
      while (segments.size < segmentCount - 1) {
        val index = remaining.indexOf(separator)
        if (index < 0) break
        segments.add(remaining.substring(0, index))
        remaining = remaining.substring(index + separator.length)
      }
      segments.add(remaining)
      if (segments.size != segmentCount) return null
      val serviceId = PopopxNodeServiceId.from(segments[0].trimWhitespace()) ?: return null
      val action = segments[1].trimWhitespace()
      if (action.isEmpty()) return null
      if (segments[2].isEmpty()) return null
      return PopopxNodeCommand(serviceId, action, segments[2])
    }

    /** `init?(wireString:)` (:171-186): trim the whole line, require the prefix, then [parse]. */
    fun parseWireString(text: String): PopopxNodeCommand? {
      val prefix = PopopxNodeWire.COMMAND_PREFIX
      val trimmed = text.trim { it.isWhitespace() || it == '\n' || it == '\r' }
      if (!trimmed.startsWith(prefix)) return null
      return parse(trimmed.substring(prefix.length))
    }

    /** Pairing text may arrive inside a forwarded message; this is the "is it a command at all" probe. */
    fun looksLikeWireString(text: String): Boolean = text.trim { it.isWhitespace() }.startsWith(PopopxNodeWire.COMMAND_PREFIX)

    private fun String.trimWhitespace(): String {
      var start = 0
      var end = length
      while (start < end && this[start].isWhitespace()) start++
      while (end > start && this[end - 1].isWhitespace()) end--
      return substring(start, end)
    }
  }
}
