package chat.popopx.common.mesh

/**
 * The mesh packet and its byte codec — a line-for-line port of
 * apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Protocol/PopopxMeshProtocol.swift, so that an iOS
 * node and an Android node read each other's frames.
 *
 * Header, 14 bytes, all big-endian:
 *   version(1)=1  type(1)  ttl(1)  timestamp(8)  flags(1)  payloadLength(2)
 * then senderID(8)  [recipientID(8)]  payload  [signature(64)], then the traffic-analysis padding.
 * There is no magic: the brief's `0x504D` and its 64-byte header do not exist in iOS, and the 64 is
 * the *signature field* width (ruling: iOS source wins, deviation recorded in the commit body).
 */

/** The `type` byte. Values are Bitchat's, minus the Nostr-only ones and plus this package's group space. */
enum class PopopxMeshMessageType(val wireValue: Int) {
  ANNOUNCE(0x01),
  MESSAGE(0x02),
  LEAVE(0x03),
  NOISE_HANDSHAKE(0x10),
  NOISE_ENCRYPTED(0x11),
  FRAGMENT(0x20),
  PING(0x26),
  PONG(0x27),
  PAIRING_REQUEST(0x30),
  PAIRING_ACK(0x31),
  DELIVERY_ACK(0x32),

  /**
   * Creator-signed group state, directed, payload is a Noise frame. Bitchat carries the same thing
   * as NoisePayloadType 0x06/0x07; a mesh type of its own is what lets a node that is not the
   * recipient still relay it.
   */
  GROUP_STATE(0x40),

  /** Group traffic: flooded, outer layer deliberately unsigned. Bitchat's MessageType 0x25. */
  GROUP_MESSAGE(0x41),
  ;

  companion object {
    /** Unknown values decode rather than fail, exactly as iOS does: `decodedType` is nil, the packet is not. */
    fun of(value: Int): PopopxMeshMessageType? = entries.firstOrNull { it.wireValue == value }
  }
}

/** The 8-byte sender/recipient field, derived from the mesh public key rather than chosen by a peer. */
class PopopxMeshPeerID private constructor(val bytes: ByteArray) {
  /** Big-endian, so two nodes that disagree about byte order disagree about every peer. */
  val u64: Long
    get() = bytes.u64()

  val hex: String get() = bytes.meshHex()

  override fun equals(other: Any?): Boolean = other is PopopxMeshPeerID && bytes.contentEquals(other.bytes)

  override fun hashCode(): Int = bytes.contentHashCode()

  override fun toString(): String = hex

  companion object {
    const val BYTE_COUNT: Int = 8

    /** First 8 bytes of SHA256(pubkey) — the same truncation Bitchat shows as a 16-hex peer id. */
    fun fromPublicKey(publicKey: ByteArray): PopopxMeshPeerID =
      PopopxMeshPeerID(sha256(publicKey).copyOfRange(0, BYTE_COUNT))

    /** nil for any other width, as iOS' failable initialiser is. */
    fun of(data: ByteArray): PopopxMeshPeerID? =
      if (data.size == BYTE_COUNT) PopopxMeshPeerID(data.copyOf()) else null
  }
}

