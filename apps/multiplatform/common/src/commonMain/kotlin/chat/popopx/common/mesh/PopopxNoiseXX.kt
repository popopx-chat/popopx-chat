package chat.popopx.common.mesh

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.bouncycastle.crypto.InvalidCipherTextException
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.ParametersWithIV
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters

/**
 * Noise_XX_25519_ChaChaPoly_SHA256, ported from
 * apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Crypto/PopopxNoiseXX.swift.
 *
 * iOS builds this on CryptoKit because a bundled libsodium or OpenSSL would collide with symbols
 * already inside libpopopx.a. Android has no such constraint, and BouncyCastle is already on the
 * classpath for the commerce layer, so the three primitives here come from it: X25519 agreement,
 * ChaCha20-Poly1305 and HMAC-SHA256. The construction is unchanged, and the cross-platform byte
 * vectors are what prove that.
 *
 * Reference: the Noise Protocol Framework, http://noiseprotocol.org/noise.html
 */

/** Every failure a handshake or a session reports, with the same payloads iOS carries. */
sealed class PopopxNoiseError(override val message: String) : Exception(message) {
  /** A protocol name other than the one this build implements was asked for. Checked before any
   * state is created: a handshake over a mismatched name would derive keys that silently disagree
   * with the peer's. */
  object ProtocolNameMismatch : PopopxNoiseError("noise protocol name mismatch")

  class MessageTooShort(val bytes: Int, val required: Int) :
    PopopxNoiseError("noise message of $bytes bytes is shorter than the $required required")

  /** The message being produced or read is not the one this role owes at this step, including a
   * message asked for after the three-message pattern has run out. Carries the role that does own
   * that step. */
  class HandshakeOutOfOrder(val role: PopopxNoiseXXHandshake.Role) :
    PopopxNoiseError("noise handshake out of order at the step owned by $role")

  /** A key the peer sent cannot be used: wrong length, rejected, or a key agreement that collapsed
   * to the all-zero secret. */
  object PeerKeyUnusable : PopopxNoiseError("noise peer key unusable")

  /** Our own seed cannot be turned into a key. Reachable because
   * `PopopxMeshIdentity.of(privateSeed, publicKey)` accepts an unvalidated seed from storage. */
  object LocalKeyUnusable : PopopxNoiseError("noise local key unusable")

  /** The frame is not authentic: a tampered byte, a wrong key, or a nonce prefix that does not match
   * the counter it claims. */
  object DecryptionFailed : PopopxNoiseError("noise decryption failed")

  class Replayed(val counter: Long) : PopopxNoiseError("noise counter $counter already read")

  /** A peer counter older than anything this session still remembers. Accepting it would need memory
   * the window deliberately does not spend. */
  class CounterOutsideWindow(val counter: Long, val windowStart: Long) :
    PopopxNoiseError("noise counter $counter is older than window start $windowStart")

  /** This side has used every nonce its key may seal. Re-handshaking is the only fix, and that is
   * the engine's decision, so the session refuses rather than rekeying on its own. */
  object LocalNonceExhausted : PopopxNoiseError("noise send counter exhausted")

  /** The peer sent a counter past the ceiling it should have stopped under. */
  object PeerNonceExhausted : PopopxNoiseError("noise peer counter past the ceiling")

  /** A symmetric key of the wrong length reached a cipher state. */
  class KeyLengthInvalid(val bytes: Int) : PopopxNoiseError("noise key of $bytes bytes rejected")

  /** Transport keys were asked for before the handshake had three messages worth of state. */
  object HandshakeNotComplete : PopopxNoiseError("noise handshake not complete")
}

/** The two cipher keys a finished handshake splits into, in Noise split order: k1 encrypts
 * initiator to responder, k2 the other way. */
class PopopxNoiseTransportKeys private constructor(
  val sendKey: ByteArray,
  val receiveKey: ByteArray,
) {
  companion object {
    /** null unless both halves are cipher keys, as iOS' failable initialiser is. */
    fun of(sendKey: ByteArray, receiveKey: ByteArray): PopopxNoiseTransportKeys? {
      if (sendKey.size != PopopxNoiseCipherState.KEY_BYTE_COUNT) return null
      if (receiveKey.size != PopopxNoiseCipherState.KEY_BYTE_COUNT) return null
      return PopopxNoiseTransportKeys(sendKey.copyOf(), receiveKey.copyOf())
    }
  }
}

