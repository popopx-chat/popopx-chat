package chat.popopx.common.agent

import chat.popopx.common.crypto.base64UrlDecode
import chat.popopx.common.crypto.base64UrlEncode
import chat.popopx.common.crypto.ed25519PublicKey
import chat.popopx.common.crypto.ed25519Sign
import chat.popopx.common.crypto.ed25519Verify
import chat.popopx.common.discover.popopxJsonDecode
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Kotlin twin of `apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Agent/PopopxAgentTaskWire.swift`: the
 * `popopx.agent.task.v1` card an agent (or a bound Mac Node acting as one) sends, and the signed
 * `popopx.agent.receipt.v1` answer this device returns.
 *
 * Both sides are held to the same pinned literal bodies by `PopopxAgentTaskWireTest` (here) and
 * `PopopxAgentTaskWireTests.swift`, so an encoder that reorders a key, escapes `/`, or writes
 * `percent` as a JSON number fails a test instead of shipping two receivers that disagree.
 *
 * Shape on the wire is one line:
 *
 *     ::POPOPX_AGENT::v1::{"agent":"…","kind":"approval",…}
 *
 * A producer may prefix a human sentence; [PopopxAgentTaskWire.parseVisibleCard] searches the first
 * marker and reads to the end of its line, exactly like the Swift side.
 */
data class PopopxAgentTask(
  val taskId: String,
  val kind: Kind,
  val status: Status,
  val title: String,
  val agent: String? = null,
  val detail: String? = null,
  /** 0…100, present on a progress card that can state a number. */
  val percent: Int? = null,
  val steps: List<Step> = emptyList(),
  val permissions: List<String> = emptyList(),
  /** `retention == "zero"` on the wire. Drives the Zero retention tag; never assumed. */
  val retentionZero: Boolean = false,
  val choices: List<Choice> = emptyList(),
  val result: String? = null,
  /** The producer's own clock, carried unvalidated (display data, never ordering). */
  val updatedAt: String? = null,
) {
  enum class Kind(val raw: String) {
    PROGRESS("progress"),
    APPROVAL("approval"),
    CHOICE("choice"),
    RESULT("result"),
    ;

    companion object {
      fun from(raw: String): Kind? = entries.firstOrNull { it.raw == raw }
    }
  }

  enum class Status(val raw: String) {
    RUNNING("running"),
    AWAITING_APPROVAL("awaiting_approval"),
    COMPLETED("completed"),
    FAILED("failed"),
    CANCELLED("cancelled"),
    ;

    /** The two states the home screen treats as "there is something alive in this chat". */
    val isActive: Boolean get() = this == RUNNING || this == AWAITING_APPROVAL

    companion object {
      fun from(raw: String): Status? = entries.firstOrNull { it.raw == raw }
    }
  }

  data class Step(val label: String, val state: State) {
    enum class State(val raw: String) {
      PENDING("pending"),
      ACTIVE("active"),
      DONE("done"),
      FAILED("failed"),
      ;

      companion object {
        fun from(raw: String): State? = entries.firstOrNull { it.raw == raw }
      }
    }
  }

  data class Choice(val id: String, val label: String)

  val isActive: Boolean get() = status.isActive
}

object PopopxAgentTaskWire {
  const val MARKER = "::POPOPX_AGENT::"
  const val SCHEMA_VERSION = "v1"
  const val SCHEMA_IDENTIFIER = "popopx.agent.task.v1"

  /** One card is one line; the Swift ceiling is 8 192 characters and is counted in graphemes there
   * and UTF-16 units here. The difference only shows on hostile emoji-heavy lines, which are refused
   * on both sides either way. */
  const val MAXIMUM_LINE_CHARACTERS = 8_192
  const val MAXIMUM_STEPS = 12
  const val MAXIMUM_PERMISSIONS = 12
  const val MAXIMUM_CHOICES = 8

  private const val MAXIMUM_TITLE_CHARACTERS = 200
  private const val MAXIMUM_DETAIL_CHARACTERS = 500
  private const val MAXIMUM_LABEL_CHARACTERS = 120
  private const val MAXIMUM_AGENT_CHARACTERS = 64
  private const val MAXIMUM_RESULT_CHARACTERS = 500
  private const val MAXIMUM_TASK_ID_CHARACTERS = 64
  private const val MAXIMUM_UPDATED_AT_CHARACTERS = 40

