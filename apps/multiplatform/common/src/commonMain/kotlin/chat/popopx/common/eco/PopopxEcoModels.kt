package chat.popopx.common.eco

import chat.popopx.common.crypto.base64UrlDecode
import chat.popopx.common.crypto.hexDecode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

// Ported from apps/ios/Shared/Features/ServiceAccount/PopopxEcoModels.swift.
//
// Every character-count limit below is measured in Unicode code points, which is what Swift's
// `String.count` reports for the ASCII payloads these fields are in practice. They differ only for
// combining marks, where the Kotlin count is larger and therefore rejects more frames than iOS would —
// the conservative direction for an input validator, and the reason the caps are not worth a grapheme
// cluster library here.

object PopopxEcoLimits {
  const val MAXIMUM_FRAME_CHARACTERS = 8192
  const val MAXIMUM_CARD_ID_CHARACTERS = 64
  const val MAXIMUM_TITLE_CHARACTERS = 120
  const val MAXIMUM_BODY_CHARACTERS = 2000
  const val MAXIMUM_LABEL_CHARACTERS = 80
  const val MAXIMUM_VALUE_CHARACTERS = 240
  const val MAXIMUM_PAYLOAD_CHARACTERS = 512
  const val MAXIMUM_URL_CHARACTERS = 2048

  /** How long a scanned deep link may keep its intent waiting for the session handshake. */
  const val PENDING_INTENT_LIFETIME_SECONDS = 300L

  const val MAXIMUM_FIELDS = 8
  const val MAXIMUM_ACTIONS = 4
  const val MAXIMUM_MENU_ITEMS = 3
  const val MAXIMUM_SUB_ITEMS = 5
  const val MAXIMUM_PROGRESS_PERCENT = 100

  /** The same ceiling as the commerce threshold cap: one frame may not ask for more than any screen can. */
  const val MAXIMUM_CREDIT_AMOUNT = 100_000

  /** A zero-amount card payment deducts nothing and leaves no ledger row, so it is only noise. */
  const val MINIMUM_AMOUNT = 1
  const val MAXIMUM_SESSION_SECRET_HEX_CHARACTERS = 64

  // The channel layer's own caps. On iOS these live in an `extension PopopxEcoLimits`
  // (ChannelKeyRotationManager.swift:46-60); Kotlin has no extensions, so they join the set.

  /** Stored epochs per channel: a daily rotation for a month, with room to spare. */
  const val MAXIMUM_STORED_EPOCHS = 30

  /** A card whose conversation was deleted would otherwise live in storage forever. */
  const val MAXIMUM_STORED_CARDS = 200

  /** A channel post is a few kilobytes; a megabyte would be an attachment wearing a card's clothes. */
  const val MAXIMUM_CIPHERTEXT_BYTES = 512 * 1024
  const val MAXIMUM_PLAINTEXT_BYTES = 512 * 1024

  /** Epoch numbers are ints on the wire; past a million a server has a different problem than this client. */
  const val MAXIMUM_EPOCH = 1_000_000
  const val MINIMUM_EXPIRY_WARNING_DAYS = 1
  const val MAXIMUM_EXPIRY_WARNING_DAYS = 90
  const val DEFAULT_EXPIRY_WARNING_DAYS = 7
}

/** Character count in code points, the measure every `PopopxEcoLimits` cap is written against. */
internal fun String.ecoLength(): Int = codePointCount(0, length)

/**
 * One decoded `::POPOPX_ECO::` frame. The four cases are the four frames the server pushes;
 * anything else does not decode.
 */
sealed class PopopxEcoFrame {
  /** The pairwise identity + session secret a service account hands out when someone follows it. */
  data class SessionHandshake(val session: PopopxEcoSession) : PopopxEcoFrame()

  /** The custom bottom menu of this service account. */
  data class MenuConfig(val menu: PopopxEcoMenu) : PopopxEcoFrame()

  /** A card: `create` renders a bubble, `update` mutates the card that is already on screen. */
  data class ServiceCard(val card: PopopxServiceCard) : PopopxEcoFrame()

  /** A new channel epoch key. The crypto is verified by [PopopxChannelKeyRotation], not here. */
  data class ChannelKeyUpdate(val update: PopopxChannelKeyUpdate) : PopopxEcoFrame()

  /** Whether this frame must never reach a bubble, a chat-list preview or a notification. */
  val isControlFrame: Boolean
    get() = when (this) {
      is ServiceCard -> card.mode != PopopxServiceCard.Mode.CREATE
      else -> true
    }

