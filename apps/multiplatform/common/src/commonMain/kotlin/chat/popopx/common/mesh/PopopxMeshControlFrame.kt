package chat.popopx.common.mesh

/**
 * Single-token text frames — `PopopxMeshControlFrame` (PopopxMeshProtocol.swift:82-135). The prefix
 * is the whole protocol: everything after the first colon is the argument, and the argument may
 * itself contain colons, because an invite link does.
 */
sealed class PopopxMeshControlFrame(val text: String) {
  class PairingRequest(val inviteLink: String) : PopopxMeshControlFrame(PAIRING_REQUEST_PREFIX + inviteLink)

  class PairingAck(meshPublicKey: String) : PopopxMeshControlFrame(PAIRING_ACK_PREFIX + meshPublicKey)

  class DeliveryAck(messageId: String) : PopopxMeshControlFrame(DELIVERY_ACK_PREFIX + messageId)

  val messageType: PopopxMeshMessageType
    get() = when (this) {
      is PairingRequest -> PopopxMeshMessageType.PAIRING_REQUEST
      is PairingAck -> PopopxMeshMessageType.PAIRING_ACK
      is DeliveryAck -> PopopxMeshMessageType.DELIVERY_ACK
    }

  val payload: ByteArray get() = text.encodeToByteArray()

  // iOS' enum is Hashable, and the text carries both the case and its argument, so text alone is
  // the identity. Without this, two equal frames from two parses would compare unequal.
  override fun equals(other: Any?): Boolean = other is PopopxMeshControlFrame && text == other.text

  override fun hashCode(): Int = text.hashCode()

  override fun toString(): String = text

  companion object {
    const val PAIRING_REQUEST_PREFIX: String = "SYS_POPOPX_REQ:"
    const val PAIRING_ACK_PREFIX: String = "SYS_POPOPX_ACK:"
    const val DELIVERY_ACK_PREFIX: String = "BLE_ACK:"

    /**
     * An ACK id is ours (`PopopxMessageID`) and never longer, so this caps an attacker's string
     * before it reaches a dictionary key.
     */
    const val MAX_ARGUMENT_LENGTH: Int = 128

    /** nil for anything that is not one of the three frames, or whose argument is unusable. */
    fun of(text: String): PopopxMeshControlFrame? = when {
      text.startsWith(PAIRING_REQUEST_PREFIX) -> {
        val link = text.substring(PAIRING_REQUEST_PREFIX.length)
        if (link.isEmpty()) null else PairingRequest(link)
      }

      text.startsWith(PAIRING_ACK_PREFIX) -> {
        val key = text.substring(PAIRING_ACK_PREFIX.length)
        if (key.isMeshPublicKey()) PairingAck(key) else null
      }

      text.startsWith(DELIVERY_ACK_PREFIX) -> {
        val id = text.substring(DELIVERY_ACK_PREFIX.length)
        if (id.isEmpty() || id.length > MAX_ARGUMENT_LENGTH) null else DeliveryAck(id)
      }

      else -> null
    }
  }
}