/** What a finished handshake gives the caller: who the peer is, the keys to talk to it with, and the
 * handshake hash, which both sides can show each other as a channel-binding short code. */
class PopopxNoiseHandshakeResult private constructor(
  val peerStaticPublicKey: ByteArray,
  val transportKeys: PopopxNoiseTransportKeys,
  val handshakeHash: ByteArray,
) {
  companion object {
    fun of(
      peerStaticPublicKey: ByteArray,
      transportKeys: PopopxNoiseTransportKeys,
      handshakeHash: ByteArray,
    ): PopopxNoiseHandshakeResult? {
      if (peerStaticPublicKey.size != PopopxNoiseXXHandshake.PUBLIC_KEY_SIZE) return null
      if (handshakeHash.size != PopopxNoiseXXHandshake.PUBLIC_KEY_SIZE) return null
      return PopopxNoiseHandshakeResult(peerStaticPublicKey.copyOf(), transportKeys, handshakeHash.copyOf())
    }
  }
}

/**
 * One ChaCha20-Poly1305 key plus the framing around it. Deliberately stateless about counters: the
 * nonce is an argument, so the same value can open a message the caller has already vetted against
 * its replay window, and nothing here can reuse a nonce by accident.
 */
class PopopxNoiseCipherState private constructor(private val key: ByteArray) {
  companion object {
    const val KEY_BYTE_COUNT: Int = 32
    const val NONCE_BYTE_COUNT: Int = 12
    const val TAG_BYTE_COUNT: Int = 16

    /** Bytes a transport frame carries over its plaintext: the 12-byte nonce prefix plus the 16-byte
     * tag. Equal to `PopopxMeshConfig.noiseTransportOverhead`. */
    const val FRAME_OVERHEAD: Int = NONCE_BYTE_COUNT + TAG_BYTE_COUNT

    /** The first counter that is refused, so one key seals 2^32 - 1 messages. Staying under 2^32
     * keeps the counter inside the last four bytes of the prefix, which is the width the mesh's
     * extracted-nonce framing has always carried; past it Noise requires a fresh handshake. */
    const val MESSAGE_LIMIT: Long = (1L shl 32) - 1

    fun of(key: ByteArray): PopopxNoiseCipherState? {
      if (key.size != KEY_BYTE_COUNT) return null
      return PopopxNoiseCipherState(key.copyOf())
    }

    /**
     * 4 zero bytes ++ the counter little-endian - the nonce Noise 12.3 specifies for ChaChaPoly
     * ("32 bits of zeros followed by little-end encoding of n"), which is also what the mesh's
     * extracted-nonce framing puts on the wire, so one relayed frame can be opened on its own, out of
     * order. The frame prefix and the ChaCha20 nonce are the same 12 bytes.
     *
     * The encoding is not a style choice: it is mixed into the handshake transcript, because the `s`
     * token encrypts the peer's static key. A big-endian counter opens its own frames and agrees with
     * the spec on every Diffie-Hellman output, yet reports a different binding hash.
     */
    fun nonceBytes(counter: Long): ByteArray {
      val bytes = ByteArray(NONCE_BYTE_COUNT)
      for (shift in 0 until 8) bytes[4 + shift] = ((counter ushr (8 * shift)) and 0xFF).toByte()
      return bytes
    }

    /** The counter a nonce prefix carries, or null when it does not start with the four zero bytes
     * this format uses. */
    fun counterOf(nonceBytes: ByteArray): Long? {
      if (nonceBytes.size != NONCE_BYTE_COUNT) return null
      for (index in 0 until 4) if (nonceBytes[index].toInt() != 0) return null
      var counter = 0L
      for (shift in 0 until 8) counter = counter or ((nonceBytes[4 + shift].toLong() and 0xFF) shl (8 * shift))
      return counter
    }

    /** Reads the nonce out of a wire frame without touching the ciphertext, so a session can run its
     * replay check before spending an AEAD on the frame. */
    fun counterInFrame(frame: ByteArray): Long {
      if (frame.size < FRAME_OVERHEAD) throw PopopxNoiseError.MessageTooShort(frame.size, FRAME_OVERHEAD)
      return counterOf(frame.copyOfRange(0, NONCE_BYTE_COUNT)) ?: throw PopopxNoiseError.DecryptionFailed
    }

    /** Handshake fields are bare `ciphertext ++ tag` with the handshake hash as associated data: no
     * nonce prefix, because both sides already track the handshake nonce themselves. */
    internal fun handshakeFieldLength(plaintextSize: Int): Int = plaintextSize + TAG_BYTE_COUNT
  }