  /** Second-pass validation: the JSON decoded, but is every field inside the caps and none required empty? */
  val isSane: Boolean
    get() = when (this) {
      is SessionHandshake -> session.isSane
      is MenuConfig -> menu.isSane
      is ServiceCard -> card.isSane
      is ChannelKeyUpdate -> update.isSane
    }
}

/** The codec for `::POPOPX_ECO::`. */
object PopopxEcoMarker {
  const val MARKER = "::POPOPX_ECO::"

  private val json = Json { ignoreUnknownKeys = true }

  /**
   * Whole-string parse: the only entry point for a frame that mutates this device.
   *
   * Trim, compare the prefix, then require that nothing else remains. A frame inside a longer text
   * returns null *by design*. Newlines are the other half of "nothing else remains": a frame with a
   * trailing sentence would decode fine as JSON and silently execute while the user sees their own text.
   */
  fun parseControlText(text: String): PopopxEcoFrame? {
    val trimmed = text.trim { it.isWhitespace() }
    if (!trimmed.startsWith(MARKER)) return null
    val body = trimmed.substring(MARKER.length)
    if (body.contains('\n') || body.contains('\r')) return null
    return decode(body)
  }

  /**
   * Unanchored parse of a **visible card** frame: split on whitespace, try each token from the end.
   *
   * Searching from the end matches the location payload parser: the producer puts the machine line
   * after the readable one, so the last candidate is the real payload and a place name that happens to
   * look like a payload cannot win. Only a `create` card is returned.
   */
  fun parseVisibleCard(text: String): PopopxServiceCard? {
    val tokens = text.ecoTokens()
    for (token in tokens.asReversed()) {
      if (!token.startsWith(MARKER)) continue
      val body = token.substring(MARKER.length)
      val frame = decode(body) ?: continue
      if (frame is PopopxEcoFrame.ServiceCard && frame.card.mode == PopopxServiceCard.Mode.CREATE) return frame.card
    }
    return null
  }

  /** The render-suppression criterion, shared by the three UI gates. */
  fun isControlText(text: String): Boolean = parseControlText(text)?.isControlFrame ?: false

  /** Wire form of a frame. Used by the tests and by the card-update confirmation the router writes back. */
  fun wireString(frame: PopopxEcoFrame): String = MARKER + PopopxEcoCodec.json(frame)

  internal fun decode(json: String): PopopxEcoFrame? {
    if (json.ecoLength() > PopopxEcoLimits.MAXIMUM_FRAME_CHARACTERS) return null
    val frame = PopopxEcoCodec.frame(json) ?: return null
    return if (frame.isSane) frame else null
  }
}

/**
 * The three machine lines this device sends *up* to a service account.
 *
 * One definition on purpose: the sender and the render-suppression gate must agree character for
 * character, or a machine line shows as the user's own bubble or a real message disappears. These are
 * plain text, not `::POPOPX_ECO::` frames, so they need their own gate.
 */
object PopopxEcoUplink {
  const val CALLBACK_PREFIX = "::CB::"
  const val REFERENCE_PREFIX = "::REF::"
  const val SSO_SCAN_PREFIX = "::SSO_SCAN::"

  private val prefixes = listOf(CALLBACK_PREFIX, REFERENCE_PREFIX, SSO_SCAN_PREFIX)

  /** Refusing to build the line is the only safe answer for a payload with whitespace or a second `::`. */
  fun wireString(prefix: String, payload: String): String? =
    if (prefix in prefixes && isSendablePayload(payload)) prefix + payload else null

  /** A sentence that merely quotes one of these lines is a message the user wrote and must stay visible. */
  fun isUplinkText(text: String): Boolean {
    val trimmed = text.trim { it.isWhitespace() }
    val prefix = prefixes.firstOrNull { trimmed.startsWith(it) } ?: return false
    return isSendablePayload(trimmed.substring(prefix.length))
  }

  /** One clean token, no room for a second command. */
  fun isSendablePayload(payload: String): Boolean =
    payload.isNotEmpty() &&
      payload.ecoLength() <= PopopxEcoLimits.MAXIMUM_PAYLOAD_CHARACTERS &&
      payload.none { it.isWhitespace() } &&
      !payload.contains("::")
}

