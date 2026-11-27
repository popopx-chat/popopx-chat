package chat.popopx.common.discover

import chat.popopx.common.crypto.sha256Hex

/**
 * Reader for the `::POPOPX_UPD::v1` upgrade notice a bonded Mac Node sends when a verified new release is
 * pending. Kotlin twin of `apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Node/PopopxNodeUpdateWire.swift`:
 * loose about the display fields, strict about the two commands.
 *
 * Producer side, quoted rather than guessed (`PopopxMacNode` main = e40f5e3):
 * - marker, version, field order — `Updates/UpdateModels.swift:484-516`
 * - the ceiling and what is dropped under it — `Models/MacNodeModels.swift:52` (`maxSignalPayloadCharacters`)
 *   plus `UpdateModels.swift:511-515` (drops `d`/`s`/`n`, never a command)
 * - command text — `UpdateCenter.swift:354-361` with `Models/MacNodeModels.swift:40`
 * - receipt provenance — `UpdateCenter.swift:219-228`: the HMAC is minted node-side, so the phone can only
 *   echo it, never construct one
 * - the line the phone actually receives — `Core/MacNodePopopxBridge.swift:2482-2486`: the card text, then a
 *   blank line and the body, with `Models/MacNodeModels.swift:1626-1631`
 * - the body the summary comes from — `PopopxMacNodeApp.swift:863-870` (bullet-prefixed, at most 8 lines)
 *
 * Two consequences shape the code:
 *
 * 1. The marker is **inside** a line, not the whole of it: the card text begins
 *    `✅ POPOPX 更新 / Update · ::POPOPX_UPD::v1|v=…`. A whole-string signal test therefore never hides it,
 *    and an in-line search is the only parse that works — the same choice
 *    `chat.popopx.common.eco.PopopxEcoMarker.parseVisibleCard` makes for the service cards.
 * 2. The commands are the payload. A missing `d`/`s`/`n` is a supported shape, not an error, but a command
 *    that does not carry the node's own `updates::approve::` / `updates::snooze::` prefix is refused:
 *    without that check, anyone able to send one message could make the phone echo an arbitrary string into
 *    the node's command channel.
 *
 * This module deliberately holds no transport. Sending the echoed command is the mount's job
 * (`PopopxSilentTransport.send(chatId, isGroup = false, text, live = false)`), which keeps the parse pure
 * enough to run under desktopTest and keeps the "echo byte-for-byte" claim in exactly one place.
 *
 * There is also no signature here. The upgrade notice is authenticated by the encrypted contact it arrives
 * over, exactly as the producer's own card is; the signed artifact beside it is [PopopxNodeFeedWire].
 */
object PopopxNodeUpdateWire {
  const val MARKER = "::POPOPX_UPD::"
  const val SCHEMA_VERSION = "v1"

  /** `NodeWire.commandPrefix` plus the service and verb, spelled out because the receiver checks both and
   * then echoes the whole command back byte-for-byte. */
  const val APPROVE_COMMAND_PREFIX = "::popopx_sys::NODE_CMD::updates::approve::"
  const val SNOOZE_COMMAND_PREFIX = "::popopx_sys::NODE_CMD::updates::snooze::"

  /** The producer keeps its own line under 1024 and trims display fields to do it. Twice that is certainly
   * not the producer's output, so it is refused rather than parsed.
   *
   * MEASURED DIFFERENCE against iOS, kept honest: Swift measures this in grapheme clusters, this measures
   * UTF-16 units, so a display field packed with non-BMP characters is counted differently at the boundary.
   * The producer's own ceiling is 1024 plain characters, nothing real comes near 2048 of either count, and
   * no accepted behaviour depends on the number — the commands are gated by prefix and echoed verbatim. */
  internal const val MAXIMUM_LINE_CHARACTERS = 2_048

  /** `PopopxMacNodeApp.swift:865`: the node puts at most eight bullet lines on the card. */
  const val MAXIMUM_SUMMARY_LINES = 8

  internal const val BULLET = "·"

  private const val APPROVE_SEPARATOR = "|approve="
  private const val SNOOZE_SEPARATOR = "|snooze="

  /** One parsed notice. A null display field means the producer dropped it under the size ceiling. */
  data class Notice(
    val version: String,
    val build: String?,
    val releasedAt: String?,
    /** Twelve hex characters of the package digest — the short form, not the digest. */
    val shortSha: String?,
    /** What the producer says how many summary lines exist, which can out-number what survives the body
     * truncation. Carried, not reconciled. */
    val summaryCount: String?,
    val approveCommand: String,
    val snoozeCommand: String,
    /** The bullet lines from the same message, prefix stripped, in the node's order. */
    val summaryLines: List<String>,
  ) {
    val hasSummary: Boolean get() = summaryLines.isNotEmpty()
  }