  /** `frame` is `nonce(12B) ++ ciphertext ++ tag(16B)`. */
  fun encrypt(plaintext: ByteArray, nonce: Long): ByteArray {
    if (nonce >= MESSAGE_LIMIT) throw PopopxNoiseError.LocalNonceExhausted
    val (ciphertext, tag) = seal(plaintext, nonceBytes(counter = nonce), ByteArray(0))
    return nonceBytes(counter = nonce) + ciphertext + tag
  }

  /** The tag separately, because a forwarding node deduplicates on the tag's few bytes rather than
   * re-hashing the frame. */
  fun encryptWithTag(plaintext: ByteArray, nonce: Long): Pair<ByteArray, ByteArray> {
    if (nonce >= MESSAGE_LIMIT) throw PopopxNoiseError.LocalNonceExhausted
    return seal(plaintext, nonceBytes(counter = nonce), ByteArray(0))
  }

  /**
   * Opens a wire frame at a counter the caller has already vetted. The ChaCha20 nonce is rebuilt from
   * that counter rather than taken from the frame, so flipping a byte in the prefix fails the tag
   * check instead of quietly moving the frame to another nonce. Measured on iOS: a tampered prefix
   * fails here, and the four leading zero bytes are the only part of the prefix that
   * [counterInFrame] looks at.
   */
  fun decrypt(frame: ByteArray, nonce: Long): ByteArray {
    if (frame.size < FRAME_OVERHEAD) throw PopopxNoiseError.MessageTooShort(frame.size, FRAME_OVERHEAD)
    if (nonce >= MESSAGE_LIMIT) throw PopopxNoiseError.PeerNonceExhausted
    val body = frame.copyOfRange(NONCE_BYTE_COUNT, frame.size)
    val plaintext = body.copyOfRange(0, body.size - TAG_BYTE_COUNT)
    val tag = body.copyOfRange(body.size - TAG_BYTE_COUNT, body.size)
    return open(plaintext, tag, nonceBytes(counter = nonce), ByteArray(0)) ?: throw PopopxNoiseError.DecryptionFailed
  }

  internal fun encryptHandshakeField(plaintext: ByteArray, nonce: Long, authenticating: ByteArray): ByteArray {
    if (nonce >= MESSAGE_LIMIT) throw PopopxNoiseError.LocalNonceExhausted
    val (ciphertext, tag) = seal(plaintext, nonceBytes(counter = nonce), authenticating)
    return ciphertext + tag
  }

  internal fun decryptHandshakeField(field: ByteArray, nonce: Long, authenticating: ByteArray): ByteArray {
    if (field.size < TAG_BYTE_COUNT) throw PopopxNoiseError.MessageTooShort(field.size, TAG_BYTE_COUNT)
    val ciphertext = field.copyOfRange(0, field.size - TAG_BYTE_COUNT)
    val tag = field.copyOfRange(field.size - TAG_BYTE_COUNT, field.size)
    return open(ciphertext, tag, nonceBytes(counter = nonce), authenticating) ?: throw PopopxNoiseError.DecryptionFailed
  }

  private fun seal(plaintext: ByteArray, nonce: ByteArray, aad: ByteArray): Pair<ByteArray, ByteArray> {
    val engine = ChaCha20Poly1305()
    engine.init(true, ParametersWithIV(KeyParameter(key), nonce))
    if (aad.isNotEmpty()) engine.processAADBytes(aad, 0, aad.size) else engine.processAADBytes(aad, 0, 0)
    val out = ByteArray(plaintext.size + TAG_BYTE_COUNT)
    val written = engine.processBytes(plaintext, 0, plaintext.size, out, 0)
    val total = written + engine.doFinal(out, written)
    return Pair(out.copyOfRange(0, total - TAG_BYTE_COUNT), out.copyOfRange(total - TAG_BYTE_COUNT, total))
  }