/** The pairwise identity of one follower, as issued by one service account. */
data class PopopxEcoSession(
  val pairwiseUid: String,
  val secretHex: String,
  val serviceId: String?,
) {
  val isSane: Boolean
    get() = pairwiseUid.isNotEmpty() &&
      pairwiseUid.ecoLength() <= PopopxEcoLimits.MAXIMUM_PAYLOAD_CHARACTERS &&
      secretBytes != null &&
      (serviceId == null || serviceId.isNotEmpty() && serviceId.ecoLength() <= PopopxEcoLimits.MAXIMUM_PAYLOAD_CHARACTERS)

  /**
   * The session secret as key material, or null when the hex is not 1..32 bytes. The cap is 32 because
   * HMAC truncates anything longer rather than rejecting it, which would mean a key the server does not hold.
   */
  val secretBytes: ByteArray?
    get() = hexDecode(secretHex, 32)

  override fun equals(other: Any?): Boolean =
    other is PopopxEcoSession && pairwiseUid == other.pairwiseUid && secretHex == other.secretHex && serviceId == other.serviceId

  override fun hashCode(): Int {
    var result = pairwiseUid.hashCode()
    result = 31 * result + secretHex.hashCode()
    result = 31 * result + (serviceId?.hashCode() ?: 0)
    return result
  }
}

/** The custom bottom menu of one service account. */
data class PopopxEcoMenu(
  val items: List<Item>,
  val revision: Int?,
) {
  data class Item(
    val title: String,
    val kind: Kind,
    val action: PopopxEcoAction.Kind?,
    val payload: String?,
    val url: String?,
    val subItems: List<Item>,
  ) {
    val id: String get() = title

    enum class Kind(val raw: String) {
      CLICK("click"),
      VIEW("view"),
      SCANCODE("scancode"),
      LOCATION("location"),
      CLICK_TEXT("click_text"),
      ;

      companion object {
        fun from(raw: String): Kind? = entries.firstOrNull { it.raw == raw }
      }
    }

    /**
     * A submenu is only reachable under a `click` button, so a `view` button carrying one is not a menu —
     * it is a button whose children silently never appear. Rejecting the whole menu is better than
     * rendering half of it. Sub-items are deliberately not validated recursively, as on iOS: the cap on
     * their count is checked, their own sanity is not.
     */
    val isSane: Boolean
      get() {
        if (title.isEmpty() || title.ecoLength() > PopopxEcoLimits.MAXIMUM_LABEL_CHARACTERS) return false
        if (subItems.size > PopopxEcoLimits.MAXIMUM_SUB_ITEMS) return false
        if (kind == Kind.VIEW) return url != null && subItems.isEmpty()
        if (kind == Kind.SCANCODE || kind == Kind.LOCATION) return action == null
        val action = action ?: return false
        return when (action) {
          PopopxEcoAction.Kind.OPEN_URL -> url != null
          PopopxEcoAction.Kind.SEND_COMMAND, PopopxEcoAction.Kind.OPEN_CHANNEL, PopopxEcoAction.Kind.CALLBACK -> payload != null
          else -> false
        }
      }
  }

  val isSane: Boolean
    get() = items.isNotEmpty() &&
      items.size <= PopopxEcoLimits.MAXIMUM_MENU_ITEMS &&
      items.map { it.id }.toSet().size == items.size &&
      items.all { it.isSane }
}