  /** Keys in the order Foundation's `.sortedKeys` emits them; optional fields are omitted, so a
   * producer that drops a display field does not change any other field's bytes. */
  internal val TASK_KEYS = listOf(
    "agent", "choices", "detail", "kind", "percent", "permissions", "result",
    "retention", "schema", "status", "steps", "task", "title", "updated",
  )

  /**
   * Parses the first marker in a received message. Null means "not a card this build can draw" — no
   * marker, an unknown version, an oversized line, or any field that fails validation. The caller
   * then shows ordinary text.
   */
  fun parseVisibleCard(text: String): PopopxAgentTask? {
    val start = text.indexOf(MARKER)
    if (start < 0) return null
    var end = start + MARKER.length
    while (end < text.length && !isNewline(text[end])) end++
    val line = text.substring(start, end)
    if (line.length > MAXIMUM_LINE_CHARACTERS) return null
    val versionPrefix = SCHEMA_VERSION + "::"
    if (!line.startsWith(MARKER + versionPrefix)) return null
    val body = line.substring(MARKER.length + versionPrefix.length)
    if (body.isEmpty()) return null
    return parseBody(body)
  }

  fun isAgentTaskCard(text: String): Boolean = parseVisibleCard(text) != null

  /** The one-line message a producer sends. The body is the canonical JSON this file parses. */
  fun wireText(task: PopopxAgentTask): String =
    MARKER + SCHEMA_VERSION + "::" + canonicalBody(task).decodeToString()

  // MARK: Canonical body

  fun canonicalBody(task: PopopxAgentTask): ByteArray {
    val builder = StringBuilder()
    builder.append('{')
    var first = true
    fun key(name: String) {
      if (!first) builder.append(',')
      first = false
      appendQuoted(builder, name)
      builder.append(':')
    }

    task.agent?.takeIf { it.isNotEmpty() }?.let {
      key("agent"); appendQuoted(builder, it)
    }
    if (task.choices.isNotEmpty()) {
      key("choices")
      builder.append('[')
      task.choices.forEachIndexed { index, choice ->
        if (index > 0) builder.append(',')
        builder.append('{')
        appendQuoted(builder, "id"); builder.append(':')
        appendQuoted(builder, choice.id)
        builder.append(',')
        appendQuoted(builder, "label"); builder.append(':')
        appendQuoted(builder, choice.label)
        builder.append('}')
      }
      builder.append(']')
    }
    task.detail?.takeIf { it.isNotEmpty() }?.let {
      key("detail"); appendQuoted(builder, it)
    }
    key("kind"); appendQuoted(builder, task.kind.raw)
    task.percent?.let {
      key("percent"); appendQuoted(builder, it.toString())
    }
    if (task.permissions.isNotEmpty()) {
      key("permissions")
      builder.append('[')
      task.permissions.forEachIndexed { index, permission ->
        if (index > 0) builder.append(',')
        appendQuoted(builder, permission)
      }
      builder.append(']')
    }
    task.result?.takeIf { it.isNotEmpty() }?.let {
      key("result"); appendQuoted(builder, it)
    }
    if (task.retentionZero) {
      key("retention"); appendQuoted(builder, "zero")
    }
    key("schema"); appendQuoted(builder, SCHEMA_IDENTIFIER)
    key("status"); appendQuoted(builder, task.status.raw)
    if (task.steps.isNotEmpty()) {
      key("steps")
      builder.append('[')
      task.steps.forEachIndexed { index, step ->
        if (index > 0) builder.append(',')
        builder.append('{')
        appendQuoted(builder, "label"); builder.append(':')
        appendQuoted(builder, step.label)
        builder.append(',')
        appendQuoted(builder, "state"); builder.append(':')
        appendQuoted(builder, step.state.raw)
        builder.append('}')
      }
      builder.append(']')
    }
    key("task"); appendQuoted(builder, task.taskId)
    key("title"); appendQuoted(builder, task.title)
    task.updatedAt?.takeIf { it.isNotEmpty() }?.let {
      key("updated"); appendQuoted(builder, it)
    }
    builder.append('}')
    return builder.toString().encodeToByteArray()
  }

  // MARK: Parsing

