package chat.popopx.common.cfgsec

// Ported from apps/ios/Shared/Features/ServerConfigSync/PopopxServerClusterConfig.swift (limits, rejections,
// payload, host rules, trust anchor).
//
// Every number and every string in this file is quoted from the signing side, which is the authority: a limit
// the client tightened would silently drop honest frames, and one it loosened would accept a body no honest
// tool ever produced. The generator is `scripts/ios/server-config-mint.swift`, and the frames this port is
// tested against are minted by it rather than hand-written here.
//
// The three properties iOS states at the top of its file are kept whole: verify before inflating, verify over
// the received bytes and never a re-serialization, and keep the suppression criterion shape-only so it cannot
// fail open.

/** Size and shape ceilings. Each one is a rejection, not a warning. */
object PopopxServerConfigLimits {
  /** Longest token segment after the prefix, counted in unicode scalars. */
  const val MAXIMUM_SEGMENT_CHARACTERS: Int = 1_024

  /** `POPOPXCFG1-`, the token tag. Eleven characters, always present, never signed. */
  const val TOKEN_PREFIX: String = "POPOPXCFG1-"

  /** base64url of a 64-byte Ed25519 signature, unpadded, is exactly this many characters. */
  const val SIGNATURE_SEGMENT_CHARACTERS: Int = 86

  /** Hard ceiling on inflated output. Beyond this, a signed body is a bomb and is refused whole. */
  const val MAXIMUM_INFLATED_BYTES: Int = 65_536

  const val MAXIMUM_SMP_SERVER_ENTRIES: Int = 10
  const val MAXIMUM_XFTP_SERVER_ENTRIES: Int = 4
  const val MAXIMUM_NOTIFICATION_SERVER_ENTRIES: Int = 4
  const val MAXIMUM_RELAY_ENTRIES: Int = 2
  const val MAXIMUM_ICE_ENTRIES: Int = 3

  /** `^[a-z0-9.-]+$` names, at most this long, with at least two labels. */
  const val MAXIMUM_HOST_CHARACTERS: Int = 253

  /** A server fingerprint is the base64url of 32 bytes: 43 characters. */
  const val SERVER_KEY_CHARACTERS: Int = 43

  const val SIGNING_KEY_CHARACTERS: Int = 64
  const val SIGNATURE_BYTE_COUNT: Int = 64

  const val KEY_ID_PREFIX: String = "k-"
  const val KEY_ID_HASH_CHARACTERS: Int = 10
  const val KEY_ID_CHARACTERS: Int = 12

  /** `bh` in the receipt: the first sixteen hex characters of the signed body's SHA-256. */
  const val BODY_HASH_CHARACTERS: Int = 16

  const val FORMAT_VERSION: Long = 1
  const val ENCODING_TAG: String = "z9"

  /** Longest validity a body may claim: 30 days. */
  const val MAXIMUM_VALIDITY_SECONDS: Long = 30L * 24 * 60 * 60

  /** Counters are bounded at 2^53 so they survive a round trip through any consumer's double. */
  const val MAXIMUM_COUNTER_VALUE: Long = 9_007_199_254_740_992L

  const val MAX_ROLLOUT_PERCENT: Long = 100

  /**
   * Hosts this device will dial on the operator's instruction. The set is the factory preset's own
   * domains: `serverDomains = ["popopx.im"]` plus the site the app links to. Keep it equal to
   * `PopopxServerConfigLimits.admittedHostnameSuffixes` on iOS.
   */
  val ADMITTED_HOSTNAME_SUFFIXES: List<String> = listOf(".popopx.chat", ".popopx.im")
  const val ONION_SUFFIX: String = ".onion"

  val ICE_SCHEMES: List<String> = listOf("stun", "stuns", "turn", "turns")
  val CREDENTIAL_REQUIRING_SCHEMES: List<String> = listOf("turn", "turns")
  val ICE_TRANSPORTS: List<String> = listOf("udp", "tcp")