/** One dynamic business card. */
data class PopopxServiceCard(
  val cardId: String,
  val style: Style,
  val title: String,
  val body: String?,
  val fields: List<Field>,
  val progress: Progress?,
  val actions: List<PopopxEcoAction>,
  val updatedAtMs: Long,
  val expiresAtMs: Long?,
  var mode: Mode = Mode.CREATE,
) {
  val id: String get() = cardId

  enum class Style(val raw: String) {
    STANDARD("standard"),
    RECEIPT("receipt"),
    SECURITY("security"),
    ;

    companion object {
      fun from(raw: String): Style? = entries.firstOrNull { it.raw == raw }
    }
  }

  enum class Mode(val raw: String) {
    CREATE("create"),
    UPDATE("update"),
    ;

    companion object {
      fun from(raw: String): Mode? = entries.firstOrNull { it.raw == raw }
    }
  }

  /** Whether the buttons still fire, judged on the caller's clock so the view and the router cannot disagree. */
  fun isLive(nowMs: Long): Boolean = expiresAtMs?.let { nowMs < it } ?: true

  val isSane: Boolean
    get() = cardId.isNotEmpty() &&
      cardId.ecoLength() <= PopopxEcoLimits.MAXIMUM_CARD_ID_CHARACTERS &&
      title.isNotEmpty() &&
      title.ecoLength() <= PopopxEcoLimits.MAXIMUM_TITLE_CHARACTERS &&
      (body == null || body.ecoLength() <= PopopxEcoLimits.MAXIMUM_BODY_CHARACTERS) &&
      fields.size <= PopopxEcoLimits.MAXIMUM_FIELDS &&
      fields.all { it.isSane } &&
      (progress == null || progress.isSane) &&
      actions.size <= PopopxEcoLimits.MAXIMUM_ACTIONS &&
      actions.all { it.isSane } &&
      actions.map { it.id }.toSet().size == actions.size &&
      updatedAtMs > 0 &&
      (expiresAtMs == null || expiresAtMs > 0)

  /** A structured key/value row of the receipt style. */
  data class Field(val label: String, val value: String, val mono: Boolean?) {
    val id: String get() = label

    val isSane: Boolean
      get() = label.isNotEmpty() &&
        label.ecoLength() <= PopopxEcoLimits.MAXIMUM_LABEL_CHARACTERS &&
        value.isNotEmpty() &&
        value.ecoLength() <= PopopxEcoLimits.MAXIMUM_VALUE_CHARACTERS
  }

  /** The inline progress bar. */
  data class Progress(val label: String, val percent: Int, val detail: String?) {
    val isSane: Boolean
      get() = label.isNotEmpty() &&
        label.ecoLength() <= PopopxEcoLimits.MAXIMUM_LABEL_CHARACTERS &&
        percent in 0..PopopxEcoLimits.MAXIMUM_PROGRESS_PERCENT &&
        (detail == null || detail.ecoLength() <= PopopxEcoLimits.MAXIMUM_VALUE_CHARACTERS)
  }
}

/** One tappable action on a card. */
data class PopopxEcoAction(
  val id: String,
  val title: String,
  val kind: Kind,
  val visual: Visual,
  val payload: String?,
  val url: String?,
  val target: String?,
  val amount: Int?,
  val requiresConfirmation: Boolean,
) {
  val isLive: Boolean get() = kind != Kind.NONE

  enum class Kind(val raw: String) {
    CALLBACK("callback"),
    PAY_CREDITS("pay_credits"),
    OPEN_URL("open_url"),
    OPEN_CHANNEL("open_channel"),
    SEND_COMMAND("send_cmd"),
    NONE("none"),
    ;

    companion object {
      fun from(raw: String): Kind? = entries.firstOrNull { it.raw == raw }
    }
  }

  enum class Visual(val raw: String) {
    PRIMARY("primary"),
    SECONDARY("secondary"),
    DESTRUCTIVE("destructive"),
    ;

    companion object {
      fun from(raw: String): Visual? = entries.firstOrNull { it.raw == raw }
    }
  }

  val isSane: Boolean
    get() {
      if (title.isEmpty() || title.ecoLength() > PopopxEcoLimits.MAXIMUM_LABEL_CHARACTERS) return false
      return when (kind) {
        Kind.NONE -> false
        Kind.CALLBACK, Kind.SEND_COMMAND ->
          payload != null && payload.isNotEmpty() && payload.ecoLength() <= PopopxEcoLimits.MAXIMUM_PAYLOAD_CHARACTERS
        Kind.OPEN_URL -> url != null && isHttpUrl(url)
        Kind.OPEN_CHANNEL -> payload != null && PopopxChannelPublicURI.parse(payload) != null
        Kind.PAY_CREDITS ->
          amount != null &&
            amount >= PopopxEcoLimits.MINIMUM_AMOUNT &&
            amount <= PopopxEcoLimits.MAXIMUM_CREDIT_AMOUNT &&
            (target == null || target.ecoLength() <= PopopxEcoLimits.MAXIMUM_PAYLOAD_CHARACTERS)
      }
    }

  companion object {
    /**
     * Only http and https, with a host, and never a JavaScript or custom scheme: a card is untrusted
     * input, and a button that can hand a URL out must not be able to hand out `javascript:` or one of
     * this app's own schemes.
     */
    fun isHttpUrl(text: String): Boolean {
      if (text.ecoLength() > PopopxEcoLimits.MAXIMUM_URL_CHARACTERS) return false
      val scheme = text.substringBefore("://", "").lowercase()
      if (scheme != "http" && scheme != "https") return false
      val authority = text.substringAfter("://", "").substringBefore('/').substringBefore('?').substringBefore('#')
      // userinfo is dropped, not validated: `user@host` is still the same destination, and the
      // credential must never reach the check below or the address bar.
      val host = if (authority.contains('@')) authority.substringAfterLast('@') else authority
      if (host.isEmpty()) return false
      // An IPv6 literal (`[::1]`) has colons of its own and is rejected rather than guessed at;
      // Swift's URLComponents parses it as a host without a port, so this rejects a URL iOS accepts.
      if (host.contains('[') || host.contains(']')) return false
      val port = host.substringAfter(':', "")
      return if (!host.contains(':')) true else port.isNotEmpty() && port.all { it.isDigit() }
    }
  }
}

