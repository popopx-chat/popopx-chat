package chat.popopx.common.discover

import chat.popopx.common.crypto.base64UrlDecode
import chat.popopx.common.crypto.ed25519Verify
import chat.popopx.common.crypto.sha256Hex
import kotlinx.datetime.Instant
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Decoder for `popopx.discover.feed.v1` — the signed Discover feed a bonded Mac Node delivers as the
 * `feed.json` artifact of one result message. Kotlin twin of
 * `apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Node/PopopxNodeFeedWire.swift`; the two are held to the
 * same pinned envelopes by `desktopTest/.../discover/PopopxNodeFeedVectors.kt`, so a change to one side
 * that the other cannot reproduce fails a test rather than shipping a phone that refuses its own Mac.
 *
 * Producer side, quoted rather than guessed (`PopopxMacNode` main = e40f5e3):
 * - item fields [PopopxNodeFeedItem], item signing body (7 keys) `Discover/DiscoverModels.swift:176-186`, `:226-236`
 * - envelope fields, envelope signing body (5 keys) `Discover/DiscoverModels.swift:247-271`, `:276-301`
 * - structural refusals `Discover/DiscoverModels.swift:313-320`
 * - item `sha256` semantics `Discover/DiscoverCenter.swift:287-293`
 * - key/signature encoding `Core/MacNodePopopxBridge.swift:556,573-579`, `Models/MacNodeModels.swift:4044-4057`
 * - the file itself `Models/MacNodeModels.swift:3174` (`AppPaths.discoverFeedFile`), sent by
 *   `Core/MacNodePopopxBridge.swift:2482-2504` as a `fileItem` beside the readable card
 *
 * The one thing a receiver cannot do is hash the bytes it was handed. The node writes `feed.json` with
 * `NodeJSON.encoder(prettyPrinted: true)` (`MacNodeModels.swift:426-437` = `[.prettyPrinted, .sortedKeys]`,
 * which escapes `/`), while both signatures cover a body **rebuilt from the decoded values** with
 * `[.sortedKeys, .withoutEscapingSlashes]`. Everything below therefore re-serializes decoded strings and
 * never looks at the file's formatting. Note this is NOT the writer in
 * [chat.popopx.common.commerce.PopopxSwiftJson]: that one reproduces `[.sortedKeys]` and escapes `/`,
 * which would refuse every feed on the wire (`plain` in the vectors pins both digests either way).
 */

/**
 * One entry of the feed. All nine fields are strings on the wire; the producer's own `Codable` emits
 * exactly these keys, so a missing one is a refusal rather than a default.
 */
data class PopopxNodeFeedItem(
  val id: String,
  val title: String,
  val summary: String,
  /** `folder`, `rss`, `json` or `mcp` — carried through unvalidated, it is display data. */
  val source: String,
  val sourceLabel: String,
  /** Deliberately allowed to be empty by the producer: a local file path must not reach the phone as a
   * tappable target, so nothing downstream may assume a scheme is present. */
  val link: String,
  val timestamp: String,
  /** Lowercase hex of this item's own seven-key canonical body. */
  val sha256: String,
  /** Unpadded base64url Ed25519 signature over that same body. */
  val signature: String,
) {
  /** Field lookup by wire name, so the key lists in [PopopxNodeFeedWire] are the only place a name is written. */
  internal fun field(key: String): String = when (key) {
    "id" -> id
    "title" -> title
    "summary" -> summary
    "source" -> source
    "sourceLabel" -> sourceLabel
    "link" -> link
    "timestamp" -> timestamp
    "sha256" -> sha256
    "signature" -> signature
    else -> ""
  }
}

/**
 * The signed envelope. `publicKey` is self-declared; whether it may be believed is the caller's problem
 * ([PopopxSubscriptionEngine] pins it on first full verification), never this decoder's.
 */
