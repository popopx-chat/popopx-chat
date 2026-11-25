package chat.popopx.common.cfgsec

import chat.popopx.common.crypto.base64UrlDecode
import chat.popopx.common.crypto.hexEncode
import chat.popopx.common.crypto.sha256
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// The wire frame and the body parser, ported from
// apps/ios/Shared/Features/ServerConfigSync/PopopxServerClusterConfig.swift:449-1060.

/** One decoded frame, before any decision about it. */
class PopopxServerConfigFrame(
  val payload: PopopxServerClusterPayload,
  /** The body exactly as it was inflated from the signed bytes: the receipt hashes *this*. */
  val body: ByteArray,
  /** First sixteen hex characters of the body's SHA-256. */
  val bodyHash: String,
  /** Index into the trust list of the key that verified. */
  val trustedKeyIndex: Int,
)

sealed class PopopxServerConfigDecode {
  class Accepted(val frame: PopopxServerConfigFrame) : PopopxServerConfigDecode()
  class Refused(val reason: PopopxServerConfigRejection) : PopopxServerConfigDecode()

  val frameOrNull: PopopxServerConfigFrame? get() = (this as? Accepted)?.frame
}

/** Codec for the configuration frame, with its own grammar rather than a case in another codec. */
object PopopxServerConfigWire {
  const val MARKER: String = "::popopx_sys::"
  const val CONFIG_KIND: String = "SERVER_CFG_V1"
  const val ACK_KIND: String = "SERVER_CFG_ACK"
  const val CONFIG_PREFIX: String = "$MARKER$CONFIG_KIND::"
  const val ACK_PREFIX: String = "$MARKER$ACK_KIND::"

  /**
   * The suppression criterion. Shape only, on purpose: an expired frame, a frame signed by nobody, and a
   * frame longer than any honest one are all still hidden, because a forged frame that renders as a bubble
   * is the outcome being prevented rather than the one being diagnosed. Nothing is decoded here, no key is
   * consulted and no length is rejected.
   *
   * Trimming is part of *this* test only; the acceptance path refuses a line with anything in front of the
   * prefix, so a leading space produces a hidden nothing rather than an update.
   */
  fun isControlText(text: String): Boolean {
    val trimmed = text.trim()
    val body = when {
      trimmed.startsWith(CONFIG_PREFIX) -> trimmed.drop(CONFIG_PREFIX.length)
      trimmed.startsWith(ACK_PREFIX) -> trimmed.drop(ACK_PREFIX.length)
      else -> return false
    }
    return body.none { it.isWhitespace() }
  }

  /** Decode, verify and validate one frame, in that order and no other. */
  fun decodeConfigFrame(text: String, now: Long): PopopxServerConfigDecode =
    decodeConfigFrame(text, now, PopopxServerConfigTrust.signingPublicKeys)

  /**
   * The same decode against a caller-supplied key list.
   *
   * The default above is the pinned production set; this overload exists so a test can carry a frame from a key
   * it generated itself all the way through the pipeline. It is internal for a reason: a production call site
   * that reached it could be handed a list that trusts an attacker's key, and every safety property below would
   * still hold while meaning nothing.
   */
  internal fun decodeConfigFrame(text: String, now: Long, keys: List<ByteArray>): PopopxServerConfigDecode = try {
    PopopxServerConfigDecode.Accepted(decodeOrThrow(text, now, keys))
  } catch (e: PopopxServerConfigRefused) {
    PopopxServerConfigDecode.Refused(e.reason)
  }

  internal fun decodeOrThrow(text: String, now: Long, keys: List<ByteArray>): PopopxServerConfigFrame {
    if (!text.startsWith(CONFIG_PREFIX)) throw refused(PopopxServerConfigRejection.FRAME_PREFIX_MISSING)
    val segment = text.drop(CONFIG_PREFIX.length)
    if (PopopxServerConfigHost.scalarCount(segment) > PopopxServerConfigLimits.MAXIMUM_SEGMENT_CHARACTERS) {
      throw refused(PopopxServerConfigRejection.SEGMENT_TOO_LONG)
    }
    val (compressed, signatureText) = tokenParts(segment)
      ?: throw refused(PopopxServerConfigRejection.TOKEN_MALFORMED)

    // Length before decoding: the order is what keeps a malformed line away from every decoder downstream.
    if (PopopxServerConfigHost.scalarCount(signatureText) != PopopxServerConfigLimits.SIGNATURE_SEGMENT_CHARACTERS) {
      throw refused(PopopxServerConfigRejection.SIGNATURE_SEGMENT_MALFORMED)
    }
    val signature = base64UrlDecode(signatureText)
      ?: throw refused(PopopxServerConfigRejection.SIGNATURE_MALFORMED)
    if (signature.size != PopopxServerConfigLimits.SIGNATURE_BYTE_COUNT) {
      throw refused(PopopxServerConfigRejection.SIGNATURE_WRONG_LENGTH)
    }
    val keyIndex = PopopxServerConfigTrust.verify(signature = signature, message = PopopxServerConfigTrust.signatureDomain + compressed.encodeToByteArray(), keys = keys)
      ?: throw refused(PopopxServerConfigRejection.SIGNATURE_NOT_VERIFYING)
    // Nothing above this line has touched a decompressor. Everything below it operates on bytes that the
    // pinned key authorized.
    val compressedBytes = base64UrlDecode(compressed)
      ?: throw refused(PopopxServerConfigRejection.TOKEN_MALFORMED)
    val body = PopopxServerConfigInflator.inflate(compressedBytes)
    return PopopxServerConfigBodyParser.parse(body, now, keyIndex, keys)
  }