/**
 * `popopx://channel/<Relay>/<ChannelID>#key=<Base64_K_master>&pub=<Base64_Ed25519公钥>`
 *
 * Everything after `#` is never sent to a relay, which is the only reason a channel key can be handed out
 * in a public post without becoming public. [connectionUri] is the only form that may leave the device.
 */
data class PopopxChannelPublicURI(
  val relay: String,
  val channelId: String,
  val masterKeyBase64Url: String,
  val issuerPublicKeyBase64Url: String,
) {
  /** The fragment-free form, rebuilt from the components rather than trimmed, so a key carried in the
   * query (a server bug, or a hand-edited link) cannot reach the network layer with it. */
  val connectionUri: String get() = "popopx://channel/$relay/$channelId"

  companion object {
    /**
     * ASCII word characters plus `-_.`, spelled as a string because the set operator silently adds the
     * array as one element: `('a'..'z') + charArrayOf('-', '_', '.')` compiles and then rejects every
     * dotted relay, which is every relay.
     *
     * iOS uses `CharacterSet.alphanumerics`, which is Unicode-wide, so a non-ASCII channel id is accepted
     * there and refused here — the conservative direction for an opaque storage account name.
     */
    private const val ALLOWED_SEGMENT_CHARACTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."

    fun parse(text: String): PopopxChannelPublicURI? {
      val trimmed = text.trim { it.isWhitespace() }
      if (trimmed.ecoLength() > PopopxEcoLimits.MAXIMUM_URL_CHARACTERS) return null
      if (!trimmed.startsWith("popopx://channel/")) return null
      val fragment = trimmed.substringAfter('#', "")
      val withoutFragment = trimmed.substringBefore('#')
      val tail = withoutFragment.substringAfter("popopx://channel/", "")
      if (tail.isEmpty()) return null
      val segments = tail.split('/').filter { it.isNotEmpty() }
      if (segments.size != 2) return null
      val relay = segments[0]
      val channelId = segments[1]
      if (!isOpaqueSegment(relay) || !isOpaqueSegment(channelId)) return null
      if (fragment.isEmpty()) return null

      val values = HashMap<String, String>()
      for (pair in fragment.split('&')) {
        if (pair.isEmpty()) return null
        val name = pair.substringBefore('=', "")
        // Only these two keys are recognised, and a duplicated key is not "last wins".
        if (name != "key" && name != "pub") return null
        if (!pair.contains('=')) return null
        val value = pair.substringAfter('=')
        if (values.containsKey(name)) return null
        values[name] = value
      }
      val key = values["key"] ?: return null
      val pub = values["pub"] ?: return null
      if (base64UrlDecode(key)?.size != 32) return null
      if (base64UrlDecode(pub)?.size != 32) return null

      return PopopxChannelPublicURI(relay, channelId, key, pub)
    }

    /** Opaque segments only: a space, a slash, a colon or a `%` would give the segment a second meaning, or
     * make a keystore account name out of a path. MEASURED against iOS, `..` is NOT refused here — the guard
     * is this character set and the dot is in it — so a link naming its channel `..` parses on both
     * platforms. Ported rather than corrected: refusing it would reject links iOS accepts, and the value is
     * only ever an account suffix. Kotlin is stricter than iOS in one way: Swift's `.alphanumerics` is
     * Unicode-wide, so iOS admits a non-ASCII letter here and Kotlin does not. */
    private fun isOpaqueSegment(text: String): Boolean =
      text.isNotEmpty() && text.length <= 128 && text.none { it.isWhitespace() } && text.all { it in ALLOWED_SEGMENT_CHARACTERS }
  }
}

/** JSON plumbing for the eco wire, so the encoders and the millisecond decision exist once. */
object PopopxEcoCodec {
  private val json = Json { ignoreUnknownKeys = true }

  fun frame(text: String): PopopxEcoFrame? {
    val element = try {
      json.parseToJsonElement(text)
    } catch (e: Exception) {
      return null
    }
    val obj = element as? JsonObject ?: return null
    return PopopxEcoWire.frame(obj)
  }