class PopopxMeshPacket(
  val version: Int,
  val type: Int,
  val ttl: Int,
  /** Milliseconds since epoch, the unit the wire field carries. */
  val timestamp: Long,
  val senderID: ByteArray,
  val recipientID: ByteArray?,
  val payload: ByteArray,
  val signature: ByteArray? = null,
) {
  /** A broadcast has no recipient field, or the all-ones recipient a relay uses to re-flood. */
  val isBroadcast: Boolean
    get() {
      val recipient = recipientID ?: return true
      if (recipient.size != PopopxMeshPeerID.BYTE_COUNT) return false
      return recipient.all { it == 0xFF.toByte() }
    }

  /**
   * Content-derived flood-dedup id: free to recompute on a relayed packet, and it changes if any
   * relayed field changes. Note what it does *not* cover — ttl, the recipient field and the
   * signature — so a directed frame and a broadcast frame with the same type, sender, timestamp and
   * payload share one id and dedup against each other. Measured on iOS (packet.unsigned,
   * packet.directed and packet.broadcastOnes all hash to 457653dc…); kept because changing it here
   * would fork the flood.
   */
  val packetID: ByteArray
    get() = sha256(
      byteArrayOf(type.toByte()) + senderID + timestamp.bigEndianBytes() + payload
    ).copyOfRange(0, 16)

  val senderPeerID: PopopxMeshPeerID? get() = PopopxMeshPeerID.of(senderID)

  val recipientPeerID: PopopxMeshPeerID? get() = recipientID?.let { PopopxMeshPeerID.of(it) }

  val isSigned: Boolean get() = signature != null

  val decodedType: PopopxMeshMessageType? get() = PopopxMeshMessageType.of(type)

  fun encoded(padded: Boolean = true): ByteArray? {
    if (version != 1) return null
    if (payload.size > 0xFFFF) return null
    if (senderID.size != PopopxMeshPeerID.BYTE_COUNT) return null
    if (recipientID != null && recipientID.size != PopopxMeshPeerID.BYTE_COUNT) return null
    if (signature != null && signature.size != SIGNATURE_SIZE) return null

    var flags = 0
    if (recipientID != null) flags = flags or FLAG_HAS_RECIPIENT
    if (signature != null) flags = flags or FLAG_HAS_SIGNATURE

    val data = java.io.ByteArrayOutputStream(HEADER_SIZE + payload.size + SIGNATURE_SIZE)
    data.write(version)
    data.write(type)
    data.write(ttl)
    data.write(timestamp.bigEndianBytes())
    data.write(flags)
    data.write((payload.size shr 8) and 0xFF)
    data.write(payload.size and 0xFF)
    data.write(senderID)
    recipientID?.let { data.write(it) }
    data.write(payload)
    signature?.let { data.write(it) }

    val unpadded = data.toByteArray()
    return if (padded) pad(unpadded, optimalBlockSize(unpadded.size)) else unpadded
  }

  override fun equals(other: Any?): Boolean =
    other is PopopxMeshPacket &&
      version == other.version &&
      type == other.type &&
      ttl == other.ttl &&
      timestamp == other.timestamp &&
      senderID.contentEquals(other.senderID) &&
      ((recipientID == null && other.recipientID == null) ||
        (recipientID != null && other.recipientID != null && recipientID.contentEquals(other.recipientID))) &&
      payload.contentEquals(other.payload) &&
      ((signature == null && other.signature == null) ||
        (signature != null && other.signature != null && signature.contentEquals(other.signature)))

  override fun hashCode(): Int {
    var result = version
    result = 31 * result + type
    result = 31 * result + ttl
    result = 31 * result + timestamp.hashCode()
    result = 31 * result + senderID.contentHashCode()
    result = 31 * result + (recipientID?.contentHashCode() ?: 0)
    result = 31 * result + payload.contentHashCode()
    result = 31 * result + (signature?.contentHashCode() ?: 0)
    return result
  }

  companion object {
    const val HEADER_SIZE: Int = 14
    const val SIGNATURE_SIZE: Int = 64
    private const val FLAG_HAS_RECIPIENT = 0x01
    private const val FLAG_HAS_SIGNATURE = 0x02

    /** Traffic-analysis padding buckets, copied from Bitchat's MessagePadding.blockSizes. */
    val blockSizes: List<Int> = listOf(256, 512, 1024, 2048)

    fun nowMillis(): Long = System.currentTimeMillis()

    fun encode(
      type: PopopxMeshMessageType,
      ttl: Int,
      senderID: ByteArray,
      recipientID: ByteArray?,
      payload: ByteArray,
      timestamp: Long = nowMillis(),
      padded: Boolean = true,
    ): ByteArray? =
      PopopxMeshPacket(
        version = 1,
        type = type.wireValue,
        ttl = ttl,
        timestamp = timestamp,
        senderID = senderID,
        recipientID = recipientID,
        payload = payload,
      ).encoded(padded)

    fun decode(data: ByteArray): PopopxMeshPacket? = decodeExact(data) ?: decodeExact(unpad(data))

    /**
     * PKCS#7-style, as Bitchat does it: every pad byte equals the pad length, which is what
     * [unpad] verifies. A frame that would need more than 255 pad bytes is left at its natural
     * length rather than faked, so sizes 513 and 769 travel unpadded even though a bucket exists.
     */
    fun pad(data: ByteArray, toSize: Int): ByteArray {
      if (data.size >= toSize) return data
      val paddingNeeded = toSize - data.size
      if (paddingNeeded > 255) return data
      return data.copyOf(data.size + paddingNeeded).also { padded ->
        for (index in data.size until padded.size) padded[index] = paddingNeeded.toByte()
      }
    }

    /** The input unchanged unless every byte the trailer claims really is the trailer. */
    fun unpad(data: ByteArray): ByteArray {
      if (data.isEmpty()) return data
      val last = data[data.size - 1]
      val paddingLength = last.toInt() and 0xFF
      if (paddingLength <= 0 || paddingLength > data.size) return data
      val start = data.size - paddingLength
      for (index in start until data.size) if (data[index] != last) return data
      return data.copyOfRange(0, start)
    }

    /**
     * Bitchat adds 16 bytes of headroom here because it pads plaintext before encryption. This
     * engine pads the finished outer frame, so no allowance is needed.
     */
    fun optimalBlockSize(size: Int): Int {
      for (blockSize in blockSizes) if (size <= blockSize) return blockSize
      return size
    }

    private fun decodeExact(raw: ByteArray): PopopxMeshPacket? {
      if (raw.size < HEADER_SIZE + PopopxMeshPeerID.BYTE_COUNT) return null
      if (raw[0].toInt() and 0xFF != 1) return null

      val type = raw[1].toInt() and 0xFF
      val ttl = raw[2].toInt() and 0xFF
      val timestamp = raw.u64At(3)
      val flags = raw[11].toInt() and 0xFF
      val payloadLength = ((raw[12].toInt() and 0xFF) shl 8) or (raw[13].toInt() and 0xFF)

      var offset = HEADER_SIZE
      val senderID = takeBytes(raw, offset, PopopxMeshPeerID.BYTE_COUNT) ?: return null
      offset += PopopxMeshPeerID.BYTE_COUNT

      var recipientID: ByteArray? = null
      if (flags and FLAG_HAS_RECIPIENT != 0) {
        recipientID = takeBytes(raw, offset, PopopxMeshPeerID.BYTE_COUNT) ?: return null
        offset += PopopxMeshPeerID.BYTE_COUNT
      }

      val payload = takeBytes(raw, offset, payloadLength) ?: return null
      offset += payloadLength

      var signature: ByteArray? = null
      if (flags and FLAG_HAS_SIGNATURE != 0) {
        signature = takeBytes(raw, offset, SIGNATURE_SIZE) ?: return null
      }

      // Anything past the last field is padding; a buffer shorter than the declared payload already
      // failed above. The decoded version is not written back — iOS always yields 1 here.
      return PopopxMeshPacket(
        version = 1,
        type = type,
        ttl = ttl,
        timestamp = timestamp,
        senderID = senderID,
        recipientID = recipientID,
        payload = payload,
        signature = signature,
      )
    }

    private fun takeBytes(raw: ByteArray, offset: Int, count: Int): ByteArray? {
      if (count < 0 || offset + count > raw.size) return null
      return raw.copyOfRange(offset, offset + count)
    }
  }
}