  private fun parseBody(body: String): PopopxAgentTask? {
    val root = popopxJsonDecode(body) as? JsonObject ?: return null
    val schema = root.strictText("schema") ?: return null
    if (schema != SCHEMA_IDENTIFIER) return null
    val taskId = root.strictText("task") ?: return null
    if (!isTaskId(taskId)) return null
    val kind = root.strictText("kind")?.let(PopopxAgentTask.Kind::from) ?: return null
    val status = root.strictText("status")?.let(PopopxAgentTask.Status::from) ?: return null
    val title = root.strictText("title") ?: return null
    if (title.length !in 1..MAXIMUM_TITLE_CHARACTERS) return null

    val agent = optionalText(root, "agent", 1, MAXIMUM_AGENT_CHARACTERS) ?: run {
      if (root.containsKey("agent")) return null else null
    }
    val detail = optionalText(root, "detail", 1, MAXIMUM_DETAIL_CHARACTERS) ?: run {
      if (root.containsKey("detail")) return null else null
    }
    val result = optionalText(root, "result", 1, MAXIMUM_RESULT_CHARACTERS) ?: run {
      if (root.containsKey("result")) return null else null
    }
    val updatedAt = optionalText(root, "updated", 1, MAXIMUM_UPDATED_AT_CHARACTERS) ?: run {
      if (root.containsKey("updated")) return null else null
    }

    val percentText = root.strictText("percent")?.also {
      if (it.length > 3 || it.any { c -> !c.isDigit() }) return null
      val value = it.toIntOrNull() ?: return null
      if (value !in 0..100) return null
    }
    val percent = percentText?.toIntOrNull()

    var steps: List<PopopxAgentTask.Step> = emptyList()
    root["steps"]?.let { raw ->
      val list = raw as? JsonArray ?: return null
      if (list.size > MAXIMUM_STEPS) return null
      steps = list.map { entry ->
        val obj = entry as? JsonObject ?: return null
        val label = obj.strictText("label") ?: return null
        if (label.length !in 1..MAXIMUM_LABEL_CHARACTERS) return null
        val state = obj.strictText("state")?.let(PopopxAgentTask.Step.State::from) ?: return null
        PopopxAgentTask.Step(label, state)
      }
    }

    var permissions: List<String> = emptyList()
    root["permissions"]?.let { raw ->
      val list = raw as? JsonArray ?: return null
      if (list.size > MAXIMUM_PERMISSIONS) return null
      permissions = list.map { entry ->
        val text = (entry as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        if (text.length !in 1..MAXIMUM_LABEL_CHARACTERS) return null
        text
      }
    }

    var choices: List<PopopxAgentTask.Choice> = emptyList()
    root["choices"]?.let { raw ->
      val list = raw as? JsonArray ?: return null
      if (list.size > MAXIMUM_CHOICES) return null
      val seen = HashSet<String>()
      choices = list.map { entry ->
        val obj = entry as? JsonObject ?: return null
        val id = obj.strictText("id") ?: return null
        if (!isTaskId(id) || !seen.add(id)) return null
        val label = obj.strictText("label") ?: return null
        if (label.length !in 1..MAXIMUM_LABEL_CHARACTERS) return null
        PopopxAgentTask.Choice(id, label)
      }
    }

    var retentionZero = false
    root["retention"]?.let { raw ->
      val text = raw.strictTextValue() ?: return null
      retentionZero = text == "zero"
    }

    return PopopxAgentTask(
      taskId = taskId, kind = kind, status = status, title = title, agent = agent, detail = detail,
      percent = percent, steps = steps, permissions = permissions, retentionZero = retentionZero,
      choices = choices, result = result, updatedAt = updatedAt,
    )
  }

  internal fun isTaskId(text: String): Boolean {
    if (text.length !in 1..MAXIMUM_TASK_ID_CHARACTERS) return false
    return text.all { c -> c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c == '.' || c == '_' || c == '-' }
  }

  /** A present-but-empty optional string is refused, not defaulted: the card must not show an empty
   * row where the producer meant a sentence. */
  private fun optionalText(root: JsonObject, name: String, lower: Int, upper: Int): String? {
    val text = root.strictText(name) ?: return null
    return if (text.length in lower..upper) text else null
  }

  private fun isNewline(c: Char): Boolean =
    c == '\n' || c == '\r' || c == '\u000B' || c == '\u000C' || c == '\u0085' || c == '\u2028' || c == '\u2029'

  // MARK: Escaping (same measured table as the Swift side and PopopxNodeFeed)

  internal fun appendQuoted(builder: StringBuilder, text: String) {
    builder.append('"')
    escapeInto(builder, text)
    builder.append('"')
  }

  internal fun escapeInto(builder: StringBuilder, text: String) {
    var index = 0
    while (index < text.length) {
      val character = text[index]
      val pair = character.isHighSurrogate() &&
        index + 1 < text.length &&
        text[index + 1].isLowSurrogate()
      when {
        pair -> {
          builder.append(character).append(text[index + 1])
          index += 1
        }
        character == '"' -> builder.append("\\\"")
        character == '\\' -> builder.append("\\\\")
        character.code == 0x08 -> builder.append("\\b")
        character.code == 0x0C -> builder.append("\\f")
        character.code == 0x09 -> builder.append("\\t")
        character.code == 0x0A -> builder.append("\\n")
        character.code == 0x0D -> builder.append("\\r")
        character.code < 0x20 ->
          builder.append("\\u00").append(hexDigit(character.code shr 4)).append(hexDigit(character.code and 0x0F))
        else -> builder.append(character)
      }
      index += 1
    }
  }

  private fun hexDigit(nibble: Int): Char =
    if (nibble < 10) ('0' + nibble) else ('a' + (nibble - 10))
}

/**
 * The user's answer, signed on this device. `decision` says what was chosen; `choice` is empty
 * unless the decision is `choose`. The signature covers the canonical six-key body rebuilt from
 * decoded values, never the envelope it arrived in.
 *
 * Signatures are deterministic here (BouncyCastle) while CryptoKit signs hedged; both verify each
 * other's output, and the Swift suite verifies the pinned signature this side produces.
 */
data class PopopxAgentReceipt(
  val taskId: String,
  val decision: PopopxAgentReceiptWire.Decision,
  val choiceId: String,
  /** ISO 8601 UTC, second precision (`2026-11-28T10:00:00Z`). */
  val at: String,
  /** Unpadded base64url of the 32-byte Ed25519 public key. */
  val publicKey: String,
  /** Unpadded base64url of the 64-byte signature. */
  val signature: String,
)

object PopopxAgentReceiptWire {
  const val MARKER = "::POPOPX_AGENT_RCPT::"
  const val SCHEMA_VERSION = "v1"
  const val SCHEMA_IDENTIFIER = "popopx.agent.receipt.v1"
  const val MAXIMUM_LINE_CHARACTERS = 4_096