  fun json(frame: PopopxEcoFrame): String = PopopxEcoWire.encode(frame)
}

/**
 * The wire shape of one frame: a discriminant plus exactly one payload section. Every field is optional
 * on purpose, so a frame that omits `menu` while claiming `t = "mc"` fails validation instead of throwing.
 */
internal object PopopxEcoWire {
  const val KEY_TYPE = "t"
  const val KEY_UID = "uid"
  const val KEY_SEC = "sec"
  const val KEY_SVC = "svc"
  const val KEY_MODE = "m"
  const val KEY_CARD = "card"
  const val KEY_MENU = "menu"
  const val KEY_UPDATE = "update"

  private const val TYPE_SESSION_HANDSHAKE = "sh"
  private const val TYPE_MENU_CONFIG = "mc"
  private const val TYPE_SERVICE_CARD = "sc"
  private const val TYPE_CHANNEL_KEY_UPDATE = "ku"
  private const val MODE_CREATE = "c"
  private const val MODE_UPDATE = "u"

  fun frame(obj: JsonObject): PopopxEcoFrame? = try {
    when (val type = obj.stringOrThrow(KEY_TYPE)) {
      TYPE_SESSION_HANDSHAKE -> {
        val uid = obj.string(KEY_UID) ?: throw EcoReject()
        val sec = obj.string(KEY_SEC) ?: throw EcoReject()
        PopopxEcoFrame.SessionHandshake(PopopxEcoSession(uid, sec, obj.string(KEY_SVC)))
      }

      TYPE_MENU_CONFIG -> {
        val menu = obj.child(KEY_MENU) ?: throw EcoReject()
        PopopxEcoFrame.MenuConfig(menuOf(menu))
      }

      TYPE_SERVICE_CARD -> {
        val card = obj.child(KEY_CARD) ?: throw EcoReject()
        when (val mode = obj.stringOrThrow(KEY_MODE)) {
          MODE_CREATE -> PopopxEcoFrame.ServiceCard(cardOf(card, PopopxServiceCard.Mode.CREATE))
          MODE_UPDATE -> PopopxEcoFrame.ServiceCard(cardOf(card, PopopxServiceCard.Mode.UPDATE))
          else -> throw EcoReject()
        }
      }

      TYPE_CHANNEL_KEY_UPDATE -> {
        val update = obj.child(KEY_UPDATE) ?: throw EcoReject()
        PopopxEcoFrame.ChannelKeyUpdate(PopopxChannelKeyUpdate.of(update))
      }

      else -> throw EcoReject()
    }
  } catch (e: EcoReject) {
    null
  } catch (e: Exception) {
    null
  }

  private fun menuOf(obj: JsonObject): PopopxEcoMenu =
    PopopxEcoMenu(obj.array(KEY_MENU_ITEMS) ?.let { items -> items.map { itemOf(it.jsonObjectOrThrow()) } } ?: emptyList(), obj.int(KEY_REVISION))

  private fun itemOf(obj: JsonObject): PopopxEcoMenu.Item = PopopxEcoMenu.Item(
    title = obj.string(KEY_TITLE) ?: "",
    kind = obj.string(KEY_KIND)?.let { PopopxEcoMenu.Item.Kind.from(it) ?: throw EcoReject() } ?: PopopxEcoMenu.Item.Kind.CLICK,
    action = obj.string(KEY_ACTION)?.let { PopopxEcoAction.Kind.from(it) ?: throw EcoReject() },
    payload = obj.string(KEY_PAYLOAD),
    url = obj.string(KEY_URL),
    subItems = obj.array(KEY_SUB_ITEMS)?.let { items -> items.map { itemOf(it.jsonObjectOrThrow()) } } ?: emptyList(),
  )

  /** Stored cards are persisted in the card's own wire shape, and a restored card is a `create`. */
  internal fun cardFromJson(obj: JsonObject): PopopxServiceCard? = try {
    cardOf(obj, PopopxServiceCard.Mode.CREATE)
  } catch (e: Exception) {
    null
  }

  internal fun cardToJson(card: PopopxServiceCard): JsonObject = encodeCard(card)