  /** A coturn REST credential is HMAC-SHA1, so exactly 20 raw bytes under standard base64. */
  const val REST_CREDENTIAL_BYTES: Int = 20

  /** v3 onion addresses: 56 base32 characters and the TLD. */
  const val ONION_NAME_CHARACTERS: Int = 56
}

/**
 * Why a frame was refused. Logged, never shown: an unverifiable configuration is not news to the user, and
 * naming the cause on screen would tell an attacker which check caught them. The raw values are the log
 * strings, kept identical to iOS so one operator-side grep works on both platforms.
 */
enum class PopopxServerConfigRejection(val rawValue: String) {
  FRAME_PREFIX_MISSING("line does not start with the configuration prefix"),
  SEGMENT_TOO_LONG("segment exceeds the client cap"),
  TOKEN_MALFORMED("token is not POPOPXCFG1-<base64url>.<base64url>"),
  SIGNATURE_SEGMENT_MALFORMED("signature segment is not 86 base64url characters"),
  SIGNATURE_MALFORMED("signature segment does not decode"),
  SIGNATURE_WRONG_LENGTH("signature is not 64 bytes"),
  SIGNATURE_NOT_VERIFYING("signature did not verify"),
  DEFLATE_HEADER_INVALID("not a zlib stream"),
  DEFLATE_FAILED("deflate stream invalid"),
  DEFLATE_TRUNCATED("deflate stream ended early"),
  DEFLATE_TRAILING_BYTES("bytes remain after the deflate stream"),
  DEFLATE_OVER_CAP("inflated body exceeds the memory ceiling"),
  CHECKSUM_MISMATCH("adler-32 trailer does not match the inflated body"),
  BODY_NOT_JSON("inflated body is not JSON"),
  BODY_NOT_OBJECT("body is not an object"),
  FORMAT_VERSION_UNSUPPORTED("unsupported payload format version"),
  ENCODING_UNKNOWN("unknown payload encoding"),
  KEY_ID_MALFORMED("key id is not k- plus ten hex characters"),
  KEY_ID_MISMATCH("key id does not match the verifying key"),
  SEQUENCE_MISSING("seq missing or out of range"),
  ISSUED_AT_MISSING("iat missing or out of range"),
  EXPIRY_MISSING("exp missing or out of range"),
  EXPIRY_NOT_AFTER_ISSUE("exp is not after iat"),
  VALIDITY_SPAN_TOO_LONG("validity span exceeds the ceiling"),
  EXPIRED("expiry at or before now"),
  SMP_ROSTER_INVALID("smp roster is not a valid array"),
  SMP_ROSTER_TOO_LARGE("smp roster exceeds its ceiling"),
  XFTP_ROSTER_INVALID("xftp roster is not a valid array"),
  XFTP_ROSTER_TOO_LARGE("xftp roster exceeds its ceiling"),
  NTF_ROSTER_INVALID("ntf roster is not a valid array"),
  NTF_ROSTER_TOO_LARGE("ntf roster exceeds its ceiling"),
  RELAY_ROSTER_INVALID("relay roster is not a valid array"),
  RELAY_ROSTER_TOO_LARGE("relay roster exceeds its ceiling"),
  ICE_ROSTER_INVALID("ice roster is not a valid array"),
  ICE_ROSTER_TOO_LARGE("ice roster exceeds its ceiling"),
  ENTRY_SHAPE_INVALID("server entry is not an array of two or three strings"),
  ENTRY_KEY_INVALID("server fingerprint is not 43 base64url characters"),
  ENTRY_HOST_INVALID("host is not a plain lowercase name"),
  ENTRY_HOST_UNADMITTED("host is outside the admitted domains"),
  ENTRY_ONION_INVALID("onion alternate is not a v3 address"),
  RELAY_ENTRY_SHAPE_INVALID("relay entry is not an array of two strings"),
  RELAY_KEY_INVALID("relay key is not 43 base64url characters"),
  ICE_ENTRY_SHAPE_INVALID("ice entry is not an object"),
  ICE_SCHEME_UNKNOWN("ice scheme is not stun, stuns, turn or turns"),
  ICE_PORT_INVALID("ice port missing or out of range"),
  ICE_TRANSPORT_UNKNOWN("ice transport is not udp or tcp"),
  ICE_CREDENTIALS_MISSING("turn entry carries no REST credentials"),
  ICE_CREDENTIALS_NOT_ALLOWED("stun entry carries credentials"),
  ICE_USERNAME_MALFORMED("ice username is not the REST expiry:id form"),
  ICE_CREDENTIAL_MALFORMED("ice credential is not base64 of 20 bytes"),
  ICE_EXPIRY_INVALID("ice expiry is not a positive integer within the counter ceiling"),
  POLICY_MISSING("policy block is not an object"),
  POLICY_ACK_INVALID("policy ack is neither a boolean nor on/off"),
  POLICY_MIN_SEQ_INVALID("policy min_seq is not a positive integer"),
  POLICY_INSTALL_WINDOW_INVALID("policy install window is not a positive integer"),
  POLICY_ROLLOUT_INVALID("policy rollout is outside one to one hundred"),
  POLICY_TTL_INVALID("policy ttl is not a positive integer"),
}

