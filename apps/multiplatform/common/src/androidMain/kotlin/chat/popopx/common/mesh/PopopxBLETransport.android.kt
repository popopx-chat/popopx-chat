package chat.popopx.common.mesh

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelUuid
import chat.popopx.common.platform.AppContextProvider
import java.lang.ref.WeakReference
import java.util.TreeMap
import java.util.UUID

/**
 * The Android dual-role radio — `apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/BLE/PopopxBLETransport.swift`,
 * on `BluetoothLeScanner` + `BluetoothLeAdvertiser` + `BluetoothGattServer`.
 *
 * Isolation follows iOS: apart from the immutable fields, every piece of state here is read and written
 * under [lock] only. Android delivers both roles' callbacks on the main thread while our callers are the
 * engine's thread and the maintenance handler's, so that lock is what makes them one owner. The handler
 * exists to keep the delayed work (duty cycle, maintenance, connect deadline) off the main thread and to
 * make each of them cancellable by reference, which is what iOS' `DispatchWorkItem` does there.
 *
 * Where Android genuinely differs, this file says so rather than pretending otherwise:
 * - One radio state, not two managers' combined. Both roles here *are* the same adapter, so the single
 *   `STATE_*` read is the same fact iOS derives, including its `.poweredOn`-only-when-both-are-up rule.
 * - No state restoration: `centralRestoreIdentifier` has no Android equivalent (plan deviation 7). A
 *   process kill drops every bearer; a pending-intent scan restores discoveries, never connections.
 * - `connect(linkID:)` is fire-and-forget because the contract returns Unit; iOS' continuation existed
 *   only for its `async` signature. The table's pending-handshake flag still records the attempt.
 * - No `canSendWriteWithoutResponse`: one ATT write may be outstanding per link, so the gate closes on
 *   every accepted write and `onCharacteristicWrite` is what reopens it (see [writeAsCentral]).
 */