  private fun cardOf(obj: JsonObject, mode: PopopxServiceCard.Mode): PopopxServiceCard {    val style = obj.string(KEY_STYLE)?.let { PopopxServiceCard.Style.from(it) ?: throw EcoReject() } ?: throw EcoReject()
    return PopopxServiceCard(
      cardId = obj.string(KEY_CARD_ID) ?: throw EcoReject(),
      style = style,
      title = obj.string(KEY_TITLE) ?: "",
      body = obj.string(KEY_BODY),
      fields = obj.array(KEY_FIELDS)?.let { rows -> rows.map { fieldOf(it.jsonObjectOrThrow()) } } ?: emptyList(),
      progress = obj.child(KEY_PROGRESS)?.let { progressOf(it) },
      actions = obj.array(KEY_ACTIONS)?.let { rows -> rows.map { actionOf(it.jsonObjectOrThrow()) } } ?: emptyList(),
      updatedAtMs = obj.long(KEY_UPDATED_AT) ?: throw EcoReject(),
      expiresAtMs = obj.long(KEY_EXPIRES_AT),
      mode = mode,
    )
  }

  private fun fieldOf(obj: JsonObject): PopopxServiceCard.Field = PopopxServiceCard.Field(
    label = obj.string(KEY_FIELD_LABEL) ?: throw EcoReject(),
    value = obj.string(KEY_FIELD_VALUE) ?: throw EcoReject(),
    mono = obj.boolean(KEY_FIELD_MONO),
  )

  private fun progressOf(obj: JsonObject): PopopxServiceCard.Progress = PopopxServiceCard.Progress(
    label = obj.string(KEY_PROGRESS_LABEL) ?: throw EcoReject(),
    percent = obj.int(KEY_PROGRESS_PERCENT) ?: throw EcoReject(),
    detail = obj.string(KEY_PROGRESS_DETAIL),
  )

  private fun actionOf(obj: JsonObject): PopopxEcoAction {
    val nestedMode = obj.string(KEY_MODE)
    return PopopxEcoAction(
      id = obj.string(KEY_ID) ?: "",
      title = obj.string(KEY_TITLE) ?: "",
      kind = (obj.string(KEY_ACTION) ?: nestedMode)?.let { PopopxEcoAction.Kind.from(it) ?: throw EcoReject() } ?: PopopxEcoAction.Kind.NONE,
      visual = obj.string(KEY_VISUAL)?.let { PopopxEcoAction.Visual.from(it) ?: throw EcoReject() } ?: PopopxEcoAction.Visual.PRIMARY,
      payload = obj.string(KEY_PAYLOAD),
      url = obj.string(KEY_URL),
      target = obj.string(KEY_TARGET),
      amount = obj.int(KEY_AMOUNT),
      requiresConfirmation = obj.boolean(KEY_CONFIRM) ?: false,
    )
  }

  fun encode(frame: PopopxEcoFrame): String {
    val obj = LinkedHashMap<String, JsonElement>()
    when (frame) {
      is PopopxEcoFrame.SessionHandshake -> {
        obj[KEY_TYPE] = JsonPrimitive(TYPE_SESSION_HANDSHAKE)
        obj[KEY_UID] = JsonPrimitive(frame.session.pairwiseUid)
        obj[KEY_SEC] = JsonPrimitive(frame.session.secretHex)
        frame.session.serviceId?.let { obj[KEY_SVC] = JsonPrimitive(it) }
      }

      is PopopxEcoFrame.MenuConfig -> {
        obj[KEY_TYPE] = JsonPrimitive(TYPE_MENU_CONFIG)
        obj[KEY_MENU] = encodeMenu(frame.menu)
      }

      is PopopxEcoFrame.ServiceCard -> {
        obj[KEY_TYPE] = JsonPrimitive(TYPE_SERVICE_CARD)
        obj[KEY_MODE] = JsonPrimitive(if (frame.card.mode == PopopxServiceCard.Mode.CREATE) MODE_CREATE else MODE_UPDATE)
        obj[KEY_CARD] = encodeCard(frame.card)
      }

      is PopopxEcoFrame.ChannelKeyUpdate -> {
        obj[KEY_TYPE] = JsonPrimitive(TYPE_CHANNEL_KEY_UPDATE)
        obj[KEY_UPDATE] = frame.update.encode()
      }
    }
    return JsonObject(obj).toString()
  }

  private fun encodeMenu(menu: PopopxEcoMenu): JsonObject {
    val obj = LinkedHashMap<String, JsonElement>()
    obj[KEY_MENU_ITEMS] = JsonArray(menu.items.map { encodeItem(it) })
    menu.revision?.let { obj[KEY_REVISION] = JsonPrimitive(it) }
    return JsonObject(obj)
  }