data class PopopxNodeFeed(
  val schema: String,
  val generatedAt: String,
  val nodeId: String,
  val publicKey: String,
  val items: List<PopopxNodeFeedItem>,
  val signature: String,
) {
  /** The producer stamps this with `PrivacyStamp.iso` — ISO 8601, internet date-time, UTC. */
  val generatedAtMs: Long? get() = PopopxNodeFeedWire.instantMillis(generatedAt)

  internal fun field(key: String): String = when (key) {
    "schema" -> schema
    "generatedAt" -> generatedAt
    "nodeId" -> nodeId
    "publicKey" -> publicKey
    "signature" -> signature
    else -> ""
  }
}

/**
 * What this device keeps between launches: the items it verified, the instant the node generated them,
 * the node's id, and **the key they were verified under** — which is what makes the next envelope's key a
 * question with an answer.
 *
 * Only ever written by this device. The fields that decide acceptance (`signature`, and each item's
 * `sha256`) are present here because the displayed rows carry them, but nothing may read a stored snapshot
 * as if it had been verified: [PopopxNodeFeedWire.ingest] always re-runs the whole chain on fresh bytes.
 */
data class PopopxNodeFeedSnapshot(
  val items: List<PopopxNodeFeedItem>,
  val generatedAt: String,
  val nodeId: String,
  val publicKey: String,
  /** Milliseconds since 1970 of the last envelope whose key was NOT the pinned one. Persisted because the
   * refusal repeats on every later feed: without it a rotated node key would leave the panel showing stale
   * content and no reason, forever. */
  val keyChangedAtMs: Long? = null,
) {
  val generatedAtMs: Long? get() = PopopxNodeFeedWire.instantMillis(generatedAt)

  companion object {
    fun of(feed: PopopxNodeFeed): PopopxNodeFeedSnapshot =
      PopopxNodeFeedSnapshot(feed.items, feed.generatedAt, feed.nodeId, feed.publicKey)

    /** Null on any structural surprise: a corrupt blob drops the feed rather than showing unverified rows. */
    fun fromJson(json: JsonElement?): PopopxNodeFeedSnapshot? {
      val obj = json as? JsonObject ?: return null
      val generatedAt = obj.strictText("generatedAt") ?: return null
      val nodeId = obj.strictText("nodeId") ?: return null
      val publicKey = obj.strictText("publicKey") ?: return null
      val array = obj["items"] as? JsonArray ?: return null
      val items = ArrayList<PopopxNodeFeedItem>(array.size)
      for (element in array) {
        val item = element as? JsonObject ?: return null
        val id = item.strictText("id") ?: return null
        val title = item.strictText("title") ?: return null
        val summary = item.strictText("summary") ?: return null
        val source = item.strictText("source") ?: return null
        val sourceLabel = item.strictText("sourceLabel") ?: return null
        val link = item.strictText("link") ?: return null
        val timestamp = item.strictText("timestamp") ?: return null
        val sha256 = item.strictText("sha256") ?: return null
        val signature = item.strictText("signature") ?: return null
        items.add(PopopxNodeFeedItem(id, title, summary, source, sourceLabel, link, timestamp, sha256, signature))
      }
      return PopopxNodeFeedSnapshot(
        items = items,
        generatedAt = generatedAt,
        nodeId = nodeId,
        publicKey = publicKey,
        keyChangedAtMs = obj["keyChangedAtMs"]?.let { (it as? JsonPrimitive)?.let { p -> if (p.isString) null else p.content.toLongOrNull() } },
      )
    }

    fun toJson(snapshot: PopopxNodeFeedSnapshot): JsonObject {
      val members = LinkedHashMap<String, JsonElement>()
      members["generatedAt"] = JsonPrimitive(snapshot.generatedAt)
      members["nodeId"] = JsonPrimitive(snapshot.nodeId)
      members["publicKey"] = JsonPrimitive(snapshot.publicKey)
      snapshot.keyChangedAtMs?.let { members["keyChangedAtMs"] = JsonPrimitive(it) }
      members["items"] = JsonArray(snapshot.items.map { item ->
        val row = LinkedHashMap<String, JsonElement>()
        row["id"] = JsonPrimitive(item.id)
        row["title"] = JsonPrimitive(item.title)
        row["summary"] = JsonPrimitive(item.summary)
        row["source"] = JsonPrimitive(item.source)
        row["sourceLabel"] = JsonPrimitive(item.sourceLabel)
        row["link"] = JsonPrimitive(item.link)
        row["timestamp"] = JsonPrimitive(item.timestamp)
        row["sha256"] = JsonPrimitive(item.sha256)
        row["signature"] = JsonPrimitive(item.signature)
        JsonObject(row)
      })
      return JsonObject(members)
    }
  }
}