/** Raised by every refusal path so the first precise reason propagates out of a long linear validation. */
class PopopxServerConfigRefused(val reason: PopopxServerConfigRejection) : Exception(reason.rawValue)

/** One SMP, XFTP or notification server: `[key, host, onion?]` on the wire, in that order. */
class PopopxServerEntry(
  val key: String,
  val host: String,
  val onion: String?,
) {
  /** Hosts to try for this one server, in the order the core should walk them. */
  val hostnames: List<String> get() = if (onion == null) listOf(host) else listOf(host, onion)

  override fun equals(other: Any?): Boolean =
    other is PopopxServerEntry && other.key == key && other.host == host && other.onion == onion

  override fun hashCode(): Int = listOf(key, host, onion).hashCode()
}

/** A chat relay. The client assembles `https://{host}/r#{key}`; the frame carries the parts, never the URL. */
class PopopxRelayEntry(val host: String, val key: String)

/**
 * A structured ICE server, deliberately not a URL: a coturn REST username contains `:` and its credential is
 * base64 with `+/=`, so an inline `turn:user:cred@host` form mis-parses — and a call path that fails to parse
 * its ICE list falls back to a hardcoded server, which is failing open on a paid-for credential.
 */
class PopopxIceEntry(
  val scheme: String,
  val host: String,
  val port: Int,
  val transport: String?,
  val username: String?,
  val credential: String?,
  val expiresAt: Long?,
)

/** The policy block. `ack` is the only field this device acts on directly. */
class PopopxServerConfigPolicy(
  val ack: Boolean,
  val minSeq: Long,
  val installWindowSeconds: Long,
  val rolloutPercent: Long,
  val ttlSeconds: Long,
)

/** The signed configuration, version 1. Unknown top-level fields are ignored, not refused. */
class PopopxServerClusterPayload(
  val seq: Long,
  val issuedAt: Long,
  val expiresAt: Long,
  val keyId: String,
  val smpServers: List<PopopxServerEntry>,
  val xftpServers: List<PopopxServerEntry>,
  val notificationServers: List<PopopxServerEntry>,
  val relays: List<PopopxRelayEntry>,
  val iceServers: List<PopopxIceEntry>,
  val policy: PopopxServerConfigPolicy,
)

/** The two hostname rules a cluster has to satisfy: a plain name, and a host this organization operates. */
object PopopxServerConfigHost {
  private const val HOSTNAME_ALLOWED = "abcdefghijklmnopqrstuvwxyz0123456789.-"
  private const val BASE64URL_CHARS =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  private const val BASE32_CHARS = "abcdefghijklmnopqrstuvwxyz234567"

