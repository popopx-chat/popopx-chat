package chat.popopx.common.discover

import chat.popopx.common.crypto.base64UrlDecode
import chat.popopx.common.crypto.ed25519Verify
import chat.popopx.common.crypto.sha256Hex
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * The pairing code and the local binding it leaves behind
 * (DiscoverCatalogModels.swift:524-681, MacNodePairingSheet.swift:179-198).
 *
 * The security posture, stated once because three files repeat it: the offer is SELF-DECLARED.
 * Anyone can type a key and a node id, so the signature only proves the bytes were not edited in
 * transit — there is no trust root, and nothing here upgrades to one
 * (DiscoverCatalogModels.swift:524-537). What the app promises about that reality:
 *
 *  1. A failed verification is a SILENT drop. [evaluate] returns a typed reason for tests and the
 *     local log, and the user-visible answer to every failure — wrong syntax, bad signature, stale
 *     offer — is one shared sentence ([PopopxDiscoverCopy.GENERIC_PAIRING_NOTICE]). The sheet's
 *     comment is explicit that distinguishing "not a code" from "forged code" is an oracle
 *     (MacNodePairingSheet.swift:177-178); this port keeps that property: the reason never reaches
 *     the UI layer.
 *  2. The signature is checked over the DECODED JSON BYTES, not the base64 text. That is the one
 *     place the two platforms could disagree silently, so a real CryptoKit signature over the
 *     base64 TEXT is pinned as a must-fail vector (`wrongTextSignatureIsRefused`).
 *  3. Nothing is stored, marked paired, or spent on an offer that fails.
 *
 * This module only PASTES codes. iOS has no camera path for node pairing at all
 * (MacNodePairingSheet.swift:12-20: "there is no camera step on iPhone or iPad, and the Mac
 * itself has no camera here either") — the brief keeps paste-and-verify, so no QR machinery
 * needed porting.
 */
object PopopxNodePairing {
  /**
   * `PopopxNodePairingOffer.decode(signalPayload:)` equivalent (:560-591): syntax, fields and
   * signature only, NO clock. iOS deliberately keeps expiry out of the decoder — it is a fact the
   * sheet checks separately (`isLive`, :552-555) — and this mirror keeps the split.
   *
   * Returns null on every failure, saying nothing, exactly as iOS returns nil. The engine uses
   * [evaluate]; this is the format half for callers that only ask "is this a well-formed offer".
   */
  fun parse(text: String): PopopxNodePairingOffer? = (evaluate(text, includeFreshness = false) as? PopopxPairingVerdict.Accepted)?.offer

  /**
   * Full gate: format + signature + freshness window. `nowMs` is the injected seam millisecond;
   * the wire's `iat`/`exp` are SECONDS and become [PopopxNodePairingOffer.issuedAtMs]/
   * [PopopxNodePairingOffer.expiresAtMs] here (:586-589), so every consumer downstream works in
   * milliseconds.
   */
  internal fun evaluate(text: String, nowMs: Long): PopopxPairingVerdict {
    val verdict = evaluate(text, includeFreshness = true)
      ?: return PopopxPairingVerdict.Rejected(PopopxPairingRejection.NOT_OFFER_SYNTAX)
    if (verdict is PopopxPairingVerdict.Accepted) {
      val offer = verdict.offer
      // `isLive` (DiscoverCatalogModels.swift:552-555): the lower bound is inclusive, the upper is
      // exclusive, so the expiry instant itself is already stale.
      if (nowMs < offer.issuedAtMs) return PopopxPairingVerdict.Rejected(PopopxPairingRejection.OFFER_NOT_YET_VALID)
      if (nowMs >= offer.expiresAtMs) return PopopxPairingVerdict.Rejected(PopopxPairingRejection.OFFER_STALE)
    }
    return verdict
  }

  private fun evaluate(text: String, includeFreshness: Boolean): PopopxPairingVerdict? {
    // The sheet trims before anything else (MacNodePairingSheet.swift:180), so leading/trailing
    // whitespace from a paste is normal and never counts as "not an offer".
    val trimmed = text.trim { it.isWhitespace() }
    if (!trimmed.startsWith(PopopxNodeWire.PAIRING_CODE_PREFIX + "-")) {
      return reject(includeFreshness, PopopxPairingRejection.NOT_OFFER_SYNTAX)
    }
    val body = trimmed.substring(PopopxNodeWire.PAIRING_CODE_PREFIX.length + 1)

    // Split on the FIRST "." only (:566-568). The signature is base64url — which never contains a
    // period — so taking "the rest" is safe and a code with a stray dot keeps failing anyway.
    val dot = body.indexOf('.')
    if (dot < 0) return reject(includeFreshness, PopopxPairingRejection.NOT_OFFER_SYNTAX)
    val bodyPart = body.substring(0, dot)
    val signaturePart = body.substring(dot + 1)
    if (bodyPart.isEmpty() || signaturePart.isEmpty()) {
      return reject(includeFreshness, PopopxPairingRejection.NOT_OFFER_SYNTAX)
    }

    // `bodyData` is kept as BYTES: it is the signature preimage (:570-574). Decoding it to a String
    // first and re-encoding could normalise something the signer hashed over.
    val bodyBytes = base64UrlDecode(bodyPart) ?: return reject(includeFreshness, PopopxPairingRejection.BODY_UNDECODABLE)
    if (bodyBytes.isEmpty()) return reject(includeFreshness, PopopxPairingRejection.BODY_UNDECODABLE)
    val signature = base64UrlDecode(signaturePart) ?: return reject(includeFreshness, PopopxPairingRejection.SIGNATURE_INVALID)

    val json = try {
      (Json.parseToJsonElement(bodyBytes.decodeToString()) as? JsonObject)
        ?: return reject(includeFreshness, PopopxPairingRejection.BODY_UNDECODABLE)
    } catch (_: Exception) {
      return reject(includeFreshness, PopopxPairingRejection.BODY_UNDECODABLE)
    }

    // Required fields: present and the right type, or the whole code is dropped (:576-580).
    val nodeId = json.strictString("node") ?: return reject(includeFreshness, PopopxPairingRejection.FIELD_INVALID)
    val publicKey = json.strictString("key") ?: return reject(includeFreshness, PopopxPairingRejection.FIELD_INVALID)
    val link = json.strictString("link") ?: return reject(includeFreshness, PopopxPairingRejection.FIELD_INVALID)
    // `iat`/`exp` are integers on the wire; a quoted "1760000000" is a type error, not a number
    // (DiscoverSubscriptionManager-style strictness, see EcoWire.kt:26-34 for the same rule).
    val issuedAtSeconds = json.strictSeconds("iat") ?: return reject(includeFreshness, PopopxPairingRejection.FIELD_INVALID)
    val expiresAtSeconds = json.strictSeconds("exp") ?: return reject(includeFreshness, PopopxPairingRejection.FIELD_INVALID)
    // Defensive, not a ported rule: Swift multiplies these into Int64 milliseconds and would trap
    // on an absurd value; turning the offer away instead of crashing is accepting less, never more.
    if (absLong(issuedAtSeconds) > PopopxDiscoverLimits.MAXIMUM_OFFER_EPOCH_SECONDS ||
      absLong(expiresAtSeconds) > PopopxDiscoverLimits.MAXIMUM_OFFER_EPOCH_SECONDS
    ) {
      return reject(includeFreshness, PopopxPairingRejection.FIELD_INVALID)
    }
    // Optional fields fall back to their defaults instead of rejecting — but only when ABSENT.
    // Swift reads `v` and `once` with the lenient accessor (:584, :585); a wrong-typed `v` on this
    // wire would already have failed JSON parsing to reach here.
    val schemaRevision = json.lenientInt("v") ?: 0
    val singleUse = json.lenientBoolean("once") ?: true

    val publicKeyBytes = base64UrlDecode(publicKey)
    if (publicKeyBytes == null || publicKeyBytes.size != ED25519_PUBLIC_BYTES) {
      return reject(includeFreshness, PopopxPairingRejection.PUBLIC_KEY_MALFORMED)
    }
    // VERIFY BEFORE CONSTRUCTING (:586-590): the offer object only ever exists for a code whose
    // signature opened. This is the line a careless port flips.
    if (signature.size != ED25519_SIGNATURE_BYTES || !ed25519Verify(publicKeyBytes, bodyBytes, signature)) {
      return reject(includeFreshness, PopopxPairingRejection.SIGNATURE_INVALID)
    }

    // `isValid` (:544-550): non-empty node/key/link. After the strict reads above this is only the
    // empty-string case, but iOS keeps it as a separate gate and so does this.
    if (nodeId.isEmpty() || publicKey.isEmpty() || link.isEmpty()) {
      return reject(includeFreshness, PopopxPairingRejection.OFFER_INCOMPLETE)
    }

    return PopopxPairingVerdict.Accepted(
      PopopxNodePairingOffer(
        code = trimmed,
        nodeId = nodeId,
        publicKeyBase64URL = publicKey,
        link = link,
        schemaRevision = schemaRevision,
        singleUse = singleUse,
        issuedAtMs = issuedAtSeconds * 1_000L,
        expiresAtMs = expiresAtSeconds * 1_000L,
      ),
    )
  }

  /** Clock gates belong to the full path only; a format-only caller must not see them. */
  private fun reject(includeFreshness: Boolean, reason: PopopxPairingRejection): PopopxPairingVerdict? =
    if (includeFreshness) PopopxPairingVerdict.Rejected(reason) else null

  private const val ED25519_PUBLIC_BYTES = 32
  private const val ED25519_SIGNATURE_BYTES = 64

  private fun JsonObject.strictString(key: String): String? {
    val element = this[key] ?: return null
    val primitive = element as? JsonPrimitive ?: return null
    return if (primitive.isString) primitive.content else null
  }

  private fun JsonObject.strictSeconds(key: String): Long? {
    val element = this[key] ?: return null
    val primitive = element as? JsonPrimitive ?: return null
    if (primitive.isString) return null
    return primitive.content.toLongOrNull()
  }

  private fun JsonObject.lenientInt(key: String): Int? {
    val element = this[key] ?: return null
    val primitive = element as? JsonPrimitive ?: return null
    if (primitive.isString) return null
    return primitive.content.toIntOrNull()
  }

  private fun JsonObject.lenientBoolean(key: String): Boolean? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    if (primitive.isString) return null
    return when (primitive.content) {
      "true" -> true
      "false" -> false
      else -> null
    }
  }

  private fun absLong(value: Long): Long = if (value == Long.MIN_VALUE) Long.MAX_VALUE else if (value < 0) -value else value
}