  private fun open(ciphertext: ByteArray, tag: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray? {
    val engine = ChaCha20Poly1305()
    engine.init(false, ParametersWithIV(KeyParameter(key), nonce))
    if (aad.isNotEmpty()) engine.processAADBytes(aad, 0, aad.size) else engine.processAADBytes(aad, 0, 0)
    val input = ciphertext + tag
    val out = ByteArray(input.size)
    val written = engine.processBytes(input, 0, input.size, out, 0)
    return try {
      val total = written + engine.doFinal(out, written)
      out.copyOfRange(0, total)
    } catch (failure: InvalidCipherTextException) {
      null
    }
  }
}

/**
 * The Noise SymmetricState object: handshake hash `h`, chaining key `ck`, and the key the message
 * fields are encrypted under. Internal, because it only ever exists inside a handshake.
 */
internal class PopopxNoiseSymmetricState(protocolName: String) {
  var hash: ByteArray = ByteArray(HASH_BYTE_COUNT)
    private set
  private var chainingKey: ByteArray
  private var cipher: PopopxNoiseCipherState?
  private var nonce: Long = 0

  init {
    val name = protocolName.toByteArray(Charsets.UTF_8)
    // Spec: a name of 32 bytes or less is the initial h verbatim, zero-padded.
    // "Noise_XX_25519_ChaChaPoly_SHA256" is exactly 32, so h starts as the ASCII name itself.
    hash = if (name.size <= HASH_BYTE_COUNT) name + ByteArray(HASH_BYTE_COUNT - name.size) else sha256(name)
    chainingKey = hash.copyOf()
    cipher = null
  }

  val hasKey: Boolean get() = cipher != null

  fun mixHash(data: ByteArray) {
    hash = sha256(hash + data)
  }

  /** Every MixKey also restarts the field nonce, which is why message 2's static key and message 2's
   * payload both sit at nonce 0 while message 3's static key sits at nonce 1. */
  fun mixKey(inputKeyMaterial: ByteArray) {
    val outputs = hkdf(chainingKey, inputKeyMaterial, 2)
    chainingKey = outputs[0]
    cipher = PopopxNoiseCipherState.of(outputs[1])
    nonce = 0L
  }

  /** Without a key the field travels in the clear and only feeds h - that is message 1 of XX. */
  fun encryptAndHash(plaintext: ByteArray): ByteArray {
    val state = cipher ?: run {
      mixHash(plaintext)
      return plaintext
    }
    val field = state.encryptHandshakeField(plaintext, nonce, hash)
    nonce += 1
    mixHash(field)
    return field
  }

  fun decryptAndHash(ciphertext: ByteArray): ByteArray {
    val state = cipher ?: run {
      mixHash(ciphertext)
      return ciphertext
    }
    val plaintext = state.decryptHandshakeField(ciphertext, nonce, hash)
    nonce += 1
    mixHash(ciphertext)
    return plaintext
  }

  /** Split into the two transport keys, then wipe what produced them. iOS notes this is an honesty
   * measure rather than a guarantee in a value type; the handshake drops its reference as soon as it
   * has the keys. */
  fun split(): Pair<ByteArray, ByteArray> {
    val outputs = hkdf(chainingKey, ByteArray(0), 2)
    chainingKey = ByteArray(chainingKey.size)
    hash = ByteArray(hash.size)
    cipher = null
    nonce = 0L
    return Pair(outputs[0], outputs[1])
  }