  /**
   * `POPOPXCFG1-<base64url>.<base64url>`, anchored and with exactly one dot. A dot is outside the alphabet,
   * so splitting on it cannot be confused by escaping. The character test also excludes `=`, which means a
   * padded token is refused here rather than quietly tolerated by a decoder that accepts padding.
   */
  private fun tokenParts(segment: String): Pair<String, String>? {
    if (!segment.startsWith(PopopxServerConfigLimits.TOKEN_PREFIX)) return null
    val token = segment.drop(PopopxServerConfigLimits.TOKEN_PREFIX.length)
    val parts = token.split(".")
    if (parts.size != 2) return null
    if (parts.any { it.isEmpty() || !it.all(PopopxServerConfigField::isBase64UrlChar) }) return null
    return parts[0] to parts[1]
  }

  /**
   * The receipt this device sends: `::popopx_sys::SERVER_CFG_ACK::<seq>[::<bh>]`. Plain digits rather than a
   * token, because the receipt carries no instruction — only a fact about this device. `bodyHash` is what
   * turns "I acknowledge" into "I installed *this* configuration", and it is omitted only when the device is
   * reporting a generation it did not install.
   */
  fun ackFrame(seq: Long, bodyHash: String?): String? {
    if (seq < 1 || seq > PopopxServerConfigLimits.MAXIMUM_COUNTER_VALUE) return null
    if (bodyHash == null) return "$ACK_PREFIX$seq"
    if (bodyHash.length != PopopxServerConfigLimits.BODY_HASH_CHARACTERS ||
      !PopopxServerConfigField.isHex(bodyHash)
    ) return null
    return "$ACK_PREFIX$seq::$bodyHash"
  }

  /** The first sixteen hex characters of SHA-256 over the signed body: the generator's recipe, same bytes. */
  fun bodyHash(of: ByteArray): String =
    hexEncode(sha256(of)).substring(0, PopopxServerConfigLimits.BODY_HASH_CHARACTERS)

  private fun refused(reason: PopopxServerConfigRejection): PopopxServerConfigRefused =
    PopopxServerConfigRefused(reason)
}

/**
 * Turns verified bytes into a payload, or into the reason it cannot be one.
 *
 * Structural validation only: expiry against the clock is here because it is a property of the body and the
 * instant, but the anti-downgrade floor is deliberately not, because that is device state and this file must
 * stay decidable from the frame alone. Each stage names its own reason and the first one propagates.
 */
