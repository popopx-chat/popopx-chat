package chat.popopx.common.mesh

/**
 * The desktop actual of the radio — a transport that says "no Bluetooth here" and takes nothing.
 *
 * It exists so `desktopTest` can build a real [PopopxMeshEngine] and drive it with frames injected
 * through `receive(data:linkID:)`. A JVM desktop build *could* in principle reach a radio through a
 * library, which would make every test that starts the engine a hardware test; this makes that
 * impossible instead of merely inadvisable, and the mesh banner on desktop reads
 * [PopopxBluetoothState.UNSUPPORTED] rather than pretending the radio is merely off.
 *
 * `send` reports failure through the delegate the way a dead link would, so engine code that trusts the
 * return value and code that waits for `didFailToSend` both get an answer.
 */
private class PopopxNoBLETransport : PopopxBLETransporting {
  private var delegate: PopopxBLETransportDelegate? = null

  override fun state(): PopopxBluetoothState = PopopxBluetoothState.UNSUPPORTED

  override fun links(): List<PopopxBLELink> = emptyList()

  override fun setDelegate(delegate: PopopxBLETransportDelegate?) {
    this.delegate = delegate
  }

  override fun start() = Unit

  override fun stop() = Unit

  override fun send(data: ByteArray, linkID: String): Boolean {
    delegate?.didFailToSend(data, linkID, PopopxBLETransportError.RadioOff)
    return false
  }

  override fun notifySubscribers(data: ByteArray) = Unit

  override fun connect(linkID: String) = Unit

  override fun disconnect(linkID: String) = Unit
}

actual fun popopxBLETransport(config: PopopxMeshConfig): PopopxBLETransporting = PopopxNoBLETransport()