private class PopopxBLETransportAndroid(
  private val context: Context?,
  private val manager: BluetoothManager?,
  private val config: PopopxMeshConfig,
) : PopopxBLETransporting {

  private val lock = Any()
  private val adapter: BluetoothAdapter? = manager?.adapter
  private val serviceUuid: UUID? = uuidOf(config.serviceUUID)
  private val characteristicUuid: UUID? = uuidOf(config.characteristicUUID)

  private val links = PopopxBLELinkTable(
    maxQueuedFrames = PopopxBLELinkTable.QUEUED_FRAMES_PER_LINK,
    maxCentralLinks = config.maxCentralLinks,
    maxMTU = config.maxMTU,
  )

  /** Held as iOS holds it — a transport must not keep its delegate alive. */
  private var delegateRef: WeakReference<PopopxBLETransportDelegate>? = null

  /** Handles we dialed (central role), and the characteristic of each; without the latter a link is connected but mute. */
  private val clientHandles = HashMap<String, BluetoothGatt>()
  private val writeTargets = HashMap<String, BluetoothGattCharacteristic>()

  /** Centrals that subscribed to our characteristic — iOS' `centrals`, which `registerSubscriber` fills. */
  private val subscribers = HashMap<String, BluetoothDevice>()
  private var server: BluetoothGattServer? = null
  private var servicePublished = false

  private var wantsToRun = false
  private var reportedState = PopopxBluetoothState.UNKNOWN
  private enum class ScanPhase { SCANNING, PAUSED }

  private var scanPhase = ScanPhase.PAUSED
  private var scanRunning = false
  private var advertisingRequested = false
  private val connectDeadlines = HashMap<String, Runnable>()
  private val preparedWrites = HashMap<String, TreeMap<Int, ByteArray>>()

  private var radioThread: HandlerThread? = null
  private var radioHandler: Handler? = null
  private var scanDuty: Runnable? = null
  private var maintenance: Runnable? = null
  private var adapterReceiver: BroadcastReceiver? = null

  private val delegate: PopopxBLETransportDelegate? get() = delegateRef?.get()

  // MARK: - PopopxBLETransporting

  override fun state(): PopopxBluetoothState = synchronized(lock) { reportedState }

  override fun links(): List<PopopxBLELink> = synchronized(lock) { links.links }

  override fun setDelegate(delegate: PopopxBLETransportDelegate?) {
    synchronized(lock) { delegateRef = delegate?.let { WeakReference(it) } }
  }

  override fun start() {
    synchronized(lock) {
      if (wantsToRun) return
      wantsToRun = true
      if (context == null || adapter == null || serviceUuid == null || characteristicUuid == null) {
        publish(PopopxBluetoothState.UNSUPPORTED)
        return
      }
      if (missingPermissions() != null) {
        // Reported once and never asked for twice: requesting belongs to the UI, and a transport that
        // re-checked on every duty tick would be a permission prompt on a timer.
        publish(PopopxBluetoothState.UNAUTHORIZED)
        return
      }
      registerAdapterReceiver()
      publish(adapterState())
      if (reportedState != PopopxBluetoothState.POWERED_ON) return
      bringRadioUp()
    }
  }

  override fun stop() {
    synchronized(lock) {
      wantsToRun = false
      cancelTimers()
      unregisterAdapterReceiver()
      guarded { scanner()?.stopScan(scanCallback) }
      guarded { advertiser()?.stopAdvertising(advertiseCallback) }
      scanRunning = false
      advertisingRequested = false
      dropAllLinks(null)
      for (handle in clientHandles.values) guarded { handle.close() }
      clientHandles.clear()
      writeTargets.clear()
      subscribers.clear()
      preparedWrites.clear()
      closeServer()
      servicePublished = false
    }
  }

  override fun send(data: ByteArray, linkID: String): Boolean = synchronized(lock) {
    if (!wantsToRun) {
      fail(data, linkID, PopopxBLETransportError.RadioOff)
      return@synchronized false
    }
    when (val decision = links.requestSend(data, linkID)) {
      is PopopxBLELinkTable.SendDecision.Rejected -> {
        // `.frameTooLarge` lands here, and the frame is refused whole rather than truncated: splitting a
        // message into MTU-sized pieces is the engine's job, and it owns fragment lifetimes and relay TTLs.
        fail(data, linkID, decision.error)
        false
      }
      PopopxBLELinkTable.SendDecision.Queued -> true
      is PopopxBLELinkTable.SendDecision.Transmit -> putOnRadio(decision.frame, linkID)
    }
  }

  /**
   * Peripheral-side flood, delivered link by link rather than in one call, as iOS does it: one slow
   * subscriber then parks the frame in its own queue instead of making a single call decide the whole
   * flood was sent when half the neighbourhood never got it.
   */
  override fun notifySubscribers(data: ByteArray) {
    synchronized(lock) {
      if (!wantsToRun) return
      for (linkID in subscribers.keys.toList()) send(data, linkID)
    }
  }

  override fun connect(linkID: String) {
    synchronized(lock) {
      if (!wantsToRun || !radioIsUsable() || !isCentralLink(linkID)) return
      val device = remoteDevice(linkID) ?: return
      beginDial(linkID, device)
    }
  }

  override fun disconnect(linkID: String) {
    synchronized(lock) {
      val link = links.link(linkID) ?: return
      val handle = clientHandles[linkID]
      if (link.isCentralRole && handle != null) {
        // `onConnectionStateChange` closes the link; closing it here too would report a bearer the radio
        // has not released yet.
        guarded { handle.disconnect() }
        return
      }
      // A server cannot evict a central that dialed it — the same limit iOS' `CBPeripheralManager` has, and
      // the same answer: retire our side, and a peer that keeps writing reopens it.
      closeLink(linkID, null)
    }
  }

  // MARK: - Radio up / down

  private fun bringRadioUp() {
    startScanCycle()
    publishOurService()
    startMaintenance()
  }

  private fun dropAllLinks(error: Exception?) {
    for (outcome in links.closeAll()) reportDropped(outcome, error)
    preparedWrites.clear()
  }

  private fun reportDropped(outcome: PopopxBLELinkTable.CloseOutcome, error: Exception?) {
    for (frame in outcome.droppedQueuedFrames) fail(frame, outcome.link.linkID, error)
    delegate?.didClose(outcome.link.linkID, error)
  }

  private fun closeServer() {
    val closing = server ?: return
    server = null
    servicePublished = false
    advertisingRequested = false
    guarded { closing.close() }
  }

  private fun handler(): Handler {
    radioHandler?.let { return it }
    val thread = HandlerThread("popopx-mesh-ble").apply { start() }
    val created = Handler(thread.looper)
    radioThread = thread
    radioHandler = created
    return created
  }

  private fun cancelTimers() {
    val handler = radioHandler
    scanDuty?.let { handler?.removeCallbacks(it) }
    scanDuty = null
    scanRunning = false
    scanPhase = ScanPhase.PAUSED
    maintenance?.let { handler?.removeCallbacks(it) }
    maintenance = null
    for (deadline in connectDeadlines.values) handler?.removeCallbacks(deadline)
    connectDeadlines.clear()
  }

  // MARK: - Duty cycle and maintenance

  /**
   * Scan for `scanOnDuration`, rest for `scanOffDuration`, advertising left running through the rest —
   * the same split iOS makes, so neighbours dialing us are not the ones paying for our duty cycle.
   */
  private fun startScanCycle() {
    if (!wantsToRun || !radioIsUsable()) return
    scanDuty?.let { radioHandler?.removeCallbacks(it) }
    scanPhase = ScanPhase.PAUSED
    handler().post(stepScan)
  }

  private val stepScan = Runnable { synchronized(lock) { stepScanDuty() } }

  private fun stepScanDuty() {
    if (!wantsToRun || !radioIsUsable()) return
    val scanner = scanner() ?: return
    when (scanPhase) {
      ScanPhase.SCANNING -> {
        if (scanRunning) {
          guarded { scanner.stopScan(scanCallback) }
          scanRunning = false
        }
        scanPhase = ScanPhase.PAUSED
        armScanDuty(millisOf(config.scanOffDuration))
      }
      ScanPhase.PAUSED -> {
        scanRunning = guarded { runCatching { scanner.startScan(scanFilters(), scanSettings, scanCallback) }.isSuccess } ?: false
        scanPhase = ScanPhase.SCANNING
        armScanDuty(millisOf(config.scanOnDuration))
      }
    }
  }

  private fun armScanDuty(delayMillis: Long) {
    scanDuty?.let { radioHandler?.removeCallbacks(it) }
    handler().postDelayed(stepScan, delayMillis)
    scanDuty = stepScan
  }

  /**
   * A liveness pass every `maintenanceInterval`. Android drops advertising when the app is backgrounded
   * without a companion foreground service, and a scan can be lost across an adapter reset; those are the
   * failures this transport can notice from the outside, so they are the only ones it tries to repair.
   */
  private fun startMaintenance() {
    val interval = millisOf(config.maintenanceInterval)
    if (interval <= 0L) return
    maintenance?.let { radioHandler?.removeCallbacks(it) }
    handler().postDelayed(stepMaintenance, interval)
    maintenance = stepMaintenance
  }

  private val stepMaintenance = Runnable { synchronized(lock) { tickMaintenance() } }

  private fun tickMaintenance() {
    if (!wantsToRun) return
    if (radioIsUsable()) {
      if (!scanRunning) startScanCycle()
      if (servicePublished && !advertisingRequested) startAdvertising()
    }
    startMaintenance()
  }

  private fun scanFilters(): List<ScanFilter> {
    val uuid = serviceUuid ?: return emptyList()
    return listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(uuid)).build())
  }

  private val scanSettings: ScanSettings =
    ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()

  // MARK: - Peripheral role: the GATT database

  private fun publishOurService() {
    if (server == null) {
      val opened = guarded { manager?.openGattServer(context, serverCallback) }
      if (opened == null) {
        publish(PopopxBluetoothState.UNSUPPORTED)
        return
      }
      server = opened
    }
    if (servicePublished) {
      if (!advertisingRequested) startAdvertising()
      return
    }
    val uuid = serviceUuid ?: return
    val characteristic = BluetoothGattCharacteristic(
      characteristicUuid ?: return,
      // No READ property, as iOS: a readable characteristic we never answer looks to the peer like a dead
      // link. Writes and notifications carry the whole protocol.
      BluetoothGattCharacteristic.PROPERTY_NOTIFY or
        BluetoothGattCharacteristic.PROPERTY_WRITE or
        BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
      BluetoothGattCharacteristic.PERMISSION_WRITE,
    )
    val service = BluetoothGattService(uuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
    service.addCharacteristic(characteristic)
    guarded { server?.addService(service) }
  }

  private fun startAdvertising() {
    val advertiser = advertiser() ?: return
    val uuid = serviceUuid ?: return
    // Service UUID and nothing else, as iOS: no device name, because the bytes are needed by the service
    // list and a name would tell every passer-by which app is installed on this phone.
    val data =
      AdvertiseData.Builder()
        .setIncludeDeviceName(false)
        .setIncludeTxPowerLevel(false)
        .addServiceUuid(ParcelUuid(uuid))
        .build()
    val settings =
      AdvertiseSettings.Builder()
        .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
        .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_LOW)
        .setConnectable(true)
        .setTimeout(0)
        .build()
    advertisingRequested = guarded { runCatching { advertiser.startAdvertising(settings, data, advertiseCallback) }.isSuccess } ?: false
  }

  private val advertiseCallback =
    object : AdvertiseCallback() {
      override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
        synchronized(lock) { advertisingRequested = true }
      }

      override fun onStartFailure(errorCode: Int) {
        synchronized(lock) {
          // `ADVERTISE_FAILED_TOO_MANY_ADVERTISERS` is the OEM offload limit (plan deviation 8) and
          // `ADVERTISE_FAILED_ALREADY_STARTED` is us losing track of a tick; neither is a radio failure,
          // so the state keeps its meaning and the maintenance pass is what retries.
          if (errorCode != AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED) advertisingRequested = false
        }
      }
    }

  // MARK: - Central role: dialing

  private fun beginDial(linkID: String, device: BluetoothDevice): Boolean {
    if (!radioIsUsable()) return false
    if (links.link(linkID) == null) links.open(linkID, isCentralRole = true)
    links.markHandshakePending(linkID)
    // The deadline is armed whatever happens next: a bearer that connects but never delivers a
    // characteristic is as stuck as one that never connects, and it holds one of `maxCentralLinks` either way.
    armConnectDeadline(linkID)
    if (clientHandles[linkID] != null) return true
    // The handler is the Android equivalent of iOS handing CoreBluetooth its delegate queue: every callback
    // for this bearer then arrives on the radio thread instead of the main one.
    val handle = guarded {
      runCatching {
        device.connectGatt(context, false, clientCallback, BluetoothDevice.TRANSPORT_LE, BluetoothDevice.ADDRESS_TYPE_UNKNOWN, handler())
      }.getOrNull()
    }
    if (handle == null) {
      closeLink(linkID, PopopxBLETransportError.RadioOff)
      return false
    }
    clientHandles[linkID] = handle
    return true
  }

  private fun armConnectDeadline(linkID: String) {
    connectDeadlines[linkID]?.let { radioHandler?.removeCallbacks(it) }
    val deadline =
      Runnable {
        synchronized(lock) {
          if (!wantsToRun || links.link(linkID) == null) return@synchronized
          if (writeTargets[linkID] != null) return@synchronized
          closeLink(linkID, PopopxBLETransportError.LinkNotFound(linkID))
        }
      }
    connectDeadlines[linkID] = deadline
    handler().postDelayed(deadline, millisOf(config.connectTimeout))
  }

  private fun cancelConnectDeadline(linkID: String) {
    connectDeadlines.remove(linkID)?.let { radioHandler?.removeCallbacks(it) }
  }

  // MARK: - Link events

  private fun closeLink(linkID: String, error: Exception?) {
    cancelConnectDeadline(linkID)
    val handle = clientHandles.remove(linkID)
    if (handle != null) {
      writeTargets.remove(linkID)
      guarded { handle.close() }
    }
    subscribers.remove(linkID)
    preparedWrites.remove(linkID)
    val outcome = links.close(linkID) ?: return
    reportDropped(outcome, error)
  }

  /** Answers nil from the table when nothing flipped, so a link already open avoids announcing itself writable again. */
  private fun makeLinkWritable(linkID: String) {
    val link = links.setCanSend(true, linkID) ?: return
    delegate?.didBecomeWritable(link)
  }

  // MARK: - Sending

  private fun putOnRadio(frame: ByteArray, linkID: String): Boolean =
    if (links.link(linkID)?.isCentralRole == true) writeAsCentral(frame, linkID) else notifyAsPeripheral(frame, linkID)

  private fun writeAsCentral(frame: ByteArray, linkID: String): Boolean {
    val handle = clientHandles[linkID]
    val target = writeTargets[linkID]
    if (handle == null || target == null) {
      // Connected but mute: the frame has no destination, so it is failed rather than parked where
      // nothing will ever drain it.
      links.abandonFrame(linkID)
      fail(frame, linkID, PopopxBLETransportError.LinkNotFound(linkID))
      return false
    }
    val accepted = guarded { writeWithoutResponse(handle, target, frame) } ?: false
    if (!accepted) {
      links.abandonFrame(linkID)
      fail(frame, linkID, PopopxBLETransportError.WriteQueueFull(linkID))
      return false
    }
    links.setCanSend(false, linkID)
    return true
  }

  /**
   * WRITE_TYPE_NO_RESPONSE, because a write that demands a response costs a round trip per frame and the
   * mesh keeps its own ACK above this layer. The two-parameter overload is API 33, and the pre-33 form
   * mutates the characteristic, so the call is the only part that differs.
   */
  @Suppress("DEPRECATION")
  private fun writeWithoutResponse(handle: BluetoothGatt, target: BluetoothGattCharacteristic, frame: ByteArray): Boolean =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      // The API 33 form takes the bytes as an argument and answers with a status code rather than a
      // boolean; 0 is the only accepted answer.
      handle.writeCharacteristic(target, frame, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) == BluetoothStatusCodes.SUCCESS
    } else {
      target.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
      target.setValue(frame) && handle.writeCharacteristic(target)
    }

  /**
   * One notification to one central. `notifyCharacteristicChanged` returns false on the pre-33 form when
   * the local transmit buffer is full, and `BluetoothStatusCodes.ERROR_GATT_WRITE_REQUEST_BUSY` on the
   * current one; both mean the same thing, which is why the caller keeps the frame at the head of the queue.
   */
  @Suppress("DEPRECATION")
  private fun notifyOne(device: BluetoothDevice, characteristic: BluetoothGattCharacteristic, frame: ByteArray): Boolean =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      server?.notifyCharacteristicChanged(device, characteristic, false, frame) == BluetoothStatusCodes.SUCCESS
    } else {
      characteristic.setValue(frame) && server?.notifyCharacteristicChanged(device, characteristic, false) == true
    }

  private fun notifyAsPeripheral(frame: ByteArray, linkID: String): Boolean {
    val serviceUuid = serviceUuid
    val characteristicUuid = characteristicUuid
    val characteristic =
      if (serviceUuid == null || characteristicUuid == null) null
      else server?.getService(serviceUuid)?.getCharacteristic(characteristicUuid)
    val device = subscribers[linkID]
    if (characteristic == null || device == null) {
      // Either our service is gone or that central never subscribed: a notification to it cannot exist.
      links.abandonFrame(linkID)
      fail(frame, linkID, PopopxBLETransportError.LinkNotFound(linkID))
      return false
    }
    val accepted = guarded { notifyOne(device, characteristic, frame) } ?: false
    if (!accepted) {
      // Refused for a full local transmit queue. The frame keeps its place at the head of this link's
      // queue and the gate shuts until `onNotificationSent`, so a flood is not offered to the same full
      // buffer one frame at a time.
      if (!links.returnFrame(frame, linkID)) fail(frame, linkID, PopopxBLETransportError.WriteQueueFull(linkID))
      links.setCanSend(false, linkID)
    }
    return true
  }

  /** Empties a link's queue while the gate is open; stops when it runs dry or the link goes away. */
  private fun drain(linkID: String) {
    while (wantsToRun) {
      val frame = links.nextPendingFrame(linkID) ?: return
      if (!putOnRadio(frame, linkID)) return
      if (links.link(linkID)?.canSend != true) return
    }
  }

  private fun receive(data: ByteArray, linkID: String) {
    if (!wantsToRun || data.isEmpty() || links.link(linkID) == null) return
    delegate?.didReceive(data, linkID)
  }

  private fun fail(frame: ByteArray, linkID: String, error: Exception?) {
    delegate?.didFailToSend(frame, linkID, error)
  }

  // MARK: - Radio state

  private fun adapterState(): PopopxBluetoothState {
    val adapter = adapter ?: return PopopxBluetoothState.UNSUPPORTED
    val app = context ?: return PopopxBluetoothState.UNSUPPORTED
    // Android answers "this device has no BLE" with the feature flag, never with the adapter: a switched-off
    // radio is `state == STATE_OFF`, which is poweredOff rather than unsupported, and reporting it as the
    // latter would leave the engine with no way to tell the user to turn Bluetooth on.
    if (guarded { app.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) } != true) {
      return PopopxBluetoothState.UNSUPPORTED
    }
    if (missingPermissions() != null) return PopopxBluetoothState.UNAUTHORIZED
    return when (guarded { adapter.state } ?: BluetoothAdapter.STATE_OFF) {
      BluetoothAdapter.STATE_ON -> PopopxBluetoothState.POWERED_ON
      BluetoothAdapter.STATE_OFF -> PopopxBluetoothState.POWERED_OFF
      BluetoothAdapter.STATE_TURNING_ON, BluetoothAdapter.STATE_TURNING_OFF -> PopopxBluetoothState.RESETTING
      else -> PopopxBluetoothState.UNKNOWN
    }
  }

  private fun radioIsUsable(): Boolean = adapterState() == PopopxBluetoothState.POWERED_ON

  private fun publish(state: PopopxBluetoothState) {
    if (state == reportedState) return
    reportedState = state
    delegate?.didUpdateState(state)
  }

  /** A radio that went down took our links with it and rejects commands about them; let `.poweredOn` rebuild. */
  private fun handleRadioDown() {
    cancelTimers()
    dropAllLinks(PopopxBLETransportError.RadioOff)
    for (handle in clientHandles.values) guarded { handle.close() }
    clientHandles.clear()
    writeTargets.clear()
    subscribers.clear()
    closeServer()
  }

  private fun registerAdapterReceiver() {
    if (adapterReceiver != null || context == null) return
    val listener =
      object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context?, intent: Intent?) {
          synchronized(lock) {
            publish(adapterState())
            if (!reportedState.isUsable) handleRadioDown() else if (wantsToRun) bringRadioUp()
          }
        }
      }
    val registered =
      guarded {
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
          context.registerReceiver(listener, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
          context.registerReceiver(listener, filter)
        }
        listener
      }
    adapterReceiver = registered
  }

  private fun unregisterAdapterReceiver() {
    val listener = adapterReceiver ?: return
    adapterReceiver = null
    guarded { context?.unregisterReceiver(listener) }
  }

  /** Null when the radio may be used. Which permission is missing is the UI's message, not this class's. */
  private fun missingPermissions(): String? {
    val context = context ?: return null
    val needed =
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
      } else {
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
      }
    return needed.firstOrNull { guarded { context.checkSelfPermission(it) } != PackageManager.PERMISSION_GRANTED }
  }

  private fun scanner(): BluetoothLeScanner? = guarded { adapter?.bluetoothLeScanner }
  private fun advertiser(): BluetoothLeAdvertiser? = guarded { adapter?.bluetoothLeAdvertiser }

  /** A permission revoked while we run ends the session rather than retrying into another exception. */
  private inline fun <T> guarded(block: () -> T): T? =
    try {
      block()
    } catch (error: SecurityException) {
      publish(PopopxBluetoothState.UNAUTHORIZED)
      null
    }

  // MARK: - Link ids

  /**
   * A peer can hold a link it dialed *and* a link we dialed at once, so the MAC address alone would merge
   * them into one queue and one identity. The prefix never leaves the device (plan deviation 13).
   */
  private fun centralLinkID(address: String): String = "$CENTRAL_PREFIX$address"

  private fun peripheralLinkID(address: String): String = "$PERIPHERAL_PREFIX$address"

  private fun isCentralLink(linkID: String): Boolean = linkID.startsWith(CENTRAL_PREFIX)

  private fun remoteDevice(linkID: String): BluetoothDevice? {
    val address = linkID.removePrefix(CENTRAL_PREFIX).removePrefix(PERIPHERAL_PREFIX)
    return guarded { runCatching { adapter?.getRemoteDevice(address) }.getOrNull() }
  }

  // MARK: - Central-role callbacks

  private val clientCallback =
    object : BluetoothGattCallback() {
      override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
        val linkID = linkIdOf(gatt) ?: return
        synchronized(lock) {
          if (!wantsToRun) return@synchronized
          if (newState == BluetoothProfile.STATE_CONNECTED) {
            clientHandles[linkID] = gatt
            if (links.link(linkID) == null) {
              val link = links.open(linkID, isCentralRole = true)
              delegate?.didOpen(link)
            }
            guarded { gatt.discoverServices() }
            return@synchronized
          }
          closeLink(linkID, PopopxBLETransportError.LinkNotFound(linkID))
        }
      }

      override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
        val linkID = linkIdOf(gatt) ?: return
        synchronized(lock) {
          if (!wantsToRun) return@synchronized
          val serviceUuid = serviceUuid ?: return@synchronized
          val characteristicUuid = characteristicUuid ?: return@synchronized
          val target =
            if (status != BluetoothGatt.GATT_SUCCESS) null
            else gatt.getService(serviceUuid)?.getCharacteristic(characteristicUuid)
          if (target == null) {
            // Our service without our characteristic is not a POPOPX peer we can speak to.
            guarded { gatt.disconnect() }
            closeLink(linkID, null)
            return@synchronized
          }
          writeTargets[linkID] = target
          subscribe(gatt, target)
        }
      }

      @Suppress("DEPRECATION")
      private fun subscribe(gatt: BluetoothGatt, target: BluetoothGattCharacteristic) {
        // Android has no subscription-only call: notifications need the CCC descriptor written, and the
        // stack will not deliver anything until it is.
        guarded { gatt.setCharacteristicNotification(target, true) }
        val descriptor = target.getDescriptor(CLIENT_CHARACTERISTIC_CONFIG) ?: return
        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        guarded { gatt.writeDescriptor(descriptor) }
      }

      override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
        val linkID = linkIdOf(gatt) ?: return
        synchronized(lock) {
          if (!wantsToRun) return@synchronized
          makeLinkWritable(linkID)
          drain(linkID)
        }
      }

      override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
        val linkID = linkIdOf(gatt) ?: return
        synchronized(lock) {
          if (!wantsToRun) return@synchronized
          if (descriptor.uuid != CLIENT_CHARACTERISTIC_CONFIG || status != BluetoothGatt.GATT_SUCCESS) return@synchronized
          // iOS re-reads the write budget here because subscription is when CoreBluetooth settles the MTU.
          // Android has no budget to read (`BluetoothGatt` exposes no getter) and reports the same fact
          // through `onMtuChanged`, which is already wired.
          links.completeHandshake(linkID)
          cancelConnectDeadline(linkID)
          makeLinkWritable(linkID)
          drain(linkID)
        }
      }

      override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
        val linkID = linkIdOf(gatt) ?: return
        synchronized(lock) {
          if (!wantsToRun || status != BluetoothGatt.GATT_SUCCESS) return@synchronized
          // Read-only, never requested: `requestMtu` would move the peer's payload budget out from under it
          // (plan deviation 6).
          links.recordMTU(mtu, linkID)
        }
      }

      @Suppress("DEPRECATION")
      override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        val linkID = linkIdOf(gatt) ?: return
        val value = guarded { characteristic.value } ?: return
        synchronized(lock) { receive(value, linkID) }
      }

      // Both forms are overridden on purpose: 33 moved the bytes into the callback and stopped writing them
      // into the characteristic, so a single-argument handler would silently see nothing on a new stack.
      override fun onCharacteristicChanged(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray,
      ) {
        val linkID = linkIdOf(gatt) ?: return
        if (value.isEmpty()) return
        synchronized(lock) { receive(value, linkID) }
      }

      private fun linkIdOf(gatt: BluetoothGatt): String? =
        guarded { runCatching { gatt.device?.address }.getOrNull() }?.let { centralLinkID(it) }
    }

  // MARK: - Peripheral-role callbacks

  private val serverCallback =
    object : BluetoothGattServerCallback() {
      override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
        val linkID = linkIdOf(device) ?: return
        synchronized(lock) {
          if (!wantsToRun) return@synchronized
          if (newState == BluetoothProfile.STATE_CONNECTED) return@synchronized
          // A connection without a subscription is not a link iOS would have opened either; only the
          // CCCD write below or an inbound write makes a peer real. This branch is the teardown of one.
          closeLink(linkID, PopopxBLETransportError.LinkNotFound(linkID))
        }
      }

      override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
        val linkID = linkIdOf(device) ?: return
        synchronized(lock) { if (wantsToRun) links.recordMTU(mtu, linkID) }
      }

      override fun onCharacteristicReadRequest(
        device: BluetoothDevice,
        requestId: Int,
        offset: Int,
        characteristic: BluetoothGattCharacteristic,
      ) {
        // The service declares nothing readable, so this is a peer probing what we do not offer. Answering
        // is still required, or its ATT request hangs and it calls the link dead.
        guarded { runCatching { server?.sendResponse(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, offset, null) } }
      }

      override fun onCharacteristicWriteRequest(
        device: BluetoothDevice,
        requestId: Int,
        characteristic: BluetoothGattCharacteristic,
        preparedWrite: Boolean,
        responseNeeded: Boolean,
        offset: Int,
        value: ByteArray?,
      ) {
        val linkID = linkIdOf(device) ?: return
        synchronized(lock) {
          // Answer ATT first: a request left hanging for a few milliseconds is a timeout at the peer,
          // whatever we end up doing with the bytes.
          if (responseNeeded) {
            guarded { runCatching { server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value) } }
          }
          if (!wantsToRun || characteristic.uuid != characteristicUuid) return@synchronized

          val frame = if (preparedWrite) accumulatePrepared(linkID, offset, value) else value
          if (frame == null || frame.isEmpty()) return@synchronized

          if (links.link(linkID) == null) {
            // A central can write without ever subscribing. That makes it a live link we must be able to
            // attribute traffic to, but not a writable one: notifications need a subscription.
            val link = links.open(linkID, isCentralRole = false, canSend = false)
            delegate?.didOpen(link)
          }
          receive(frame, linkID)
        }
      }

      override fun onDescriptorWriteRequest(
        device: BluetoothDevice,
        requestId: Int,
        descriptor: BluetoothGattDescriptor,
        preparedWrite: Boolean,
        responseNeeded: Boolean,
        offset: Int,
        value: ByteArray?,
      ) {
        if (responseNeeded) {
          guarded { runCatching { server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value) } }
        }
        val linkID = linkIdOf(device) ?: return
        synchronized(lock) {
          if (!wantsToRun || descriptor.uuid != CLIENT_CHARACTERISTIC_CONFIG) return@synchronized
          val enabled = value != null && (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ||
            value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE))
          if (!enabled) {
            // Giving up a subscription is iOS' `didUnsubscribeFrom`, and it carries the same two
            // consequences: the link is gone, and our own advertisement can quietly have vanished behind it.
            closeLink(linkID, null)
            if (radioIsUsable() && !advertisingRequested) startAdvertising()
            return@synchronized
          }
          if (links.link(linkID) == null) {
            val link = links.open(linkID, isCentralRole = false, canSend = false)
            subscribers[linkID] = device
            delegate?.didOpen(link)
          }
          subscribers[linkID] = device
          links.completeHandshake(linkID)
          makeLinkWritable(linkID)
          drain(linkID)
        }
      }

      override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
        val linkID = linkIdOf(device) ?: return
        synchronized(lock) {
          guarded { runCatching { server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null) } }
          if (!execute) preparedWrites.remove(linkID)
        }
      }

      override fun onNotificationSent(device: BluetoothDevice, status: Int) {
        val linkID = linkIdOf(device) ?: return
        synchronized(lock) {
          if (!wantsToRun) return@synchronized
          // Android reports a status per notification but never says which bytes it belonged to, so a failed
          // one cannot be handed back to its sender the way iOS can refuse a frame up front. The gate opens
          // either way; a peer that stopped reading is closed by its own disconnect.
          makeLinkWritable(linkID)
          drain(linkID)
        }
      }

      override fun onServiceAdded(status: Int, service: BluetoothGattService) {
        synchronized(lock) {
          if (status != BluetoothGatt.GATT_SUCCESS || service.uuid != serviceUuid) return@synchronized
          servicePublished = true
          if (wantsToRun) startAdvertising()
        }
      }

      private fun linkIdOf(device: BluetoothDevice): String? =
        guarded { runCatching { device.address }.getOrNull() }?.let { peripheralLinkID(it) }
    }

  /**
   * A prepared (long) write arrives as offset chunks ending in a request that carries no value. Returns the
   * finished frame only at that final request and null until then, because forwarding the first chunk alone
   * would hand the engine half a packet — the same rule iOS' `didReceiveWrite` applies to a batch.
   */
  private fun accumulatePrepared(linkID: String, offset: Int, value: ByteArray?): ByteArray? {
    if (value == null) {
      val chunks = preparedWrites.remove(linkID) ?: return null
      val frame = ByteArray(chunks.values.sumOf { it.size })
      var at = 0
      for (chunk in chunks.values) {
        chunk.copyInto(frame, at)
        at += chunk.size
      }
      return frame
    }
    preparedWrites.getOrPut(linkID) { TreeMap() }[offset] = value
    return null
  }

  private val scanCallback =
    object : ScanCallback() {
      override fun onScanResult(callbackType: Int, result: ScanResult?) {
        if (result == null) return
        synchronized(lock) { didDiscover(result) }
      }

      override fun onBatchScanResults(results: MutableList<ScanResult>?) {
        results ?: return
        synchronized(lock) { results.forEach { didDiscover(it) } }
      }

      override fun onScanFailed(errorCode: Int) {
        synchronized(lock) {
          // `SCAN_FAILED_OUT_OF_HARDWARE` is the OEM's scans-per-window limit and
          // `SCAN_FAILED_ALREADY_STARTED` a tick that overlapped; either way the next duty step is the
          // repair, so the phase resets and the radio is left alone.
          scanRunning = false
          scanPhase = ScanPhase.PAUSED
          if (wantsToRun) armScanDuty(millisOf(config.scanOffDuration))
        }
      }
    }

  private fun didDiscover(result: ScanResult) {
    if (!wantsToRun || !radioIsUsable()) return
    // Re-checked here although the scan is filtered: a scan response can carry only part of a service list,
    // and a dial spent on a stranger is a slot a neighbour did not get.
    val uuid = serviceUuid ?: return
    val advertised = guarded { result.scanRecord?.serviceUuids } ?: return
    if (advertised.none { it.uuid == uuid }) return
    val device = guarded { runCatching { result.device }.getOrNull() } ?: return
    val address = guarded { runCatching { device.address }.getOrNull() } ?: return
    val linkID = centralLinkID(address)
    val rssi = result.rssi.coerceIn(Byte.MIN_VALUE.toInt(), Byte.MAX_VALUE.toInt()).toByte()
    if (links.link(linkID) != null) {
      links.recordRssi(rssi, linkID)
      return
    }
    // Over `maxCentralLinks`: keep nothing, spend nothing. The next duty cycle offers it again.
    if (!links.admitsCentralLink()) return
    beginDial(linkID, device)
  }

  companion object {
    private const val CENTRAL_PREFIX = "c:"
    private const val PERIPHERAL_PREFIX = "p:"

    /** The Client Characteristic Configuration descriptor — the one a central writes to subscribe. */
    private val CLIENT_CHARACTERISTIC_CONFIG: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private fun uuidOf(value: String): UUID? = runCatching { UUID.fromString(value) }.getOrNull()

    private fun millisOf(seconds: Double): Long = maxOf(0L, (seconds * 1000).toLong())
  }
}

/**
 * The platform's radio. A process without an application context, without Bluetooth, or without the
 * permissions yet reports its state and takes nothing, so the mesh UI shows a fact rather than throwing.
 */
actual fun popopxBLETransport(config: PopopxMeshConfig): PopopxBLETransporting {
  val context = AppContextProvider.getApplicationContext()
  val manager = context?.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
  return PopopxBLETransportAndroid(context, manager, config)
}