internal object PopopxServerConfigBodyParser {
  fun parse(body: ByteArray, now: Long, keyIndex: Int, keys: List<ByteArray>): PopopxServerConfigFrame {
    val object_ = PopopxServerConfigField.objectOf(body)
    val keyId = identity(object_, keyIndex, keys)
    val (seq, issuedAt, expiresAt) = clock(object_, now)
    val smp = serverRoster(
      object_["smp"],
      PopopxServerConfigLimits.MAXIMUM_SMP_SERVER_ENTRIES,
      PopopxServerConfigRejection.SMP_ROSTER_INVALID,
      PopopxServerConfigRejection.SMP_ROSTER_TOO_LARGE,
    )
    // A cluster with no SMP servers is not a cluster: it would mean "remove every server this device dials".
    if (smp.isEmpty()) throw PopopxServerConfigRefused(PopopxServerConfigRejection.SMP_ROSTER_INVALID)
    val xftp = serverRoster(
      object_["xftp"],
      PopopxServerConfigLimits.MAXIMUM_XFTP_SERVER_ENTRIES,
      PopopxServerConfigRejection.XFTP_ROSTER_INVALID,
      PopopxServerConfigRejection.XFTP_ROSTER_TOO_LARGE,
    )
    val ntf = serverRoster(
      object_["ntf"],
      PopopxServerConfigLimits.MAXIMUM_NOTIFICATION_SERVER_ENTRIES,
      PopopxServerConfigRejection.NTF_ROSTER_INVALID,
      PopopxServerConfigRejection.NTF_ROSTER_TOO_LARGE,
    )
    val relays = relayRoster(object_["relay"])
    val ice = iceRoster(object_["ice"])
    val policy = policyBlock(object_)
    val payload = PopopxServerClusterPayload(
      seq = seq,
      issuedAt = issuedAt,
      expiresAt = expiresAt,
      keyId = keyId,
      smpServers = smp,
      xftpServers = xftp,
      notificationServers = ntf,
      relays = relays,
      iceServers = ice,
      policy = policy,
    )
    return PopopxServerConfigFrame(
      payload = payload,
      body = body,
      bodyHash = PopopxServerConfigWire.bodyHash(body),
      trustedKeyIndex = keyIndex,
    )
  }

  /** Which key the payload claims, and whether that is the key that actually verified. */
  private fun identity(object_: JsonObject, keyIndex: Int, keys: List<ByteArray>): String {
    val version = PopopxServerConfigField.integer(object_["v"])
    if (version == null || version != PopopxServerConfigLimits.FORMAT_VERSION) {
      throw PopopxServerConfigRefused(PopopxServerConfigRejection.FORMAT_VERSION_UNSUPPORTED)
    }
    val encoding = PopopxServerConfigField.text(object_["enc"])
    if (encoding != PopopxServerConfigLimits.ENCODING_TAG) {
      throw PopopxServerConfigRefused(PopopxServerConfigRejection.ENCODING_UNKNOWN)
    }
    val keyId = PopopxServerConfigField.text(object_["kid"])
    if (keyId == null || !isKeyId(keyId)) {
      throw PopopxServerConfigRefused(PopopxServerConfigRejection.KEY_ID_MALFORMED)
    }
    // With two entries present for a rotation, a body carrying the retired id but verified by the new key is
    // exactly the mismatch this catches, so the comparison is against the key the signature check named.
    // The id comes from that key's own bytes rather than from the pinned hexes, which is what lets an
    // injected key list be checked by the same rule instead of falling through.
    if (keyIndex < 0 || keyIndex >= keys.size || PopopxServerConfigTrust.keyId(keys[keyIndex]) != keyId) {
      throw PopopxServerConfigRefused(PopopxServerConfigRejection.KEY_ID_MISMATCH)
    }
    return keyId
  }

  private fun isKeyId(text: String): Boolean {
    if (!text.startsWith(PopopxServerConfigLimits.KEY_ID_PREFIX)) return false
    val hash = text.drop(PopopxServerConfigLimits.KEY_ID_PREFIX.length)
    return PopopxServerConfigHost.scalarCount(hash) == PopopxServerConfigLimits.KEY_ID_HASH_CHARACTERS &&
      PopopxServerConfigField.isHex(hash)
  }

  /** The three counters, their ordering, and the two windows they have to fit inside. */
  private fun clock(object_: JsonObject, now: Long): Triple<Long, Long, Long> {
    val seq = PopopxServerConfigField.counter(object_["seq"])
      ?: throw PopopxServerConfigRefused(PopopxServerConfigRejection.SEQUENCE_MISSING)
    val issuedAt = PopopxServerConfigField.counter(object_["iat"])
      ?: throw PopopxServerConfigRefused(PopopxServerConfigRejection.ISSUED_AT_MISSING)
    val expiresAt = PopopxServerConfigField.counter(object_["exp"])
      ?: throw PopopxServerConfigRefused(PopopxServerConfigRejection.EXPIRY_MISSING)
    if (expiresAt <= issuedAt) throw PopopxServerConfigRefused(PopopxServerConfigRejection.EXPIRY_NOT_AFTER_ISSUE)
    if (expiresAt - issuedAt > PopopxServerConfigLimits.MAXIMUM_VALIDITY_SECONDS) {
      throw PopopxServerConfigRefused(PopopxServerConfigRejection.VALIDITY_SPAN_TOO_LONG)
    }
    // `exp <= now` counts as expired rather than expiring exactly at the boundary: a frame is dead the second
    // it says it is.
    if (expiresAt <= now) throw PopopxServerConfigRefused(PopopxServerConfigRejection.EXPIRED)
    return Triple(seq, issuedAt, expiresAt)
  }