  fun isAdmitted(host: String): Boolean {
    if (host.endsWith(PopopxServerConfigLimits.ONION_SUFFIX) &&
      scalarCount(host) > PopopxServerConfigLimits.ONION_SUFFIX.length
    ) return true
    return PopopxServerConfigLimits.ADMITTED_HOSTNAME_SUFFIXES.any { host.endsWith(it) }
  }

  /** The shape rules alone, without the domain rule. */
  fun grammarRejection(host: String?): PopopxServerConfigRejection? {
    if (host == null) return PopopxServerConfigRejection.ENTRY_HOST_INVALID
    if (host.isEmpty() || scalarCount(host) > PopopxServerConfigLimits.MAXIMUM_HOST_CHARACTERS) {
      return PopopxServerConfigRejection.ENTRY_HOST_INVALID
    }
    if (!host.all { HOSTNAME_ALLOWED.contains(it) }) return PopopxServerConfigRejection.ENTRY_HOST_INVALID
    if (host.startsWith(".") || host.endsWith(".") || host.startsWith("-") || host.endsWith("-")) {
      return PopopxServerConfigRejection.ENTRY_HOST_INVALID
    }
    val labels = host.split(".")
    if (labels.size < 2 || labels.any { it.isEmpty() }) return PopopxServerConfigRejection.ENTRY_HOST_INVALID
    return null
  }

  /** The reason this host is unusable, or null when every rule holds. */
  fun rejection(host: String): PopopxServerConfigRejection? {
    grammarRejection(host)?.let { return it }
    return if (isAdmitted(host)) null else PopopxServerConfigRejection.ENTRY_HOST_UNADMITTED
  }

  /** Validates one `[key, host, onion?]` triple, normalizing a padded fingerprint away. */
  fun entry(values: List<String>): PopopxServerEntry {
    if (values.size != 2 && values.size != 3) throw PopopxServerConfigRefused(PopopxServerConfigRejection.ENTRY_SHAPE_INVALID)
    val key = fingerprint(values[0])
      ?: throw PopopxServerConfigRefused(PopopxServerConfigRejection.ENTRY_KEY_INVALID)
    rejection(values[1])?.let { throw PopopxServerConfigRefused(it) }
    if (values.size == 3 && !isOnion(values[2])) {
      throw PopopxServerConfigRefused(PopopxServerConfigRejection.ENTRY_ONION_INVALID)
    }
    return PopopxServerEntry(key = key, host = values[1], onion = values.getOrNull(2))
  }

  /** A relay key, which unlike a server fingerprint is never carried padded. */
  fun relayKey(text: String): String? =
    if (scalarCount(text) != PopopxServerConfigLimits.SERVER_KEY_CHARACTERS) null else fingerprint(text)

  fun fingerprint(text: String): String? {
    val unpadded = if (text.endsWith("=")) text.dropLast(1) else text
    if (scalarCount(unpadded) != PopopxServerConfigLimits.SERVER_KEY_CHARACTERS) return null
    if (!unpadded.all { BASE64URL_CHARS.contains(it) }) return null
    return unpadded
  }

  fun isOnion(host: String): Boolean {
    if (!host.endsWith(PopopxServerConfigLimits.ONION_SUFFIX)) return false
    val name = host.dropLast(PopopxServerConfigLimits.ONION_SUFFIX.length)
    return scalarCount(name) == PopopxServerConfigLimits.ONION_NAME_CHARACTERS &&
      name.all { BASE32_CHARS.contains(it) }
  }

  /** Swift counts `unicodeScalars`; a Java/Kotlin `length` counts UTF-16 units, so the two differ off BMP. */
  internal fun scalarCount(text: String): Int = text.codePointCount(0, text.length)
}