/** Every reason this layer can refuse. A value, not a log line: the caller decides which refusals are
 * silent (an unbound sender, a bad signature) and which are visible (a key that changed after pinning). */
enum class PopopxNodeFeedRefusal {
  /** Not a JSON object, or a field that is not the string/array type the producer always writes. */
  MALFORMED_JSON,

  /** `schema` absent or not `popopx.discover.feed.v1`. */
  SCHEMA,

  /** `publicKey` absent, empty, not unpadded base64url, or not 32 bytes. */
  EMPTY_KEY,

  /** `signature` absent or empty. */
  EMPTY_SIG,

  /** An item is not an object, misses a field, has an empty `id`/`signature`, a `sha256` that is not 64
   * characters, or there are more items than the node is allowed to emit. */
  ITEM_SHAPE,

  /** `sha256Hex(canonical item body)` is not the digest on the item. */
  ITEM_DIGEST,

  /** An item signature does not verify under the envelope key. */
  ITEM_SIGNATURE,

  /** The envelope signature does not verify under the envelope key. */
  ENVELOPE_SIGNATURE,

  /** The envelope key differs from the pinned one. Refusing is the whole point: switching quietly would
   * turn a possible key rotation into a silent accept. */
  KEY_MISMATCH,

  /** `generatedAt` unreadable, or not strictly newer than the snapshot on file. */
  STALE,
}

sealed class PopopxNodeFeedVerdict {
  data class Accepted(val feed: PopopxNodeFeed) : PopopxNodeFeedVerdict()
  data class Refused(val reason: PopopxNodeFeedRefusal) : PopopxNodeFeedVerdict()
}

/**
 * What storing one envelope decided. [state] is the snapshot to persist: on a refusal it is the previous
 * one, with `keyChangedAtMs` stamped when the refusal was a key change, so the caller has one thing to
 * write instead of remembering which refusals are worth remembering.
 */
sealed class PopopxNodeFeedApply {
  data class Stored(val snapshot: PopopxNodeFeedSnapshot) : PopopxNodeFeedApply()
  data class Refused(val reason: PopopxNodeFeedRefusal, val state: PopopxNodeFeedSnapshot?) : PopopxNodeFeedApply()
}

object PopopxNodeFeedWire {
  const val SCHEMA_IDENTIFIER = "popopx.discover.feed.v1"

  /** `DiscoverConfig.maximumItems` on the node (`DiscoverModels.swift:98`): more than this is not a feed the
   * producer can make, so it is refused instead of silently truncated. */
  const val MAXIMUM_ITEMS = 60

  /** The same ceiling the mount applies before it asks XFTP for the bytes and again before it reads them. */
  const val MAXIMUM_FEED_BYTES: Long = 262_144L

  /** `AppPaths.discoverFeedFile` (`MacNodeModels.swift:3174`) — the basename the bridge puts in the file item. */
  const val ARTIFACT_FILE_NAME = "feed.json"

  private const val ED25519_PUBLIC_BYTES = 32
  private const val BASE64URL_ALPHABET =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

  /** Item keys in the order Foundation's `.sortedKeys` emits them — measured against `JSONSerialization`
   * on every vector by `PopopxNodeFeedWireTests`, not assumed. */
  internal val ITEM_KEYS = listOf("id", "link", "sha256", "signature", "source", "sourceLabel", "summary", "timestamp", "title")