  /** One `[key, host, onion?]` roster. The three server rosters share this grammar and differ in ceiling. */
  private fun serverRoster(
    value: JsonElement?,
    ceiling: Int,
    invalid: PopopxServerConfigRejection,
    tooLarge: PopopxServerConfigRejection,
  ): List<PopopxServerEntry> =
    PopopxServerConfigField.rows(value, ceiling, invalid, tooLarge).map { row ->
      // A wrong-typed field inside an otherwise legal row is the entry's own shape error, not a roster
      // error: the list is fine and one value in it is not.
      val values = PopopxServerConfigField.strings(row)
        ?: throw PopopxServerConfigRefused(PopopxServerConfigRejection.ENTRY_SHAPE_INVALID)
      PopopxServerConfigHost.entry(values)
    }

  private fun relayRoster(value: JsonElement?): List<PopopxRelayEntry> =
    PopopxServerConfigField.rows(
      value,
      PopopxServerConfigLimits.MAXIMUM_RELAY_ENTRIES,
      PopopxServerConfigRejection.RELAY_ROSTER_INVALID,
      PopopxServerConfigRejection.RELAY_ROSTER_TOO_LARGE,
    ).map { row ->
      // `[host, key]` — the reverse of a server entry. Same shapes, opposite order, which is why this is
      // spelled out instead of sharing the server parser.
      val values = PopopxServerConfigField.strings(row)
      if (values == null || values.size != 2) {
        throw PopopxServerConfigRefused(PopopxServerConfigRejection.RELAY_ENTRY_SHAPE_INVALID)
      }
      PopopxServerConfigHost.rejection(values[0])?.let { throw PopopxServerConfigRefused(it) }
      if (PopopxServerConfigHost.relayKey(values[1]) == null) {
        throw PopopxServerConfigRefused(PopopxServerConfigRejection.RELAY_KEY_INVALID)
      }
      PopopxRelayEntry(host = values[0], key = values[1])
    }

  private fun iceRoster(value: JsonElement?): List<PopopxIceEntry> =
    PopopxServerConfigField.rows(
      value,
      PopopxServerConfigLimits.MAXIMUM_ICE_ENTRIES,
      PopopxServerConfigRejection.ICE_ROSTER_INVALID,
      PopopxServerConfigRejection.ICE_ROSTER_TOO_LARGE,
    ).map { iceEntry(it) }

  private fun iceEntry(value: JsonElement?): PopopxIceEntry {
    val object_ = value as? JsonObject
      ?: throw PopopxServerConfigRefused(PopopxServerConfigRejection.ICE_ENTRY_SHAPE_INVALID)
    val scheme = PopopxServerConfigField.text(object_["t"])
    if (scheme == null || !PopopxServerConfigLimits.ICE_SCHEMES.contains(scheme)) {
      throw PopopxServerConfigRefused(PopopxServerConfigRejection.ICE_SCHEME_UNKNOWN)
    }
    val host = PopopxServerConfigField.text(object_["h"])
      ?: throw PopopxServerConfigRefused(PopopxServerConfigRejection.ICE_ENTRY_SHAPE_INVALID)
    // Shape only, deliberately: the generator applies no domain rule to `ice`, so requiring a branded suffix
    // here would refuse every real frame over a host this build never dials.
    PopopxServerConfigHost.grammarRejection(host)?.let { throw PopopxServerConfigRefused(it) }
    // Port is mandatory rather than defaulted: a turn entry whose port was guessed is the shape that lets a
    // call path give up and fall back to the hardcoded relay.
    val port = PopopxServerConfigField.integer(object_["p"])
    if (port == null || port < 1 || port > 65535) {
      throw PopopxServerConfigRefused(PopopxServerConfigRejection.ICE_PORT_INVALID)
    }
    val transport = PopopxServerConfigField.text(object_["tr"])
    if (transport != null && transport.isNotEmpty() && !PopopxServerConfigLimits.ICE_TRANSPORTS.contains(transport)) {
      throw PopopxServerConfigRefused(PopopxServerConfigRejection.ICE_TRANSPORT_UNKNOWN)
    }
    val username = PopopxServerConfigField.text(object_["u"]) ?: ""
    val credential = PopopxServerConfigField.text(object_["c"]) ?: ""
    // `x` is read for every scheme, because an expiry is a claim about a clock rather than a property of TURN
    // credentials. Inside the credential branch only, `{"t":"stun","x":0}` would parse as "expires at zero".
    var expiry: Long? = null
    if (object_["x"] != null) {
      val parsed = PopopxServerConfigField.integer(object_["x"])
      if (parsed == null || parsed < 1 || parsed > PopopxServerConfigLimits.MAXIMUM_COUNTER_VALUE) {
        throw PopopxServerConfigRefused(PopopxServerConfigRejection.ICE_EXPIRY_INVALID)
      }
      expiry = parsed
    }
    if (PopopxServerConfigLimits.CREDENTIAL_REQUIRING_SCHEMES.contains(scheme)) {
      if (username.isEmpty() || credential.isEmpty()) {
        throw PopopxServerConfigRefused(PopopxServerConfigRejection.ICE_CREDENTIALS_MISSING)
      }
      if (!isRESTUsername(username)) {
        throw PopopxServerConfigRefused(PopopxServerConfigRejection.ICE_USERNAME_MALFORMED)
      }
      if (!isRESTCredential(credential)) {
        throw PopopxServerConfigRefused(PopopxServerConfigRejection.ICE_CREDENTIAL_MALFORMED)
      }
    } else {
      // A stun entry has nowhere to use a credential, so one on it means the generator and this reader
      // disagree about what `t` means. Refuse rather than pick a side.
      if (username.isNotEmpty() || credential.isNotEmpty()) {
        throw PopopxServerConfigRefused(PopopxServerConfigRejection.ICE_CREDENTIALS_NOT_ALLOWED)
      }
    }
    return PopopxIceEntry(
      scheme = scheme,
      host = host,
      port = port.toInt(),
      transport = if (transport.isNullOrEmpty()) null else transport,
      username = username.ifEmpty { null },
      credential = credential.ifEmpty { null },
      expiresAt = expiry,
    )
  }

