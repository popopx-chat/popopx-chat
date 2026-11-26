package chat.popopx.common.mesh

/**
 * One finished handshake per peer, plus the counters around it. Port of
 * apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Crypto/PopopxNoiseSession.swift.
 *
 * The counter travels inside every frame rather than being tracked in step on both ends: the mesh
 * floods, so two packets from one peer routinely reach the next node out of order. A counter kept in
 * step on both ends would force a fresh handshake the first time that happened. The price here is 12
 * bytes per frame, which is what `PopopxMeshConfig.noiseTransportOverhead` accounts for.
 */

/** Which side of the remembered range a peer counter falls on. */
enum class PopopxNoiseCounterPlacement {
  ACCEPT,
  DUPLICATE,
  TOO_OLD,
}

/**
 * A sliding window over the peer's counters: bit i says whether `highest - i` has been read already,
 * so an out-of-order frame is accepted exactly once and a duplicate is not accepted at all. Bitchat
 * uses 1024 bits for the same job, which is why that is the default here too.
 */
internal class PopopxNoiseReplayWindow(val size: Int) {
  private var bits = ByteArray((size + 7) / 8)

  var highest: Long = 0L
    private set
  var hasReadAny: Boolean = false
    private set

  /** The lowest counter still inside the window. Reported by `counterOutsideWindow` so a log line says
   * how far behind the peer is without leaking anything else about the session. */
  val start: Long
    get() {
      if (!hasReadAny) return 0L
      val span = (size - 1).toLong()
      return if (highest > span) highest - span else 0L
    }

  fun place(counter: Long): PopopxNoiseCounterPlacement {
    if (!hasReadAny) return PopopxNoiseCounterPlacement.ACCEPT
    if (counter > highest) return PopopxNoiseCounterPlacement.ACCEPT
    if (counter == highest) return PopopxNoiseCounterPlacement.DUPLICATE
    // Counters below Long.MAX_VALUE here (the ceiling is 2^32-1), so the subtraction cannot wrap.
    val gap = highest - counter
    if (gap >= size.toLong()) return PopopxNoiseCounterPlacement.TOO_OLD
    return if (isMarked(counter)) PopopxNoiseCounterPlacement.DUPLICATE else PopopxNoiseCounterPlacement.ACCEPT
  }

  /** Records a counter as read. Call it only after the frame opened, so a forged frame cannot retire a
   * counter the real peer has not finished sending. */
  fun mark(counter: Long) {
    if (!hasReadAny) {
      hasReadAny = true
      highest = counter
      bits[0] = (bits[0].toInt() or 1).toByte()
      return
    }
    if (counter <= highest) {
      setMark(counter)
      return
    }
    val gap = counter - highest
    if (gap >= size.toLong()) {
      // Jumped past everything remembered: the window restarts empty.
      bits = ByteArray(bits.size)
    } else {
      shift(gap.toInt())
    }
    highest = counter
    bits[0] = (bits[0].toInt() or 1).toByte()
  }

  private fun isMarked(counter: Long): Boolean {
    val offset = (highest - counter).toInt()
    return bits[offset / 8].toInt() and (1 shl (offset % 8)) != 0
  }

  private fun setMark(counter: Long) {
    val offset = (highest - counter).toInt()
    val index = offset / 8
    bits[index] = (bits[index].toInt() or (1 shl (offset % 8))).toByte()
  }

  /** Moves every mark `delta` counters further from the new highest, i.e. towards higher bit
   * positions. Done over a copy because a mark's destination can be another mark's source. */
  private fun shift(delta: Int) {
    val source = bits.copyOf()
    val byteShift = delta / 8
    val bitShift = delta % 8
    var index = bits.size - 1
    while (index >= 0) {
      var value = 0
      val from = index - byteShift
      if (from >= 0) {
        value = (source[from].toInt() and 0xFF) shl bitShift
        if (bitShift > 0 && from > 0) {
          value = value or ((source[from - 1].toInt() and 0xFF) ushr (8 - bitShift))
        }
      }
      bits[index] = (value and 0xFF).toByte()
      index -= 1
    }
  }
}