  /** The seven keys of the item signing body. `sha256` and `signature` are excluded, which is why an item's
   * digest can be checked before its signature is believed. */
  internal val ITEM_BODY_KEYS = listOf("id", "link", "source", "sourceLabel", "summary", "timestamp", "title")

  /** Envelope keys, same measurement. `items` is an array and keeps its wire order. */
  internal val ENVELOPE_BODY_KEYS = listOf("generatedAt", "items", "nodeId", "publicKey", "schema")

  /** Are these the bytes the node publishes? Exact basename and a size the producer can actually make.
   * Transport and sender identity are the caller's half — this layer has no chat model. */
  fun isArtifact(fileName: String, byteCount: Long): Boolean =
    fileName == ARTIFACT_FILE_NAME && byteCount > 0L && byteCount <= MAXIMUM_FEED_BYTES

  /** The narrow predicate the mount asks before downloading a node artifact, kept beside the byte ceiling
   * it applies. `fromBoundNode` is the whole security story: an unbound sender with a perfectly signed feed
   * is still not a node this device agreed to listen to. */
  fun shouldAutoReceive(
    fileName: String,
    byteCount: Long,
    alreadyReceived: Boolean,
    fromBoundNode: Boolean,
  ): Boolean = fromBoundNode && !alreadyReceived && isArtifact(fileName, byteCount)

  // MARK: Canonical bodies

  /** The bytes an item's `sha256` and signature are made of. */
  fun canonicalItemBody(item: PopopxNodeFeedItem): ByteArray {
    val builder = StringBuilder()
    builder.append('{')
    ITEM_BODY_KEYS.forEachIndexed { index, key ->
      if (index > 0) builder.append(',')
      appendQuoted(builder, key)
      builder.append(':')
      appendQuoted(builder, item.field(key))
    }
    builder.append('}')
    return toUtf8(builder.toString())
  }

  /** The nine-key form of one item, as it appears **inside** the envelope body. */
  private fun appendItemObject(builder: StringBuilder, item: PopopxNodeFeedItem) {
    builder.append('{')
    ITEM_KEYS.forEachIndexed { index, key ->
      if (index > 0) builder.append(',')
      appendQuoted(builder, key)
      builder.append(':')
      appendQuoted(builder, item.field(key))
    }
    builder.append('}')
  }

  /** The bytes the envelope signature is made of: five keys, every item present as its full nine-key
   * object, in array order. */
  fun canonicalEnvelopeBody(feed: PopopxNodeFeed): ByteArray {
    val builder = StringBuilder()
    builder.append('{')
    ENVELOPE_BODY_KEYS.forEachIndexed { index, key ->
      if (index > 0) builder.append(',')
      appendQuoted(builder, key)
      builder.append(':')
      if (key == "items") {
        builder.append('[')
        feed.items.forEachIndexed { itemIndex, item ->
          if (itemIndex > 0) builder.append(',')
          appendItemObject(builder, item)
        }
        builder.append(']')
      } else {
        appendQuoted(builder, feed.field(key))
      }
    }
    builder.append('}')
    return toUtf8(builder.toString())
  }

  private fun appendQuoted(builder: StringBuilder, text: String) {
    builder.append('"')
    escapeInto(builder, text)
    builder.append('"')
  }

  /** A hostile feed must not be able to crash the receiver, so this never throws: the default
   * `encodeToByteArray()` replaces an unpaired surrogate with U+FFFD instead of trapping. Such a body still
   * fails its digest, and Foundation cannot even *parse* that escape, so no real producer ever signs one. */
  private fun toUtf8(text: String): ByteArray = text.encodeToByteArray()