  /** `^<1..12 digits>:<[A-Za-z0-9_-]{1,64}>$` — coturn's REST username, expiry first, then the id. */
  private fun isRESTUsername(text: String): Boolean {
    val parts = text.split(":")
    if (parts.size != 2) return false
    val expiry = parts[0]
    if (expiry.length < 1 || expiry.length > 12 || !PopopxServerConfigField.isDigit(expiry)) return false
    val id = parts[1]
    return id.length in 1..64 && id.all(PopopxServerConfigField::isBase64UrlChar)
  }

  /**
   * Standard base64 of exactly 20 raw bytes, which is HMAC-SHA1's output and what coturn recomputes. Padding
   * is required here, unlike everywhere else in this format: this value is base64 as coturn spells it.
   */
  private fun isRESTCredential(text: String): Boolean {
    if (text.isEmpty() || !text.all(PopopxServerConfigField::isStandardBase64Char)) return false
    val raw = try {
      java.util.Base64.getDecoder().decode(text)
    } catch (e: IllegalArgumentException) {
      return false
    }
    return raw.size == PopopxServerConfigLimits.REST_CREDENTIAL_BYTES
  }

  private fun policyBlock(object_: JsonObject): PopopxServerConfigPolicy {
    val block = object_["pol"] as? JsonObject
      ?: throw PopopxServerConfigRefused(PopopxServerConfigRejection.POLICY_MISSING)
    val ack = PopopxServerConfigField.flag(block["ack"])
      ?: throw PopopxServerConfigRefused(PopopxServerConfigRejection.POLICY_ACK_INVALID)
    val minSeq = PopopxServerConfigField.counter(block["ms"])
      ?: throw PopopxServerConfigRefused(PopopxServerConfigRejection.POLICY_MIN_SEQ_INVALID)
    // `install_window` is the long spelling the generator also accepts on input, so refusing it here would
    // reject a frame the reference implementation decodes.
    val installWindow = PopopxServerConfigField.counter(block["iw"] ?: block["install_window"])
      ?: throw PopopxServerConfigRefused(PopopxServerConfigRejection.POLICY_INSTALL_WINDOW_INVALID)
    val rollout = PopopxServerConfigField.counter(block["ro"])
    if (rollout == null || rollout > PopopxServerConfigLimits.MAX_ROLLOUT_PERCENT) {
      throw PopopxServerConfigRefused(PopopxServerConfigRejection.POLICY_ROLLOUT_INVALID)
    }
    val ttl = PopopxServerConfigField.counter(block["ttl"])
      ?: throw PopopxServerConfigRefused(PopopxServerConfigRejection.POLICY_TTL_INVALID)
    // Only `ro` gets a client-side bound, because only `ro` is checked by the generator while decoding.
    return PopopxServerConfigPolicy(
      ack = ack,
      minSeq = minSeq,
      installWindowSeconds = installWindow,
      rolloutPercent = rollout,
      ttlSeconds = ttl,
    )
  }
}