  /**
   * Parses the first `::POPOPX_UPD::v1` marker in a received message. Null means "not a card this build can
   * answer" — no marker, an unknown version, an oversized line, a missing command, or a command that is not
   * an update command. The caller then shows ordinary text, which is what the producer expects of a receiver
   * that has never seen this kind.
   */
  fun parseVisibleCard(text: String): Notice? {
    val start = text.indexOf(MARKER)
    if (start < 0) return null
    val stop = lineEnd(text, start)
    val line = text.substring(start, stop)
    if (line.length > MAXIMUM_LINE_CHARACTERS) return null
    val segments = line.substring(MARKER.length).split('|')
    if (segments.firstOrNull() != SCHEMA_VERSION) return null

    // Spelled as separators rather than as segments, because a command value is JSON and a naive split on
    // a vertical bar would cut it in half while still looking like a successful parse.
    val approveAt = line.indexOf(APPROVE_SEPARATOR)
    if (approveAt < 0) return null
    val snoozeAt = line.indexOf(SNOOZE_SEPARATOR, approveAt + APPROVE_SEPARATOR.length)
    if (snoozeAt < 0) return null
    val approve = line.substring(approveAt + APPROVE_SEPARATOR.length, snoozeAt)
    val snooze = line.substring(snoozeAt + SNOOZE_SEPARATOR.length)
    if (!approve.startsWith(APPROVE_COMMAND_PREFIX) || !snooze.startsWith(SNOOZE_COMMAND_PREFIX)) return null

    var version = ""
    var build: String? = null
    var releasedAt: String? = null
    var shortSha: String? = null
    var summaryCount: String? = null
    for (segment in segments.drop(1)) {
      val equals = segment.indexOf('=')
      if (equals < 0) continue
      val value = segment.substring(equals + 1)
      when (segment.substring(0, equals)) {
        "v" -> version = value
        "b" -> build = emptyToNull(value)
        "d" -> releasedAt = emptyToNull(value)
        "s" -> shortSha = emptyToNull(value)
        "n" -> summaryCount = emptyToNull(value)
      }
    }
    // The card is titled with the version; without it there is nothing to confirm.
    if (version.isEmpty()) return null

    return Notice(
      version = version,
      build = build,
      releasedAt = releasedAt,
      shortSha = shortSha,
      summaryCount = summaryCount,
      approveCommand = approve,
      snoozeCommand = snooze,
      summaryLines = summaryLines(text, stop),
    )
  }

  fun isUpdateCard(text: String): Boolean = parseVisibleCard(text) != null

  /** The bullet lines the node puts below the card. Split out so a caller can refresh the summary of a
   * stored notice without re-checking the commands. */
  fun summaryLines(text: String): List<String> {
    val start = text.indexOf(MARKER)
    if (start < 0) return emptyList()
    return summaryLines(text, lineEnd(text, start))
  }

  /** Index just past the last character of the marker's line. */
  private fun lineEnd(text: String, from: Int): Int {
    var index = from
    while (index < text.length && !isNewline(text[index])) index += 1
    return index
  }

  private fun summaryLines(text: String, from: Int): List<String> {
    val lines = ArrayList<String>()
    var index = from
    while (index < text.length) {
      var end = index
      while (end < text.length && !isNewline(text[end])) end += 1
      // Swift's split drops empty subsequences, so an empty line never reaches the prefix test.
      if (end > index) {
        val line = trimmed(text.substring(index, end))
        if (line.startsWith(BULLET)) {
          val summary = trimmed(line.substring(BULLET.length))
          // "（无更新说明 / no summary）" carries no bullet, so it never reaches here either.
          if (summary.isNotEmpty()) {
            lines.add(summary)
            if (lines.size == MAXIMUM_SUMMARY_LINES) return lines
          }
        }
      }
      index = end + 1
    }
    return lines
  }

  /** Swift's `Character.isNewline` is the Unicode Newline property rather than a line feed alone; mirroring
   * the whole set keeps both receivers cutting the card line at the same character, which decides whether a
   * later `approve=` still belongs to the card. All seven are BMP, so the UTF-16 unit is the exact value: a
   * surrogate half belongs to no newline and never ends the line on either platform. */
  private fun isNewline(character: Char): Boolean {
    // Spelled as code units rather than escapes so nothing in this file depends on how a lexer reads them.
    val value = character.code
    return value == 0x0A || value == 0x0B || value == 0x0C || value == 0x0D || value == 0x85 ||
      value == 0x2028 || value == 0x2029
  }

  /** `trimmingCharacters(in: .whitespaces)` is spaces and tabs only, and newlines never reach here anyway. */
  private fun trimmed(text: String): String = text.trim { it == ' ' || it.code == 0x09 }

  private fun emptyToNull(value: String): String? = if (value.isEmpty()) null else value
}

/** What the user chose on an upgrade card. The node sees only the echoed command; this is the phone's memory. */
enum class PopopxNodeUpdateDecision(val rawValue: String) {
  APPROVED("approved"),
  SNOOZED("snoozed"),
  ;

  companion object {
    /** Null for anything unrecognized, so a hand-edited settings value reads as "no decision" rather than as
     * one of the two. */
    fun from(text: String?): PopopxNodeUpdateDecision? = entries.firstOrNull { it.rawValue == text }
  }
}

/**
 * Stable identity of one notice's answer: a digest of the approve command, which carries the node's single-use
 * receipt. Both buttons of one card share it — the choice IS the card's state — and two notices of the same
 * version do not, because their receipts differ.
 *
 * The digest rather than the command itself, because the command is a credential-shaped string that has no
 * business being a filename or a settings key in clear text.
 */
fun popopxNodeReceiptKey(approveCommand: String): String =
  sha256Hex(approveCommand.encodeToByteArray()).take(16)