  /** The escape table measured against Foundation on the iOS side (`PopopxNodeFeedWire.swift:26-44`):
   * `"` and `\`, the five named control escapes, every other scalar under 0x20 as lowercase `\u00xx`, and
   * nothing else — `/` stays raw (that is what `.withoutEscapingSlashes` buys), non-ASCII stays raw UTF-8,
   * and no normalization is performed. */
  private fun escapeInto(builder: StringBuilder, text: String) {
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
        character.code < 0x20 -> builder.append("\\u00").append(hexDigit(character.code shr 4)).append(hexDigit(character.code and 0x0F))
        else -> builder.append(character)
      }
      index += 1
    }
  }

  private fun hexDigit(nibble: Int): Char =
    if (nibble < 10) ('0' + nibble) else ('a' + (nibble - 10))

  // MARK: Parsing

  /** Decodes and structurally checks the envelope. It does not look at a key it was not given, so it is
   * safe to call on any bytes; everything cryptographic is in [verify]. */
  fun parse(bytes: ByteArray): PopopxNodeFeedVerdict {
    if (bytes.size > MAXIMUM_FEED_BYTES) return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.MALFORMED_JSON)
    val obj = popopxJsonDecode(bytes.decodeToString()) as? JsonObject
      ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.MALFORMED_JSON)

    val schema = obj.strictText("schema") ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.SCHEMA)
    if (schema != SCHEMA_IDENTIFIER) return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.SCHEMA)

    val generatedAt = obj.strictText("generatedAt") ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.MALFORMED_JSON)
    val nodeId = obj.strictText("nodeId") ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.MALFORMED_JSON)
    val publicKey = obj.strictText("publicKey") ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.MALFORMED_JSON)
    if (publicKey.isEmpty() || keyBytes(publicKey) == null) {
      return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.EMPTY_KEY)
    }
    val signature = obj.strictText("signature")
    if (signature.isNullOrEmpty()) return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.EMPTY_SIG)

    val rawItems = obj["items"] as? JsonArray ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SHAPE)
    if (rawItems.size > MAXIMUM_ITEMS) return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SHAPE)
    val items = ArrayList<PopopxNodeFeedItem>(rawItems.size)
    for (element in rawItems) {
      val item = element as? JsonObject ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SHAPE)
      val id = item.strictText("id") ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SHAPE)
      val title = item.strictText("title") ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SHAPE)
      val summary = item.strictText("summary") ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SHAPE)
      val source = item.strictText("source") ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SHAPE)
      val sourceLabel = item.strictText("sourceLabel") ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SHAPE)
      val link = item.strictText("link") ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SHAPE)
      val timestamp = item.strictText("timestamp") ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SHAPE)
      val sha256 = item.strictText("sha256") ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SHAPE)
      val itemSignature = item.strictText("signature") ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SHAPE)
      // `structuralRefusal` on the node: an empty id or signature, or a digest that is not 64 characters,
      // condemns the whole envelope rather than that one item.
      if (id.isEmpty() || itemSignature.isEmpty() || sha256.length != 64) {
        return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SHAPE)
      }
      items.add(PopopxNodeFeedItem(id, title, summary, source, sourceLabel, link, timestamp, sha256, itemSignature))
    }
    return PopopxNodeFeedVerdict.Accepted(PopopxNodeFeed(schema, generatedAt, nodeId, publicKey, items, signature))
  }

  // MARK: Verification

  /** The whole acceptance chain, in the order that costs least first. `trustedPublicKey` is the pinned key,
   * null when nothing is pinned yet; `newerThanMs` is the stored snapshot's instant. */
  fun verify(
    feed: PopopxNodeFeed,
    trustedPublicKey: String?,
    newerThanMs: Long?,
  ): PopopxNodeFeedVerdict {
    if (trustedPublicKey != null && trustedPublicKey != feed.publicKey) {
      return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.KEY_MISMATCH)
    }
    val key = keyBytes(feed.publicKey) ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.EMPTY_KEY)
    for (item in feed.items) {
      val body = canonicalItemBody(item)
      if (sha256Hex(body) != item.sha256.lowercase()) {
        return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_DIGEST)
      }
      if (!verifySignature(item.signature, body, key)) {
        return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ITEM_SIGNATURE)
      }
    }
    val envelopeBody = canonicalEnvelopeBody(feed)
    if (!verifySignature(feed.signature, envelopeBody, key)) {
      return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.ENVELOPE_SIGNATURE)
    }
    val generatedAtMs = feed.generatedAtMs ?: return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.STALE)
    if (newerThanMs != null && generatedAtMs <= newerThanMs) {
      return PopopxNodeFeedVerdict.Refused(PopopxNodeFeedRefusal.STALE)
    }
    return PopopxNodeFeedVerdict.Accepted(feed)
  }

  fun verify(bytes: ByteArray, trustedPublicKey: String?, newerThanMs: Long?): PopopxNodeFeedVerdict =
    when (val parsed = parse(bytes)) {
      is PopopxNodeFeedVerdict.Refused -> parsed
      is PopopxNodeFeedVerdict.Accepted -> verify(parsed.feed, trustedPublicKey, newerThanMs)
    }

  /**
   * The store-side half of the chain: pin on first success (TOFU), refuse a rotated key, refuse a feed that
   * is not strictly newer. It lives here rather than in the engine because all four of those decisions are
   * testable against the pinned vectors, and the engine's persistence is not the same claim.
   */
  fun ingest(data: ByteArray, current: PopopxNodeFeedSnapshot?, nowMs: Long): PopopxNodeFeedApply {
    return when (val verdict = verify(data, current?.publicKey, current?.generatedAtMs)) {
      is PopopxNodeFeedVerdict.Accepted -> {
        // A warning already on record survives a later success. Clearing it here would let whoever changed
        // the key once also erase the evidence by sending a second, correct feed.
        PopopxNodeFeedApply.Stored(PopopxNodeFeedSnapshot.of(verdict.feed).copy(keyChangedAtMs = current?.keyChangedAtMs))
      }
      is PopopxNodeFeedVerdict.Refused -> {
        val state = current
        if (verdict.reason != PopopxNodeFeedRefusal.KEY_MISMATCH || state == null || state.keyChangedAtMs != null) {
          PopopxNodeFeedApply.Refused(verdict.reason, state)
        } else {
          PopopxNodeFeedApply.Refused(verdict.reason, state.copy(keyChangedAtMs = nowMs))
        }
      }
    }
  }

  // MARK: Primitives

  /** Unpadded base64url of the raw 32-byte Ed25519 key — the form `publicKeyBase64URL` writes
   * (`MacNodePopopxBridge.swift:556`). A padded or standard-alphabet key is refused, not repaired: two
   * decodings of one string is how two implementations disagree about a key. [base64UrlDecode] is lenient
   * about padding and `+/` by design, so the character class is checked here first. */
  internal fun keyBytes(text: String): ByteArray? {
    if (!isUnpaddedBase64URL(text)) return null
    val raw = base64UrlDecode(text) ?: return null
    return if (raw.size == ED25519_PUBLIC_BYTES) raw else null
  }

  internal fun verifySignature(signature: String, body: ByteArray, key: ByteArray): Boolean {
    if (!isUnpaddedBase64URL(signature)) return false
    val raw = base64UrlDecode(signature) ?: return false
    return ed25519Verify(key, body, raw)
  }

  private fun isUnpaddedBase64URL(text: String): Boolean =
    text.isNotEmpty() && text.all { BASE64URL_ALPHABET.contains(it) } && text.length % 4 != 1

  /** ISO 8601 → epoch milliseconds, the two forms the node emits (with and without fractional seconds).
   * Unreadable is a refusal, never a zero. */
  internal fun instantMillis(text: String): Long? =
    try {
      Instant.parse(text).toEpochMilliseconds()
    } catch (_: Exception) {
      null
    }
}

/** A string field or nothing — a number is not the string the producer writes, and describing it is not
 * this decoder's job. File-private so both [PopopxNodeFeedSnapshot.fromJson] and [PopopxNodeFeedWire] read
 * the same rule. */
private fun JsonObject.strictText(key: String): String? {
  val primitive = this[key] as? JsonPrimitive ?: return null
  return if (primitive.isString) primitive.content else null
}
