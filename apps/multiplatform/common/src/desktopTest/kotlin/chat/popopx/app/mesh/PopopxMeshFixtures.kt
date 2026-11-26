package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxBLELink
import chat.popopx.common.mesh.PopopxBLETransportDelegate
import chat.popopx.common.mesh.PopopxBLETransporting
import chat.popopx.common.mesh.PopopxBluetoothState
import chat.popopx.common.mesh.PopopxMeshEvent
import chat.popopx.common.mesh.PopopxMeshPacket
import chat.popopx.common.mesh.PopopxMeshSecretStoring
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeout

/**
 * The radio the engine tests drive. It records instead of transmitting, and it never touches a real
 * adapter, which is the same reason iOS keeps `PopopxBLETransporting` behind an interface.
 *
 * [linkList] is mutable because a link's writability changes during a conversation, and the engine reads
 * `links()` on every delivery rather than caching it.
 */
internal class FakeMeshTransport(
  var radio: PopopxBluetoothState = PopopxBluetoothState.POWERED_ON,
  var linkList: MutableList<PopopxBLELink> = mutableListOf(),
) : PopopxBLETransporting {
  /** The engine registers itself here; the tests use it as the way in to the receive path. */
  var sink: PopopxBLETransportDelegate? = null
  val sent: MutableList<Pair<ByteArray, String>> = mutableListOf()
  var startCount = 0
  var stopCount = 0
  var accepted = true
  var notifyCount = 0

  override fun state(): PopopxBluetoothState = radio
  override fun links(): List<PopopxBLELink> = linkList.toList()
  override fun setDelegate(delegate: PopopxBLETransportDelegate?) {
    this.sink = delegate
  }

  override fun start() {
    startCount += 1
  }

  override fun stop() {
    stopCount += 1
  }

  override fun send(data: ByteArray, linkID: String): Boolean {
    sent += data to linkID
    return accepted
  }

  override fun notifySubscribers(data: ByteArray) {
    notifyCount += 1
  }

  override fun connect(linkID: String) = Unit
  override fun disconnect(linkID: String) = Unit

  /** The frames this transport was handed, decoded back into packets. */
  fun packets(): List<PopopxMeshPacket> =
    sent.mapNotNull { PopopxMeshPacket.decode(it.first) }
}

internal fun meshLink(id: String, central: Boolean = true, writable: Boolean = true, mtu: Int = 512): PopopxBLELink =
  PopopxBLELink(linkID = id, isCentralRole = central, canSend = writable, negotiatedMTU = mtu)

/** The Keychain stand-in. [refuseRemove] and [refuseSet] model the only two failures the wipe reports. */
internal class FakeMeshSecrets(
  private var refuseRemove: Boolean = false,
  private var refuseSet: Boolean = false,
) : PopopxMeshSecretStoring {
  val items = HashMap<String, ByteArray>()
  var removeAllCalls = 0

  private fun key(service: String, account: String) = "$service/$account"

  override fun data(service: String, account: String): ByteArray? = items[key(service, account)]

  override fun set(data: ByteArray, service: String, account: String): Boolean {
    if (refuseSet) return false
    items[key(service, account)] = data
    return true
  }

  override fun remove(service: String, account: String): Boolean {
    if (refuseRemove) return false
    items.remove(key(service, account))
    return !items.containsKey(key(service, account))
  }

  override fun removeAll(service: String): Boolean {
    removeAllCalls += 1
    val prefix = "$service/"
    if (refuseRemove) return false
    items.keys.filter { it.startsWith(prefix) }.forEach { items.remove(it) }
    return items.keys.none { it.startsWith(prefix) }
  }
}

/** Events out of one hub subscription, drained at the end of a case so ordering is explicit. */
internal class EventLog(val channel: Channel<PopopxMeshEvent>) {
  fun drain(): List<PopopxMeshEvent> {
    val out = mutableListOf<PopopxMeshEvent>()
    while (true) {
      val next = channel.tryReceive().getOrNull() ?: break
      out += next
    }
    return out
  }

  /**
   * The bounded wait for a path that publishes asynchronously: the transport's delegate hands the frame to
   * a coroutine, so [drain] would read an empty channel and report that as the result.
   */
  suspend fun awaitInbound(): PopopxMeshEvent.Inbound =
    withTimeout(AWAIT_MILLIS) {
      var found: PopopxMeshEvent.Inbound? = null
      while (found == null) {
        val event = channel.receive()
        if (event is PopopxMeshEvent.Inbound) found = event
      }
      found!!
    }

  private companion object {
    const val AWAIT_MILLIS = 5_000L
  }
}