/**
 * A peer's established Noise session: the two transport keys, the counter this side is up to, and the
 * window over the peer's.
 *
 * iOS makes this a value type so a task can be handed a copy for one encryption without locking.
 * Kotlin has no equivalent without a deep copy at every call, so this is a class and the engine owns
 * it behind its own serialisation - the same place iOS keeps sessions in its actor-isolated table.
 */
class PopopxNoiseSession private constructor(
  /** The peer's X25519 static key. Nothing may point a session at a different peer afterwards. */
  var peerPublicKey: ByteArray,
  private val send: PopopxNoiseCipherState,
  private val receive: PopopxNoiseCipherState,
  replayWindow: Int,
) {
  private var sendCounter: Long = 0L
  private val window = PopopxNoiseReplayWindow(replayWindow)

  /** The same key as the 64 hex characters the pairing frames and the mapping table use. */
  val peerMeshPublicKeyHex: String get() = peerPublicKey.meshHex()

  /** Messages this side has sealed, which is what an engine watches to decide when to renegotiate. */
  val messagesSent: Long get() = sendCounter

  /** Where the peer's counter stands, which is the counter its next frame must carry: the highest one
   * accepted plus one, null before the first frame. Mirrors [messagesSent], so an engine can compare
   * the two and see who is behind. */
  val peerCounter: Long? get() = if (window.hasReadAny) window.highest + 1 else null

  /** `nonce(12B) ++ ciphertext ++ tag(16B)`, so 28 bytes longer than the plaintext. */
  fun encrypt(plaintext: ByteArray): ByteArray {
    val counter = sendCounter
    if (counter >= PopopxNoiseCipherState.MESSAGE_LIMIT) {
      // Refused, not rekeyed: fresh keys mean a fresh handshake with the peer, and deciding when to
      // spend that round trip belongs to the engine.
      throw PopopxNoiseError.LocalNonceExhausted
    }
    sendCounter = counter + 1
    return send.encrypt(plaintext, counter)
  }

  /** Opens a frame the caller took off the wire. The counter is checked against the window first, so a
   * replay costs a comparison rather than an AEAD. */
  fun decrypt(frame: ByteArray): ByteArray {
    val counter = PopopxNoiseCipherState.counterInFrame(frame)
    if (counter >= PopopxNoiseCipherState.MESSAGE_LIMIT) throw PopopxNoiseError.PeerNonceExhausted
    when (window.place(counter)) {
      PopopxNoiseCounterPlacement.ACCEPT -> Unit
      PopopxNoiseCounterPlacement.DUPLICATE -> throw PopopxNoiseError.Replayed(counter)
      PopopxNoiseCounterPlacement.TOO_OLD -> throw PopopxNoiseError.CounterOutsideWindow(counter, window.start)
    }
    val plaintext = receive.decrypt(frame, counter)
    // Marked only now: a frame that failed to open was not from the peer, and letting it retire a
    // counter would let an attacker lock out the real message that follows.
    window.mark(counter)
    return plaintext
  }

  companion object {
    /** Bitchat's REPLAY_WINDOW_SIZE. Mesh reordering needs more slack than a point-to-point link. */
    const val DEFAULT_REPLAY_WINDOW: Int = 1024

    /** Upper bound on the window a caller may ask for. It is allocated per peer, so an unbounded size
     * would turn a configured number into a memory problem. */
    const val MAX_REPLAY_WINDOW: Int = 16_384

    /** null when the key material is not two 32-byte values or the window is not a usable size. */
    fun of(
      peerPublicKey: ByteArray,
      keys: PopopxNoiseTransportKeys,
      replayWindow: Int = DEFAULT_REPLAY_WINDOW,
    ): PopopxNoiseSession? {
      if (peerPublicKey.size != PopopxNoiseXXHandshake.PUBLIC_KEY_SIZE) return null
      if (replayWindow <= 0 || replayWindow > MAX_REPLAY_WINDOW) return null
      val send = PopopxNoiseCipherState.of(keys.sendKey) ?: return null
      val receive = PopopxNoiseCipherState.of(keys.receiveKey) ?: return null
      return PopopxNoiseSession(peerPublicKey.copyOf(), send, receive, replayWindow)
    }
  }
}
