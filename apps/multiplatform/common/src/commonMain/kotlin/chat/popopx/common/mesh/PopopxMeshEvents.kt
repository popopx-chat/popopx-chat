package chat.popopx.common.mesh

import kotlinx.coroutines.channels.Channel

/**
 * The mesh's outward-facing values and its event fan-out — a port of
 * `apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Events/PopopxMeshEvents.swift`, so the app layers
 * above the engine (banner, Cabin list, timeline) consume the same five events on both platforms and
 * nothing in here imports the app.
 *
 * `Date` becomes epoch milliseconds, which is what every other mesh type in this port already uses.
 */

/** What the radio is doing. The names are iOS' cases, in iOS' order. */
enum class PopopxBluetoothState {
  UNKNOWN,
  RESETTING,
  UNSUPPORTED,
  UNAUTHORIZED,
  POWERED_OFF,
  POWERED_ON,
  ;

  val isUsable: Boolean get() = this == POWERED_ON
}

/** A node the mesh knows about, direct or relayed. */
class PopopxMeshPeer(
  val peerID: PopopxMeshPeerID,
  /** The X25519 public key once an announce or a handshake revealed it; `peerID` alone cannot open a session. */
  val meshPublicKey: ByteArray?,
  val nickname: String?,
  /** Hops away, measured as (origin TTL - received TTL); 0 when this radio holds the link. */
  val hopCount: Int,
  val lastSeenAtMillis: Long,
  /**
   * Measured on iOS: the engine builds every peer with `rssi: nil` (PopopxMeshEngine.swift:43,318) even though the
   * transport records it on the link (PopopxBLETransport.swift:692). Kept as a nullable field so a later phase can
   * fill it in without changing this type, and left null by the engine exactly as iOS leaves it.
   */
  val rssi: Byte?,
  val isDirect: Boolean,
) {
  override fun equals(other: Any?): Boolean =
    other is PopopxMeshPeer &&
      other.peerID == peerID &&
      ((other.meshPublicKey == null && meshPublicKey == null) ||
        (other.meshPublicKey != null && meshPublicKey != null && other.meshPublicKey.contentEquals(meshPublicKey))) &&
      other.nickname == nickname &&
      other.hopCount == hopCount &&
      other.lastSeenAtMillis == lastSeenAtMillis &&
      other.rssi == rssi &&
      other.isDirect == isDirect

  override fun hashCode(): Int {
    var result = peerID.hashCode()
    result = 31 * result + (meshPublicKey?.contentHashCode() ?: 0)
    result = 31 * result + (nickname?.hashCode() ?: 0)
    result = 31 * result + hopCount
    result = 31 * result + lastSeenAtMillis.hashCode()
    result = 31 * result + (rssi?.toInt() ?: 0)
    result = 31 * result + isDirect.hashCode()
    return result
  }

  override fun toString(): String =
    "PopopxMeshPeer(peerID=$peerID, mesh=${meshPublicKey?.meshHex()?.take(8)}, nickname=$nickname, " +
      "hop=$hopCount, direct=$isDirect)"
}

/** What one inbound message carries. */
sealed class PopopxMeshBody {
  class Text(val text: String) : PopopxMeshBody()
  class Control(val frame: PopopxMeshControlFrame) : PopopxMeshBody()
  class Binary(val data: ByteArray) : PopopxMeshBody()

  override fun equals(other: Any?): Boolean =
    other is PopopxMeshBody &&
      when {
        this is Text && other is Text -> text == other.text
        this is Control && other is Control -> frame == other.frame
        this is Binary && other is Binary -> data.contentEquals(other.data)
        else -> false
      }

  override fun hashCode(): Int = when (this) {
    is Text -> text.hashCode()
    is Control -> frame.hashCode()
    is Binary -> data.contentHashCode()
  }

  override fun toString(): String = when (this) {
    is Text -> "Text($text)"
    is Control -> "Control($frame)"
    is Binary -> "Binary(${data.size}B)"
  }
}

class PopopxMeshInbound(
  val messageId: String,
  val sender: PopopxMeshPeerID,
  /** Nil until a handshake or an announce ties the 8-byte wire id to a public key. */
  val senderMeshPublicKey: ByteArray?,
  /** Nil for a broadcast. */
  val recipient: PopopxMeshPeerID?,
  val hopCount: Int,
  val isBroadcast: Boolean,
  val receivedAtMillis: Long,
  val body: PopopxMeshBody,
) {
  val controlFrame: PopopxMeshControlFrame?
    get() = (body as? PopopxMeshBody.Control)?.frame

  override fun equals(other: Any?): Boolean =
    other is PopopxMeshInbound &&
      other.messageId == messageId &&
      other.sender == sender &&
      ((other.senderMeshPublicKey == null && senderMeshPublicKey == null) ||
        (other.senderMeshPublicKey != null && senderMeshPublicKey != null &&
          other.senderMeshPublicKey.contentEquals(senderMeshPublicKey))) &&
      other.recipient == recipient &&
      other.hopCount == hopCount &&
      other.isBroadcast == isBroadcast &&
      other.receivedAtMillis == receivedAtMillis &&
      other.body == body

  override fun hashCode(): Int {
    var result = messageId.hashCode()
    result = 31 * result + sender.hashCode()
    result = 31 * result + (senderMeshPublicKey?.contentHashCode() ?: 0)
    result = 31 * result + (recipient?.hashCode() ?: 0)
    result = 31 * result + hopCount
    result = 31 * result + isBroadcast.hashCode()
    result = 31 * result + receivedAtMillis.hashCode()
    result = 31 * result + body.hashCode()
    return result
  }

  override fun toString(): String =
    "PopopxMeshInbound(messageId=$messageId, sender=$sender, hop=$hopCount, broadcast=$isBroadcast, body=$body)"
}