  private fun encodeItem(item: PopopxEcoMenu.Item): JsonObject {
    val obj = LinkedHashMap<String, JsonElement>()
    obj[KEY_TITLE] = JsonPrimitive(item.title)
    obj[KEY_KIND] = JsonPrimitive(item.kind.raw)
    item.action?.let { obj[KEY_ACTION] = JsonPrimitive(it.raw) }
    item.payload?.let { obj[KEY_PAYLOAD] = JsonPrimitive(it) }
    item.url?.let { obj[KEY_URL] = JsonPrimitive(it) }
    obj[KEY_SUB_ITEMS] = JsonArray(item.subItems.map { encodeItem(it) })
    return JsonObject(obj)
  }

  private fun encodeCard(card: PopopxServiceCard): JsonObject {
    val obj = LinkedHashMap<String, JsonElement>()
    obj[KEY_CARD_ID] = JsonPrimitive(card.cardId)
    obj[KEY_STYLE] = JsonPrimitive(card.style.raw)
    obj[KEY_TITLE] = JsonPrimitive(card.title)
    card.body?.let { obj[KEY_BODY] = JsonPrimitive(it) }
    obj[KEY_FIELDS] = JsonArray(card.fields.map { field ->
      val f = LinkedHashMap<String, JsonElement>()
      f[KEY_FIELD_LABEL] = JsonPrimitive(field.label)
      f[KEY_FIELD_VALUE] = JsonPrimitive(field.value)
      field.mono?.let { f[KEY_FIELD_MONO] = JsonPrimitive(it) }
      JsonObject(f)
    })
    card.progress?.let { progress ->
      val p = LinkedHashMap<String, JsonElement>()
      p[KEY_PROGRESS_LABEL] = JsonPrimitive(progress.label)
      p[KEY_PROGRESS_PERCENT] = JsonPrimitive(progress.percent)
      progress.detail?.let { p[KEY_PROGRESS_DETAIL] = JsonPrimitive(it) }
      obj[KEY_PROGRESS] = JsonObject(p)
    }
    obj[KEY_ACTIONS] = JsonArray(card.actions.map { action ->
      val a = LinkedHashMap<String, JsonElement>()
      a[KEY_ID] = JsonPrimitive(action.id)
      a[KEY_TITLE] = JsonPrimitive(action.title)
      a[KEY_MODE] = JsonPrimitive(action.kind.raw)
      a[KEY_VISUAL] = JsonPrimitive(action.visual.raw)
      action.payload?.let { a[KEY_PAYLOAD] = JsonPrimitive(it) }
      action.url?.let { a[KEY_URL] = JsonPrimitive(it) }
      action.target?.let { a[KEY_TARGET] = JsonPrimitive(it) }
      action.amount?.let { a[KEY_AMOUNT] = JsonPrimitive(it) }
      if (action.requiresConfirmation) a[KEY_CONFIRM] = JsonPrimitive(true)
      JsonObject(a)
    })
    obj[KEY_UPDATED_AT] = JsonPrimitive(card.updatedAtMs)
    card.expiresAtMs?.let { obj[KEY_EXPIRES_AT] = JsonPrimitive(it) }
    return JsonObject(obj)
  }

  // MARK: Strict readers and object building live in EcoWire.kt, shared with the channel envelope.

  private const val KEY_MENU_ITEMS = "items"
  private const val KEY_REVISION = "rev"
  private const val KEY_SUB_ITEMS = "sub"
  private const val KEY_TITLE = "title"
  private const val KEY_KIND = "kind"
  private const val KEY_ACTION = "action"
  private const val KEY_PAYLOAD = "payload"
  private const val KEY_URL = "url"
  private const val KEY_CARD_ID = "id"
  private const val KEY_STYLE = "v"
  private const val KEY_BODY = "body"
  private const val KEY_FIELDS = "fields"
  private const val KEY_FIELD_LABEL = "k"
  private const val KEY_FIELD_VALUE = "v"
  private const val KEY_FIELD_MONO = "mono"
  private const val KEY_PROGRESS = "progress"
  private const val KEY_PROGRESS_LABEL = "l"
  private const val KEY_PROGRESS_PERCENT = "p"
  private const val KEY_PROGRESS_DETAIL = "d"
  private const val KEY_ACTIONS = "actions"
  private const val KEY_ID = "id"
  private const val KEY_VISUAL = "style"
  private const val KEY_TARGET = "target"
  private const val KEY_AMOUNT = "amount"
  private const val KEY_CONFIRM = "confirm"
  private const val KEY_UPDATED_AT = "ut"
  private const val KEY_EXPIRES_AT = "et"
}