  companion object {
    const val HASH_BYTE_COUNT: Int = 32

    /**
     * HKDF-SHA256 in the shape Noise uses: Extract over the chaining key, then an Expand chain of
     * HMACs over h1 ++ 0x02, h2 ++ 0x03, so one call covers MixKey's two outputs and Split's two.
     *
     * Written out rather than taken from `HKDFBytesGenerator` because the input keying material is
     * empty for Split, and BouncyCastle's handling of a zero-length IKM in that class is not
     * documented well enough to bet a cross-platform hash on.
     */
    fun hkdf(chainingKey: ByteArray, inputKeyMaterial: ByteArray, outputs: Int): List<ByteArray> {
      val tempKey = hmacSha256(chainingKey, inputKeyMaterial)
      val results = ArrayList<ByteArray>(outputs)
      var previous = ByteArray(0)
      for (index in 1..outputs) {
        previous = hmacSha256(tempKey, previous + byteArrayOf(index.toByte()))
        results.add(previous)
      }
      return results
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
      val mac = Mac.getInstance("HmacSHA256")
      mac.init(SecretKeySpec(key, "HmacSHA256"))
      return mac.doFinal(data)
    }
  }
}

/**
 * One XX handshake, in one direction. The instance is spent after [finalize]: starting a second
 * handshake with it would reuse the ephemeral key, which is the one thing that breaks forward
 * secrecy in Noise.
 */
class PopopxNoiseXXHandshake private constructor(
  private val role: Role,
  private val identity: PopopxMeshIdentity,
  private var symmetric: PopopxNoiseSymmetricState,
) {
  enum class Role {
    INITIATOR,
    RESPONDER,
    ;

    /** The word iOS prints for a role in `handshakeOutOfOrder`, kept so a log line reads the same. */
    override fun toString(): String = if (this == INITIATOR) "initiator" else "responder"
  }

  private enum class Token { E, EE, S, ES, SE }

  private var step = 0
  private var localEphemeralSeed: ByteArray? = null
  private var remoteEphemeralPublicKey: ByteArray? = null
  private var remoteStaticPublicKey: ByteArray? = null
  private var finalized: PopopxNoiseHandshakeResult? = null

  /** Test hook: pins the one ephemeral this role writes, so a handshake hash can be locked to a
   * literal instead of re-derived from random keys. Cleared on use, so it cannot leak onward. */
  internal var ephemeralSeedOverride: ByteArray? = null

  /** Index of the message owed next. Even indices are spoken by the initiator, so the index alone says
   * whose turn it is and both peers keep in step without exchanging a counter. */
  val isComplete: Boolean get() = step >= MESSAGE_PATTERNS.size

  /** Message 1 for the initiator, message 2 for the responder.
   *
   * Message 1 is written before any key exists, so a payload passed to the initiator's first call
   * goes out in the clear. The mesh sends empty payloads there.
   */
  fun nextMessage(payload: ByteArray): ByteArray {
    requireTurn(reading = false)
    val buffer = java.io.ByteArrayOutputStream(PUBLIC_KEY_SIZE * 2 + payload.size + TAG * 2)
    for (token in MESSAGE_PATTERNS[step]) buffer.write(write(token))
    buffer.write(symmetric.encryptAndHash(payload))
    step += 1
    return buffer.toByteArray()
  }

  /** The peer's half of the message this role is waiting for. */
  fun consume(message: ByteArray): PopopxNoiseHandshakeMessage {
    requireTurn(reading = true)
    var offset = 0
    for (token in MESSAGE_PATTERNS[step]) offset = read(token, message, offset)
    val payload = symmetric.decryptAndHash(message.copyOfRange(offset, message.size))
    step += 1
    return PopopxNoiseHandshakeMessage(payload, step >= MESSAGE_PATTERNS.size)
  }

  /** Transport keys plus the binding hash. Idempotent, so a caller that stored the result and asks
   * again is handed the same one. */
  fun finalize(): PopopxNoiseHandshakeResult {
    finalized?.let { return it }
    if (!isComplete) throw PopopxNoiseError.HandshakeNotComplete
    val peerStatic = remoteStaticPublicKey ?: throw PopopxNoiseError.PeerKeyUnusable
    // Read before split(): split wipes the state that produced the hash, and the hash is what both
    // sides quote to each other for channel binding.
    val handshakeHash = symmetric.hash
    val (first, second) = symmetric.split()
    val keys = PopopxNoiseTransportKeys.of(
      sendKey = if (role == Role.INITIATOR) first else second,
      receiveKey = if (role == Role.INITIATOR) second else first,
    ) ?: throw PopopxNoiseError.KeyLengthInvalid(first.size)
    val result = PopopxNoiseHandshakeResult.of(peerStatic, keys, handshakeHash)
      ?: throw PopopxNoiseError.KeyLengthInvalid(handshakeHash.size)
    finalized = result
    return result
  }

  // MARK: Turn taking

  private fun requireTurn(reading: Boolean) {
    if (step >= MESSAGE_PATTERNS.size) throw PopopxNoiseError.HandshakeOutOfOrder(role)
    val speaker = speakerOf(step)
    val speaksThisStep = role == speaker
    // Writing when the step is ours, reading when it is not; either way the error names the role that
    // does own the step, which is what a log line needs to say who is out of line.
    if (reading == speaksThisStep) throw PopopxNoiseError.HandshakeOutOfOrder(speaker)
  }

  // MARK: Tokens

  private fun write(token: Token): ByteArray =
    when (token) {
      Token.E -> writeEphemeral()
      Token.S -> {
        val staticPublic = identity.publicKey
        if (staticPublic.size != PUBLIC_KEY_SIZE) throw PopopxNoiseError.LocalKeyUnusable
        symmetric.encryptAndHash(staticPublic)
      }

      else -> {
        symmetric.mixKey(sharedSecret(token))
        ByteArray(0)
      }
    }

  /** The cursor after the token's field. */
  private fun read(token: Token, message: ByteArray, offset: Int): Int {
    var cursor = offset
    when (token) {
      Token.E -> {
        val key = take(PUBLIC_KEY_SIZE, message, cursor)
        cursor += PUBLIC_KEY_SIZE
        validatedPeerPublicKey(key)
        remoteEphemeralPublicKey = key
        symmetric.mixHash(key)
      }

      Token.S -> {
        // In messages 2 and 3 the static key arrives under the handshake cipher, so its field is 16
        // bytes longer than the key; reading 32 would leave the tag at the payload start.
        val size = if (symmetric.hasKey) ENCRYPTED_PUBLIC_KEY_SIZE else PUBLIC_KEY_SIZE
        val field = take(size, message, cursor)
        cursor += size
        val key = symmetric.decryptAndHash(field)
        validatedPeerPublicKey(key)
        remoteStaticPublicKey = key
      }

      else -> symmetric.mixKey(sharedSecret(token))
    }
    return cursor
  }

  /** Generates - or, under the test hook, takes - the ephemeral for this message and mixes its public
   * half into the handshake hash. */
  private fun writeEphemeral(): ByteArray {
    val pinned = ephemeralSeedOverride
    val seed = if (pinned != null) {
      ephemeralSeedOverride = null
      pinned
    } else {
      ByteArray(PUBLIC_KEY_SIZE).also { random.nextBytes(it) }
    }
    val key = privateKeyFrom(seed)
    localEphemeralSeed = seed
    val publicBytes = key.generatePublicKey().encoded
    symmetric.mixHash(publicBytes)
    return publicBytes
  }

  /** The DH each token means, with the operand order flipped by role the way the spec requires. */
  private fun sharedSecret(token: Token): ByteArray {
    val localSeed: ByteArray?
    val peerPublic: ByteArray?
    when (token) {
      Token.EE -> {
        localSeed = localEphemeralSeed
        peerPublic = remoteEphemeralPublicKey
      }

      // Initiator: DH(ephemeral, peer static). Responder: DH(static, peer ephemeral).
      Token.ES -> {
        localSeed = if (role == Role.INITIATOR) localEphemeralSeed else identity.privateSeed
        peerPublic = if (role == Role.INITIATOR) remoteStaticPublicKey else remoteEphemeralPublicKey
      }

      // Initiator: DH(static, peer ephemeral). Responder: DH(ephemeral, peer static).
      Token.SE -> {
        localSeed = if (role == Role.INITIATOR) identity.privateSeed else localEphemeralSeed
        peerPublic = if (role == Role.INITIATOR) remoteEphemeralPublicKey else remoteStaticPublicKey
      }

      else -> {
        localSeed = null
        peerPublic = null
      }
    }
    val seed = localSeed ?: throw PopopxNoiseError.LocalKeyUnusable
    val peer = peerPublic ?: throw PopopxNoiseError.PeerKeyUnusable
    return keyAgreement(seed, peer)
  }

  companion object {
    const val PROTOCOL_NAME: String = "Noise_XX_25519_ChaChaPoly_SHA256"
    const val PUBLIC_KEY_SIZE: Int = 32

    /** The `s` token once a key exists: a 32-byte public key under a 16-byte tag. */
    val ENCRYPTED_PUBLIC_KEY_SIZE: Int = PUBLIC_KEY_SIZE + PopopxNoiseCipherState.TAG_BYTE_COUNT

    private const val TAG = PopopxNoiseCipherState.TAG_BYTE_COUNT

    /** XX exactly as the spec writes it: `-> e`, `<- e, ee, s, es`, `-> s, se`. */
    private val MESSAGE_PATTERNS: List<List<Token>> =
      listOf(
        listOf(Token.E),
        listOf(Token.E, Token.EE, Token.S, Token.ES),
        listOf(Token.S, Token.SE),
      )

    private val random = java.security.SecureRandom()

    /** The door a caller uses when the protocol name came from configuration rather than from
     * [PROTOCOL_NAME]. Throws before any state exists, exactly as iOS' throwing initialiser does. */
    fun create(
      role: Role,
      localIdentity: PopopxMeshIdentity,
      protocolName: String = PROTOCOL_NAME,
      ephemeralSeed: ByteArray? = null,
    ): PopopxNoiseXXHandshake {
      if (protocolName != PROTOCOL_NAME) throw PopopxNoiseError.ProtocolNameMismatch
      val handshake = PopopxNoiseXXHandshake(role, localIdentity, PopopxNoiseSymmetricState(protocolName))
      handshake.ephemeralSeedOverride = ephemeralSeed
      return handshake
    }

    fun initiator(localIdentity: PopopxMeshIdentity): PopopxNoiseXXHandshake =
      PopopxNoiseXXHandshake(Role.INITIATOR, localIdentity, PopopxNoiseSymmetricState(PROTOCOL_NAME))

    fun responder(localIdentity: PopopxMeshIdentity): PopopxNoiseXXHandshake =
      PopopxNoiseXXHandshake(Role.RESPONDER, localIdentity, PopopxNoiseSymmetricState(PROTOCOL_NAME))

    /** The role that speaks the message at `step`. */
    internal fun speakerOf(step: Int): Role = if (step % 2 == 0) Role.INITIATOR else Role.RESPONDER

    private fun privateKeyFrom(seed: ByteArray): X25519PrivateKeyParameters {
      if (seed.size != PUBLIC_KEY_SIZE) throw PopopxNoiseError.LocalKeyUnusable
      return runCatching { X25519PrivateKeyParameters(seed, 0) }.getOrElse { throw PopopxNoiseError.LocalKeyUnusable }
    }

    /**
     * A peer's public key, or the refusal.
     *
     * Two checks, and the second one is the reason this is not just a constructor call: the all-zero
     * encoding is the identity element, and a DH against it says nothing about who is on the other
     * end. CryptoKit refuses that encoding by throwing; BouncyCastle accepts any 32 bytes, so the
     * rule moves here rather than being left to the library.
     */
    internal fun validatedPeerPublicKey(data: ByteArray): X25519PublicKeyParameters {
      if (data.size != PUBLIC_KEY_SIZE) throw PopopxNoiseError.PeerKeyUnusable
      var accumulator = 0
      for (byte in data) accumulator = accumulator or (byte.toInt() and 0xFF)
      if (accumulator == 0) throw PopopxNoiseError.PeerKeyUnusable
      return runCatching { X25519PublicKeyParameters(data, 0) }.getOrElse { throw PopopxNoiseError.PeerKeyUnusable }
    }

    private fun keyAgreement(localSeed: ByteArray, peerPublicKey: ByteArray): ByteArray {
      val local = privateKeyFrom(localSeed)
      val remote = validatedPeerPublicKey(peerPublicKey)
      val secret = ByteArray(PUBLIC_KEY_SIZE)
      // A low-order peer point makes the shared secret independent of our private key, so the peer
      // already knows it. CryptoKit's X25519 throws on the encodings it recognises as degenerate;
      // BouncyCastle returns quietly instead, so the all-zero output check below is the load-bearing
      // one on this platform and is kept even though iOS has both.
      runCatching { local.generateSecret(remote, secret, 0) }.getOrElse { throw PopopxNoiseError.PeerKeyUnusable }
      var accumulator = 0
      for (byte in secret) accumulator = accumulator or (byte.toInt() and 0xFF)
      if (accumulator == 0) throw PopopxNoiseError.PeerKeyUnusable
      return secret
    }

    /** Field reader: a truncated message is `messageTooShort` with the length the parse needed. */
    private fun take(count: Int, message: ByteArray, cursor: Int): ByteArray {
      if (message.size - cursor < count) throw PopopxNoiseError.MessageTooShort(message.size, cursor + count)
      return message.copyOfRange(cursor, cursor + count)
    }
  }
}

/** What [PopopxNoiseXXHandshake.consume] hands back: the decrypted payload and whether the pattern ran out. */
class PopopxNoiseHandshakeMessage(val payload: ByteArray, val complete: Boolean)