/**
 * WHY this module keeps its own strict JSON readers instead of importing eco's identical
 * internal ones (`chat.popopx.common.eco.string/long/int/boolean`, EcoWire.kt:21-44): eco is
 * another agent's live lane; borrowing its internals would make a rename in that file break
 * Discover. The RULE is copied (absent → default, wrong type → drop the whole message), the
 * code is not shared. Same reason the result-card and binding codecs are local.
 */

/** The typed, never-user-visible reason an offer was dropped. Internal: the UI only gets the generic notice. */
internal enum class PopopxPairingRejection {
  NOT_OFFER_SYNTAX,
  BODY_UNDECODABLE,
  FIELD_INVALID,
  PUBLIC_KEY_MALFORMED,
  SIGNATURE_INVALID,
  OFFER_STALE,
  OFFER_NOT_YET_VALID,
  OFFER_INCOMPLETE,
}

internal sealed class PopopxPairingVerdict {
  data class Accepted(val offer: PopopxNodePairingOffer) : PopopxPairingVerdict()
  data class Rejected(val reason: PopopxPairingRejection) : PopopxPairingVerdict()
}

/**
 * A verified pairing offer (DiscoverCatalogModels.swift:540-558). `code` keeps the exact trimmed
 * text because its digest is stored as the binding's fingerprint (:657-659) — re-serialising the
 * JSON would produce a different fingerprint for the same pairing.
 *
 * There is deliberately no "trusted" flag: nothing here establishes trust, only integrity
 * (:530-537).
 */
