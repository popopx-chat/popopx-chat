package chat.popopx.common.mesh

/**
 * The Bluetooth transport, described as an interface rather than a class —
 * `apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/BLE/PopopxBLETransportContract.swift`.
 *
 * Two reasons, both of which survive the port: the engine holds it behind the interface so a unit test
 * can drive the mesh with an in-memory fake, and the real implementation is confined to one radio
 * thread on each platform. The methods are not `suspend` here even though iOS marks them `async`: on
 * iOS the suspension is only the hop onto the manager's serial queue, and Android's equivalent is a
 * `Handler`, which does not need the caller to cooperate. Nothing on either platform waits on the peer
 * inside these calls, so the seam stays synchronous and the engine's own thread is never parked.
 */

/**
 * One Bluetooth link, in either role. The transport knows nothing about mesh identity: a link is a
 * pipe, and the engine binds a link to a peer from the first packet that arrives on it.
 *
 * [linkID] is iOS' `UUID` (the peer's peripheral identifier) and Android' MAC address with a role
 * prefix, because a peer can simultaneously hold a link it dialed *and* a link we dialed; the id never
 * leaves the device, so the two platforms need not agree on its shape. Deviation 13 in the plan.
 */
class PopopxBLELink(
  val linkID: String,
  /** True when this device dialed the link (central role), false when the peer dialed us. */
  val isCentralRole: Boolean,
  /** A writable characteristic on the central side, at least one subscriber on the peripheral side. */
  val canSend: Boolean = false,
  /** The ATT MTU the system negotiated; 23 if the peer never answered a request. */
  val negotiatedMTU: Int = DEFAULT_ATT_MTU,
  val rssi: Byte? = null,
) {
  /** ATT leaves 3 bytes for the write/notify header. */
  val usablePayloadBytes: Int get() = maxOf(MIN_USABLE_PAYLOAD_BYTES, negotiatedMTU - ATT_HEADER_BYTES)

  override fun equals(other: Any?): Boolean =
    other is PopopxBLELink &&
      other.linkID == linkID &&
      other.isCentralRole == isCentralRole &&
      other.canSend == canSend &&
      other.negotiatedMTU == negotiatedMTU &&
      other.rssi == rssi

  override fun hashCode(): Int {
    var result = linkID.hashCode()
    result = 31 * result + isCentralRole.hashCode()
    result = 31 * result + canSend.hashCode()
    result = 31 * result + negotiatedMTU
    result = 31 * result + (rssi?.toInt() ?: 0)
    return result
  }

  override fun toString(): String =
    "PopopxBLELink($linkID, central=$isCentralRole, canSend=$canSend, mtu=$negotiatedMTU)"

  companion object {
    /** The ATT MTU a link that never negotiated one has, and the floor for anything stored. */
    const val DEFAULT_ATT_MTU: Int = 23

    /** The three bytes a write or a notify spends on its ATT header. */
    const val ATT_HEADER_BYTES: Int = 3

    /** A link never reports a payload budget below one ATT data packet. */
    const val MIN_USABLE_PAYLOAD_BYTES: Int = 20
  }
}

/** What the transport reports upward. Held weakly on both platforms: a transport must not keep its delegate alive. */
interface PopopxBLETransportDelegate {
  fun didUpdateState(state: PopopxBluetoothState)

  /** A link is open but not yet writable. */
  fun didOpen(link: PopopxBLELink)

  /** The link can take a frame now, for the first time or after a drain. */
  fun didBecomeWritable(link: PopopxBLELink)

  fun didClose(linkID: String, error: Exception?)

  fun didReceive(data: ByteArray, fromLinkID: String)

  fun didFailToSend(data: ByteArray, toLinkID: String, error: Exception?)
}

interface PopopxBLETransporting {
  fun state(): PopopxBluetoothState

  fun links(): List<PopopxBLELink>

  fun setDelegate(delegate: PopopxBLETransportDelegate?)

  /**
   * Starts scanning, advertising and connecting. Safe to call twice; does nothing while the radio is
   * off, and reports `.poweredOff` instead.
   */
  fun start()

  /** Stops everything and drops every link. Called by the global switch and by panic wipe. */
  fun stop()

  /**
   * Returns false when the link is unknown or closed. A true result means "handed to the radio", not
   * "the peer got it" — that is what the BLE ACK is for.
   */
  fun send(data: ByteArray, linkID: String): Boolean

  /** Peripheral side of a dual-role node: pushes a frame to every central subscribed to our characteristic. */
  fun notifySubscribers(data: ByteArray)

  fun connect(linkID: String)

  fun disconnect(linkID: String)
}

sealed class PopopxBLETransportError(override val message: String) : Exception(message) {
  object RadioOff : PopopxBLETransportError("radioOff")
  object Unauthorized : PopopxBLETransportError("unauthorized")
  class LinkNotFound(val linkID: String) : PopopxBLETransportError("linkNotFound($linkID)")
  class WriteQueueFull(val linkID: String) : PopopxBLETransportError("writeQueueFull($linkID)")
  class FrameTooLarge(val bytes: Int, val usable: Int) :
    PopopxBLETransportError("frameTooLarge(bytes=$bytes, usable=$usable)")
}

/**
 * The platform's radio. Android returns the dual-role CoreBluetooth analogue; desktop returns a
 * transport that reports [PopopxBluetoothState.POWERED_OFF] and takes nothing, so `desktopTest` can
 * build an engine without a Bluetooth stack and can never start one by accident.
 */
expect fun popopxBLETransport(
  config: PopopxMeshConfig = PopopxMeshConfig.default,
): PopopxBLETransporting