  private const val ED25519_PUBLIC_BYTES = 32
  private const val ED25519_SIGNATURE_BYTES = 64
  private const val MAXIMUM_AT_CHARACTERS = 40

  enum class Decision(val raw: String) {
    APPROVE("approve"),
    DENY("deny"),
    CHOOSE("choose"),
    ;

    companion object {
      fun from(raw: String): Decision? = entries.firstOrNull { it.raw == raw }
    }
  }

  /** Sorted-key order; `sig` is excluded from the signed body and appended to the envelope. */
  internal val BODY_KEYS = listOf("at", "choice", "decision", "key", "schema", "task")
  internal val ENVELOPE_KEYS = listOf("at", "choice", "decision", "key", "schema", "sig", "task")

  fun canonicalBody(
    taskId: String,
    decision: Decision,
    choiceId: String,
    at: String,
    publicKey: String,
  ): ByteArray {
    val builder = StringBuilder()
    builder.append('{')
    BODY_KEYS.forEachIndexed { index, key ->
      if (index > 0) builder.append(',')
      PopopxAgentTaskWire.appendQuoted(builder, key)
      builder.append(':')
      val value = when (key) {
        "at" -> at
        "choice" -> choiceId
        "decision" -> decision.raw
        "key" -> publicKey
        "schema" -> SCHEMA_IDENTIFIER
        "task" -> taskId
        else -> ""
      }
      PopopxAgentTaskWire.appendQuoted(builder, value)
    }
    builder.append('}')
    return builder.toString().encodeToByteArray()
  }