data class PopopxNodePairingOffer(
  val code: String,
  val nodeId: String,
  val publicKeyBase64URL: String,
  val link: String,
  val schemaRevision: Int,
  val singleUse: Boolean,
  val issuedAtMs: Long,
  val expiresAtMs: Long,
) {
  /** `isLive(at:)`, DiscoverCatalogModels.swift:552-555: lower bound inclusive, upper exclusive. */
  fun isLive(nowMs: Long): Boolean = nowMs >= issuedAtMs && nowMs < expiresAtMs

  /** Seconds on the wire (`lifetime` analogue); the 900 s the Mac stamps. */
  val lifetimeSeconds: Long get() = (expiresAtMs - issuedAtMs) / 1_000L
}

/**
 * What pairing leaves on the device (DiscoverCatalogModels.swift:613-681). The node's public key
 * is stored in its base64url form because every consumer is this app, and re-deriving the wire
 * string from raw bytes would silently break the fingerprint if the alphabet ever changed.
 */
data class PopopxMacNodeBinding(
  val nodeId: String,
  val publicKeyBase64URL: String,
  /** User-typed; iOS starts it empty (:644) and the edit sheet is the only writer. */
  val deviceLabel: String,
  /** `PopopxBadgeCodec.shortDigest(code)` at pairing time (:657-659) — 16 lower hex chars, for logging a pairing without logging the code. */
  val offerFingerprint: String,
  val pairedAtMs: Long,
  /** Kept so "attempt handshake" can say no to an offer that has since expired (:670-674). */
  val offerExpiresAtMs: Long,
  val contactId: Long? = null,
  val contactDisplayName: String? = null,
  val handshakeConfirmed: Boolean = false,
) {
  val id: String get() = nodeId

  /** `isBondedToChat` (:666-668): the node reached a chat contact, not just a paste field. */
  val isBondedToChat: Boolean get() = contactId != null

  /** `canAttemptHandshake(at:)` (:670-674): strictly before expiry, and only meaningful once bonded. */
  fun canAttemptHandshake(nowMs: Long): Boolean = nowMs < offerExpiresAtMs

  companion object {
    /** `init(offer:now:)` (:642-651): label empty, handshake unconfirmed, fingerprint of the code. */
    fun of(offer: PopopxNodePairingOffer, nowMs: Long): PopopxMacNodeBinding =
      PopopxMacNodeBinding(
        nodeId = offer.nodeId,
        publicKeyBase64URL = offer.publicKeyBase64URL,
        deviceLabel = "",
        offerFingerprint = popopxShortDigest(offer.code),
        pairedAtMs = nowMs,
        offerExpiresAtMs = offer.expiresAtMs,
      )

    fun fromJson(json: JsonObject): PopopxMacNodeBinding? {
      val nodeId = json.strictText("nodeId") ?: return null
      val publicKey = json.strictText("publicKeyBase64URL") ?: return null
      if (nodeId.isEmpty() || publicKey.isEmpty()) return null
      // iOS Codable throws on a wrong-typed OPTIONAL, discarding the binding; this reader nulls it.
      // The blob only ever comes back from our own keystore write, so the looseness is unreachable
      // — noted rather than ported for exactness.
      return PopopxMacNodeBinding(
        nodeId = nodeId,
        publicKeyBase64URL = publicKey,
        deviceLabel = json.strictText("deviceLabel") ?: return null,
        offerFingerprint = json.strictText("offerFingerprint") ?: return null,
        pairedAtMs = json.strictLong("pairedAtMs") ?: return null,
        offerExpiresAtMs = json.strictLong("offerExpiresAtMs") ?: return null,
        contactId = json.strictLong("contactId"),
        contactDisplayName = json.strictText("contactDisplayName"),
        handshakeConfirmed = json.strictBoolean("handshakeConfirmed") ?: false,
      )
    }

    /** Stable key order; this object is signed nothing, but a re-save after load should be identical. */
    fun toJson(binding: PopopxMacNodeBinding): JsonObject {
      val members = LinkedHashMap<String, JsonElement>()
      members["nodeId"] = JsonPrimitive(binding.nodeId)
      members["publicKeyBase64URL"] = JsonPrimitive(binding.publicKeyBase64URL)
      members["deviceLabel"] = JsonPrimitive(binding.deviceLabel)
      members["offerFingerprint"] = JsonPrimitive(binding.offerFingerprint)
      members["pairedAtMs"] = JsonPrimitive(binding.pairedAtMs)
      members["offerExpiresAtMs"] = JsonPrimitive(binding.offerExpiresAtMs)
      binding.contactId?.let { members["contactId"] = JsonPrimitive(it) }
      binding.contactDisplayName?.let { members["contactDisplayName"] = JsonPrimitive(it) }
      members["handshakeConfirmed"] = JsonPrimitive(binding.handshakeConfirmed)
      return JsonObject(members)
    }

    private fun JsonObject.strictText(key: String): String? {
      val primitive = this[key] as? JsonPrimitive ?: return null
      return if (primitive.isString) primitive.content else null
    }

    private fun JsonObject.strictLong(key: String): Long? {
      val primitive = this[key] as? JsonPrimitive ?: return null
      if (primitive.isString) return null
      return primitive.content.toLongOrNull()
    }

    private fun JsonObject.strictBoolean(key: String): Boolean? {
      val primitive = this[key] as? JsonPrimitive ?: return null
      if (primitive.isString) return null
      return when (primitive.content) {
        "true" -> true
        "false" -> false
        else -> null
      }
    }
  }
}

/**
 * The fingerprint iOS stores per pairing (`shortDigest`, PopopxBadgeCreditsModels.swift:1602-1607):
 * first 8 SHA-256 bytes of the UTF-8 text, lower-case hex — 16 characters. Pinned against a value
 * generated by Apple's own CryptoKit (`PopopxDiscoverSwiftVectors`).
 */
internal fun popopxShortDigest(text: String): String = sha256Hex(text.encodeToByteArray()).substring(0, 16)

/** The stored-JSON helpers shared by this package's persistence (engine + binding). */
internal fun popopxJsonArrayText(elements: List<JsonObject>): String =
  elements.joinToString(prefix = "[", postfix = "]") { it.toString() }

internal fun popopxJsonEncode(obj: JsonObject): String = obj.toString()

internal fun popopxJsonDecode(text: String): JsonElement? = try {
  Json.parseToJsonElement(text)
} catch (_: Exception) {
  null
}