/** Why a frame could not be put on the radio. `sendFailed` only ever means "never left the device". */
sealed class PopopxMeshSendFailure {
  object NoLinkToPeer : PopopxMeshSendFailure()
  object LinkDropped : PopopxMeshSendFailure()
  object TtlExhausted : PopopxMeshSendFailure()
  class Oversized(val payloadBytes: Int, val limitBytes: Int) : PopopxMeshSendFailure()
  object NoSessionWithPeer : PopopxMeshSendFailure()
  class RadioUnavailable(val state: PopopxBluetoothState) : PopopxMeshSendFailure()

  override fun equals(other: Any?): Boolean =
    other is PopopxMeshSendFailure &&
      when {
        this is Oversized && other is Oversized -> payloadBytes == other.payloadBytes && limitBytes == other.limitBytes
        this is RadioUnavailable && other is RadioUnavailable -> state == other.state
        else -> this::class == other::class
      }

  override fun hashCode(): Int = when (this) {
    is Oversized -> 31 * payloadBytes + limitBytes
    is RadioUnavailable -> state.hashCode()
    else -> this::class.hashCode()
  }

  override fun toString(): String = when (this) {
    is NoLinkToPeer -> "noLinkToPeer"
    is LinkDropped -> "linkDropped"
    is TtlExhausted -> "ttlExhausted"
    is Oversized -> "oversized(payloadBytes=$payloadBytes, limitBytes=$limitBytes)"
    is NoSessionWithPeer -> "noSessionWithPeer"
    is RadioUnavailable -> "radioUnavailable($state)"
  }
}

/** Why a send threw. Wraps [PopopxMeshSendFailure] so callers catch one type while the stream keeps the richer value. */
class PopopxMeshSendError(val messageId: String, val failure: PopopxMeshSendFailure) : Exception(failure.toString())

/** One thing the mesh wants the app to know. */
sealed class PopopxMeshEvent {
  class BluetoothState(val state: PopopxBluetoothState) : PopopxMeshEvent()
  class PeerAppeared(val peer: PopopxMeshPeer) : PopopxMeshEvent()
  class PeerDisappeared(val peerID: PopopxMeshPeerID) : PopopxMeshEvent()
  class Inbound(val inbound: PopopxMeshInbound) : PopopxMeshEvent()

  /** The mesh could not put a message on the radio at all. A BLE ACK timeout is module 4's verdict, not this. */
  class SendFailed(val messageId: String, val peer: PopopxMeshPeerID?, val reason: PopopxMeshSendFailure) : PopopxMeshEvent()
}

/**
 * One publisher, many consumers, as iOS' `PopopxMeshEventHub` is.
 *
 * iOS hands each subscriber an `AsyncStream` with unbounded buffering and removes it through
 * `onTermination`. The Kotlin equivalent is an unlimited [Channel] with [Channel.invokeOnClose], so a
 * consumer that stops reading — or whose `LaunchedEffect` is cancelled — unregisters itself and cannot
 * stall the mesh. [publish] never suspends: `trySend` to a full unbounded channel cannot fail, and a
 * closed subscriber is dropped rather than retried.
 */
class PopopxMeshEventHub {
  private val lock = Any()
  private var nextID = 0L
  private val subscriptions = HashMap<Long, Channel<PopopxMeshEvent>>()

  fun subscribe(): Channel<PopopxMeshEvent> {
    val id: Long
    val channel = Channel<PopopxMeshEvent>(Channel.UNLIMITED)
    synchronized(lock) {
      id = nextID++
      subscriptions[id] = channel
    }
    channel.invokeOnClose { unsubscribe(id) }
    return channel
  }

  fun unsubscribe(id: Long) {
    val channel = synchronized(lock) { subscriptions.remove(id) }
    channel?.close()
  }

  /** Removes every subscriber and closes every stream — what a UI teardown calls. */
  fun unsubscribeAll() {
    val channels = synchronized(lock) {
      val all = subscriptions.values.toList()
      subscriptions.clear()
      all
    }
    for (channel in channels) channel.close()
  }

  fun publish(event: PopopxMeshEvent) {
    for (channel in synchronized(lock) { subscriptions.values.toList() }) {
      channel.trySend(event)
    }
  }

  val subscriberCount: Int get() = synchronized(lock) { subscriptions.size }

  companion object {
    val shared: PopopxMeshEventHub = PopopxMeshEventHub()
  }
}