  /** Signs the canonical body with a 32-byte Ed25519 seed. */
  fun make(
    taskId: String,
    decision: Decision,
    choiceId: String = "",
    at: String,
    seed: ByteArray,
  ): PopopxAgentReceipt? {
    if (seed.size != 32 || !PopopxAgentTaskWire.isTaskId(taskId)) return null
    if (decision == Decision.CHOOSE && !PopopxAgentTaskWire.isTaskId(choiceId)) return null
    if (decision != Decision.CHOOSE && choiceId.isNotEmpty()) return null
    val publicKey = ed25519PublicKey(seed) ?: return null
    val publicKeyText = base64UrlEncode(publicKey)
    val body = canonicalBody(taskId, decision, choiceId, at, publicKeyText)
    val signature = ed25519Sign(seed, body) ?: return null
    return PopopxAgentReceipt(taskId, decision, choiceId, at, publicKeyText, base64UrlEncode(signature))
  }

  fun verify(receipt: PopopxAgentReceipt): Boolean {
    if (!PopopxAgentTaskWire.isTaskId(receipt.taskId)) return false
    if (receipt.decision == Decision.CHOOSE && !PopopxAgentTaskWire.isTaskId(receipt.choiceId)) return false
    if (receipt.decision != Decision.CHOOSE && receipt.choiceId.isNotEmpty()) return false
    val key = base64UrlDecode(receipt.publicKey) ?: return false
    if (key.size != ED25519_PUBLIC_BYTES) return false
    val signature = base64UrlDecode(receipt.signature) ?: return false
    if (signature.size != ED25519_SIGNATURE_BYTES) return false
    val body = canonicalBody(
      receipt.taskId, receipt.decision, receipt.choiceId, receipt.at, receipt.publicKey,
    )
    return ed25519Verify(key, body, signature)
  }

  fun wireText(receipt: PopopxAgentReceipt): String {
    val builder = StringBuilder()
    builder.append('{')
    ENVELOPE_KEYS.forEachIndexed { index, key ->
      if (index > 0) builder.append(',')
      PopopxAgentTaskWire.appendQuoted(builder, key)
      builder.append(':')
      val value = when (key) {
        "at" -> receipt.at
        "choice" -> receipt.choiceId
        "decision" -> receipt.decision.raw
        "key" -> receipt.publicKey
        "schema" -> SCHEMA_IDENTIFIER
        "sig" -> receipt.signature
        "task" -> receipt.taskId
        else -> ""
      }
      PopopxAgentTaskWire.appendQuoted(builder, value)
    }
    builder.append('}')
    return MARKER + SCHEMA_VERSION + "::" + builder.toString()
  }

  /** A whole-string test: receipts are machine frames and must never be drawn, previewed or read
   * aloud. The render suppression composes this with the other terms. */
  fun isReceiptText(text: String): Boolean = text.trim { it.isWhitespace() }.startsWith(MARKER)

  fun parseReceipt(text: String): PopopxAgentReceipt? {
    val trimmed = text.trim { it.isWhitespace() }
    if (!trimmed.startsWith(MARKER) || trimmed.length > MAXIMUM_LINE_CHARACTERS) return null
    val versionPrefix = SCHEMA_VERSION + "::"
    if (!trimmed.startsWith(MARKER + versionPrefix)) return null
    val body = trimmed.substring(MARKER.length + versionPrefix.length)
    val root = popopxJsonDecode(body) as? JsonObject ?: return null
    val schema = root.strictText("schema") ?: return null
    if (schema != SCHEMA_IDENTIFIER) return null
    val taskId = root.strictText("task") ?: return null
    if (!PopopxAgentTaskWire.isTaskId(taskId)) return null
    val decision = root.strictText("decision")?.let(Decision::from) ?: return null
    val choiceId = root.strictText("choice") ?: return null
    val at = root.strictText("at") ?: return null
    if (at.length !in 1..MAXIMUM_AT_CHARACTERS) return null
    val publicKey = root.strictText("key") ?: return null
    val signature = root.strictText("sig") ?: return null
    if (decision == Decision.CHOOSE && !PopopxAgentTaskWire.isTaskId(choiceId)) return null
    if (decision != Decision.CHOOSE && choiceId.isNotEmpty()) return null
    return PopopxAgentReceipt(taskId, decision, choiceId, at, publicKey, signature)
  }
}

private fun JsonObject.strictText(key: String): String? {
  val primitive = this[key] as? JsonPrimitive ?: return null
  return if (primitive.isString) primitive.content else null
}

private fun kotlinx.serialization.json.JsonElement.strictTextValue(): String? {
  val primitive = this as? JsonPrimitive ?: return null
  return if (primitive.isString) primitive.content else null
}
