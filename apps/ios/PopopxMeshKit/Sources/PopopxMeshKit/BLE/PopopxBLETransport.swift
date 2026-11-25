//
//  PopopxBLETransport.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The dual-role CoreBluetooth transport: one serial queue, one link table, and both of Apple's
//  manager objects created on that queue so their callbacks arrive in the order the radio produced
//  them and cannot interleave with anything else.
//
//  Isolation — the single thing `@unchecked Sendable` rests on: apart from the four immutable fields
//  set in `init`, every property here is read and written on `queue` only. The managers take `queue`
//  as their delegate queue, so CoreBluetooth delivers to us *on* that queue rather than alongside it,
//  and each `PopopxBLETransporting` method lands its work there through `onQueue` instead of touching
//  state from the caller's executor.
//
//  Two mechanisms make `stop()` mean it, because cancelling a queue cannot retract a callback that has
//  already run onto it: the manager delegates are detached from inside `queue` (the one point Apple
//  guarantees no further callback will be dispatched), and every callback body re-checks `wantsToRun`,
//  which is true only between a `start()` and a `stop()` that both ran on this queue.
//

import CoreBluetooth
import Foundation
import os

/// One object holding both manager roles, so a neighbour can dial us while we dial it.
public final class PopopxBLETransport: NSObject, PopopxBLETransporting, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    /// Frames one link may hold while its radio gate is shut. Room for a couple of flooded broadcasts
    /// per neighbour and nothing more: past that the mesh should reroute rather than buffer, because a
    /// queue in front of a dead peer is a memory leak with extra steps.
    public static let queuedFramesPerLink = 64

    // MARK: Immutable

    private let queue: DispatchQueue
    private let config: PopopxMeshConfig
    private let serviceUUID: CBUUID
    private let characteristicUUID: CBUUID
    /// Link bookkeeping — writability, MTU, per-link queues, the central budget. Kept apart from this
    /// class because none of it needs CoreBluetooth, so all of it is unit-testable without a radio.
    private let linkTable: PopopxBLELinkTable

    // MARK: Queue-confined mutable state

    private weak var delegate: (any PopopxBLETransportDelegate)?
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    /// Our published characteristic. Held because `updateValue` needs the mutable instance and because
    /// state restoration hands this back rather than rebuilding it.
    private var characteristic: CBMutableCharacteristic?

    /// Peripherals we dialed that are connected, keyed by link id (which is the peer's `identifier`).
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// The writable characteristic of each dialed peer; without it a link is connected but mute.
    private var writeTargets: [UUID: CBCharacteristic] = [:]
    /// Handles kept from discovery, restoration and disconnection, so `connect(to:)` can redial a peer
    /// it has seen. CoreBluetooth will not accept a bare UUID in place of a `CBPeripheral`.
    private var dialablePeripherals: [UUID: CBPeripheral] = [:]
    /// Centrals connected to us (peripheral role), keyed by their `identifier`.
    private var centrals: [UUID: CBCentral] = [:]

    /// Connect attempts waiting on a callback. A link id is present only between `beginDial` and
    /// `didConnect` / `didFailToConnect` / close / its deadline, and each of those removes it before
    /// resuming — which is what keeps a continuation resumed exactly once and never parked.
    private var pendingConnects: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var connectDeadlines: [UUID: DispatchWorkItem] = [:]
    private var scanDutyItem: DispatchWorkItem?
    private var maintenanceItem: DispatchWorkItem?
    private enum ScanPhase { case scanning, paused }
    private var scanPhase: ScanPhase = .paused

    private var centralRoleState: CBManagerState = .unknown
    private var peripheralRoleState: CBManagerState = .unknown
    private var reportedState: PopopxBluetoothState = .unknown
    private var wantsToRun = false

    // MARK: - Life

    public init(config: PopopxMeshConfig = .default, queueLabel: String = "chat.popopx.mesh.ble") {
        self.config = config
        self.queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        self.serviceUUID = CBUUID(string: config.serviceUUID)
        self.characteristicUUID = CBUUID(string: config.characteristicUUID)
        self.linkTable = PopopxBLELinkTable(
            maxQueuedFrames: Self.queuedFramesPerLink,
            maxCentralLinks: config.maxCentralLinks,
            maxMTU: config.maxMTU
        )
        super.init()
        // Built here rather than in `start()`, and on `queue` rather than on the caller's thread: iOS
        // offers state restoration only to a process that hands it the restore identifiers at launch,
        // and a manager allocated off its own delegate queue races the first callbacks it exists to
        // receive.
        queue.sync {
            self.centralManager = CBCentralManager(
                delegate: self,
                queue: queue,
                options: [
                    CBCentralManagerOptionRestoreIdentifierKey: config.centralRestoreIdentifier,
                    CBCentralManagerOptionShowPowerAlertKey: true,
                ]
            )
            self.peripheralManager = CBPeripheralManager(
                delegate: self,
                queue: queue,
                options: [
                    CBPeripheralManagerOptionRestoreIdentifierKey: config.peripheralRestoreIdentifier,
                    CBPeripheralManagerOptionShowPowerAlertKey: true,
                ]
            )
        }
    }

    // MARK: - PopopxBLETransporting

    public var state: PopopxBluetoothState {
        get async { await onQueue { self.reportedState } }
    }

    public var links: [PopopxBLELink] {
        get async { await onQueue { self.linkTable.links } }
    }

    public func setDelegate(_ delegate: (any PopopxBLETransportDelegate)?) async {
        await onQueue { self.delegate = delegate }
    }

    public func start() async {
        await onQueue { self.begin() }
    }

    public func stop() async {
        await onQueue { self.shutDown() }
    }

    public func send(_ data: Data, to linkID: UUID) async -> Bool {
        await onQueue { self.dispatch(data, to: linkID) }
    }

    /// Peripheral-side flood: delivered link by link instead of with `onSubscribedCentrals: nil`, so
    /// one slow subscriber parks the frame in its own queue rather than making a single `updateValue`
    /// call decide that the whole flood was sent when half the neighbourhood never got it.
    public func notifySubscribers(_ data: Data) async {
        await onQueue {
            guard self.wantsToRun else { return }
            for linkID in Array(self.centrals.keys) { _ = self.dispatch(data, to: linkID) }
        }
    }

    /// Dials a peer this transport has seen. Awaits the outcome, bounded by `bleConnectTimeoutSeconds`
    /// and resolved early by `didConnect`, `didFailToConnect`, a close or a `stop()` — there is no
    /// path on which it waits for a radio event without one of those four.
    public func connect(to linkID: UUID) async {
        let writable: Bool = await withCheckedContinuation { continuation in
            self.queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                guard self.wantsToRun, self.centralRoleIsUsable, self.pendingConnects[linkID] == nil else {
                    continuation.resume(returning: false)
                    return
                }
                if self.linkTable.link(for: linkID)?.canSend == true {
                    continuation.resume(returning: true)
                    return
                }
                guard let peripheral = self.peripherals[linkID] ?? self.dialablePeripherals[linkID] else {
                    continuation.resume(returning: false)
                    return
                }
                self.pendingConnects[linkID] = continuation
                if !self.beginDial(linkID, to: peripheral) {
                    self.resumeConnect(linkID: linkID, with: false)
                }
            }
        }
        // The contract reports link state through the delegate, so the outcome is already delivered;
        // this only keeps the call from pretending success it did not get.
        if !writable {
            PopopxMeshLog.ble.debug("connect(\(linkID.uuidString.prefix(8), privacy: .public)) produced no writable link")
        }
    }

    public func disconnect(_ linkID: UUID) async {
        await onQueue {
            guard let link = self.linkTable.link(for: linkID) else { return }
            if link.isCentralRole {
                let peripheral = self.peripherals[linkID] ?? self.dialablePeripherals[linkID]
                if let peripheral, peripheral.state == .connected {
                    // `didDisconnectPeripheral` closes the link; doing it here too would report a
                    // close for a bearer the radio has not released yet.
                    self.centralManager?.cancelPeripheralConnection(peripheral)
                    return
                }
                self.closeLink(linkID, error: nil)
                return
            }
            // `CBPeripheralManager` cannot drop a central that dialed us — only the peer can close an
            // ATT bearer. Retiring our side is all this role can do, and it is enough: the engine stops
            // using the link and a peer that keeps writing reopens it.
            self.closeLink(linkID, error: nil)
        }
    }

    // MARK: - Queue bridge and radio facts

    /// Runs `operation` on the transport's queue and waits for its answer. Nothing in these operations
    /// waits on the radio, so this cannot park; the only radio-shaped continuation in the file is
    /// `connect(to:)`, and that one carries a deadline plus three early exits.
    private func onQueue<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            self.queue.async { continuation.resume(returning: operation()) }
        }
    }

    private var centralRoleIsUsable: Bool { centralRoleState == .poweredOn }
    private var peripheralRoleIsUsable: Bool { peripheralRoleState == .poweredOn }

    // MARK: - Start / stop

    private func begin() {
        guard !wantsToRun else { return }
        wantsToRun = true
        centralManager?.delegate = self
        peripheralManager?.delegate = self
        guard combinedState == .poweredOn else {
            // Safe to call twice, and a no-op while the radio is down — but say so, because the engine
            // cannot otherwise tell "starting" from "refused".
            publishState(forcing: combinedState == .unknown ? .poweredOff : combinedState)
            return
        }
        bringRadioUp()
    }

    private func bringRadioUp() {
        startScanCycle()
        publishOurService()
        // A restored characteristic comes back with its subscribers already attached, and no callback
        // tells us so; without this their links would stay invisible in the relaunched process.
        for central in characteristic?.subscribedCentrals ?? [] { registerSubscriber(central) }
        startMaintenance()
    }

    /// Either manager can be the one that finally reports `.poweredOn`, and `start()` may have run
    /// while only the other one had. Every `.poweredOn` callback therefore re-arms the radio as a
    /// whole; each step inside `bringRadioUp` is guarded on its own role and idempotent, so calling
    /// it twice costs nothing and calling it once from either delegate is enough.
    private func resumeRadioIfReady() {
        guard wantsToRun, combinedState == .poweredOn else { return }
        bringRadioUp()
    }

    private func shutDown() {
        wantsToRun = false
        cancelTimers()
        // Commands are legal only while the radio is up; on a power-off Apple rejects them as API
        // misuse, and the local teardown below is what has to carry the meaning of "stopped".
        if centralRoleIsUsable {
            centralManager?.stopScan()
            for peripheral in Array(peripherals.values) { centralManager?.cancelPeripheralConnection(peripheral) }
        }
        if peripheralRoleIsUsable {
            peripheralManager?.stopAdvertising()
        }
        dropAllLinks(error: nil)
        writeTargets.removeAll()
        dialablePeripherals.removeAll()
        characteristic = nil

        // Detached from inside `queue`, the one point at which Apple guarantees no further callback
        // will reach us. `wantsToRun` above is what catches the ones already in flight.
        centralManager?.delegate = nil
        peripheralManager?.delegate = nil
    }

    private func cancelTimers() {
        scanDutyItem?.cancel()
        scanDutyItem = nil
        scanPhase = .paused
        maintenanceItem?.cancel()
        maintenanceItem = nil
        for deadline in connectDeadlines.values { deadline.cancel() }
        connectDeadlines.removeAll()
    }

    /// The local half of a teardown: forget the handles, then report every link the table was holding.
    /// Used by `stop()` and by a radio that went down under us; a peer that merely disconnects reaches
    /// `closeLink` through its own callback.
    private func dropAllLinks(error: (any Error)?) {
        for peripheral in Array(peripherals.values) { peripheral.delegate = nil }
        peripherals.removeAll()
        centrals.removeAll()
        for outcome in linkTable.closeAll() {
            // Unconditional: a dial still in flight has a waiter parked on this link id, and the close
            // of the entry is the last moment anyone can still answer it.
            resumeConnect(linkID: outcome.link.linkID, with: false)
            reportDropped(outcome, error: error)
        }
    }

    // MARK: - Duty cycle and maintenance

    /// Scan for `bleDutyOnDuration`, rest for `bleDutyOffDuration`. Duty cycling is what lets a phone
    /// carry a mesh for hours instead of an hour; advertising keeps running through the rest phase so
    /// neighbours dialing us are not the ones paying for it.
    private func startScanCycle() {
        guard centralRoleIsUsable, wantsToRun else { return }
        scanDutyItem?.cancel()
        scanPhase = .paused
        stepScanDuty()
    }

    private func stepScanDuty() {
        guard wantsToRun, centralRoleIsUsable, let central = centralManager else { return }
        switch scanPhase {
        case .scanning:
            if central.isScanning { central.stopScan() }
            scanPhase = .paused
            armScanDuty(after: config.scanOffDuration)
        case .paused:
            scanPhase = .scanning
            central.scanForPeripherals(withServices: [serviceUUID], options: nil)
            armScanDuty(after: config.scanOnDuration)
        }
    }

    private func armScanDuty(after delay: TimeInterval) {
        scanDutyItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.stepScanDuty() }
        scanDutyItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// A liveness pass every `bleMaintenanceInterval`. iOS drops advertising when the app is
    /// backgrounded without the peripheral background mode keeping it alive, and a scan can be lost
    /// across a radio reset; those are the only failures this transport can notice from the outside,
    /// so they are the only ones this tries to repair.
    private func startMaintenance() {
        guard config.maintenanceInterval > 0 else { return }
        maintenanceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.tickMaintenance() }
        maintenanceItem = item
        queue.asyncAfter(deadline: .now() + config.maintenanceInterval, execute: item)
    }

    private func tickMaintenance() {
        guard wantsToRun else { return }
        if centralRoleIsUsable, scanDutyItem == nil { startScanCycle() }
        if peripheralRoleIsUsable, characteristic != nil, peripheralManager?.isAdvertising == false {
            PopopxMeshLog.ble.notice("advertising had stopped; restarting")
            peripheralManager?.startAdvertising(advertisementPayload)
        }
        startMaintenance()
    }

    /// Service UUID and nothing else. No local name on purpose: the bytes are needed by the service
    /// list (which is all a background scanner can read out of the overflow area anyway), and a name
    /// would tell every passer-by which app is installed on this phone.
    private var advertisementPayload: [String: Any] {
        [CBAdvertisementDataServiceUUIDsKey: [serviceUUID]]
    }

    // MARK: - Peripheral role: the GATT database

    private func publishOurService() {
        guard let peripheralManager, peripheralRoleIsUsable else { return }
        if characteristic != nil {
            // Published already, or handed back by state restoration: re-adding would clear the
            // subscriptions iOS just carefully preserved for us.
            if !peripheralManager.isAdvertising { peripheralManager.startAdvertising(advertisementPayload) }
            return
        }
        let mutable = CBMutableCharacteristic(
            type: characteristicUUID,
            // No `.read`: a readable characteristic with a nil value makes iOS ask us for one on every
            // read, and an ATT request we do not answer looks to the peer like a dead link.
            properties: [.notify, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [mutable]
        peripheralManager.removeAllServices()
        peripheralManager.add(service)
        characteristic = mutable
    }

    // MARK: - Central role: dialing

    /// Starts a connection and the clock that bounds it. Returns false when nothing was started, which
    /// the caller must treat as an immediate failure so no continuation is left waiting on a radio
    /// command that was never issued.
    @discardableResult
    private func beginDial(_ linkID: UUID, to peripheral: CBPeripheral) -> Bool {
        guard let centralManager, centralRoleIsUsable else { return false }
        if linkTable.link(for: linkID) == nil {
            _ = linkTable.open(linkID: linkID, isCentralRole: true)
        }
        linkTable.markHandshakePending(for: linkID)
        dialablePeripherals[linkID] = peripheral
        peripheral.delegate = self
        // The deadline is armed whatever happens next. A bearer that connects but never delivers a
        // characteristic is as stuck as one that never connects, and it is as expensive: it holds one
        // of `bleMaxCentralLinks`.
        armConnectDeadline(linkID, to: peripheral)
        guard peripheral.state != .connected else {
            // A restored link, or one we already held the handle for: `didConnect` is not coming, so
            // read the database here and let the discovery callbacks answer whoever is waiting.
            peripherals[linkID] = peripheral
            peripheral.discoverServices([serviceUUID])
            return true
        }
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true,
        ])
        return true
    }

    /// iOS never times a pending connect out on its own, so an unanswerable peer would hold a central
    /// slot — one of `bleMaxCentralLinks` — forever.
    private func armConnectDeadline(_ linkID: UUID, to peripheral: CBPeripheral) {
        connectDeadlines[linkID]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.wantsToRun, self.linkTable.link(for: linkID) != nil else { return }
            guard self.writeTargets[linkID] == nil else { return }
            PopopxMeshLog.ble.notice("connect deadline expired for \(linkID.uuidString.prefix(8), privacy: .public)")
            self.centralManager?.cancelPeripheralConnection(peripheral)
            self.closeLink(linkID, error: PopopxBLETransportError.linkNotFound(linkID))
        }
        connectDeadlines[linkID] = item
        queue.asyncAfter(deadline: .now() + config.connectTimeout, execute: item)
    }

    private func cancelConnectDeadline(_ linkID: UUID) {
        connectDeadlines[linkID]?.cancel()
        connectDeadlines[linkID] = nil
    }

    private func resumeConnect(linkID: UUID, with succeeded: Bool) {
        guard let continuation = pendingConnects.removeValue(forKey: linkID) else { return }
        continuation.resume(returning: succeeded)
    }

    /// Reads back what the system settled the link on. Apple exposes no ATT MTU control at all — there
    /// is no `CBATTRequestMTUMaximum` and no `didUpdateMaximumATTMTU:` in any iOS or macOS SDK; the
    /// stack negotiates the MTU by itself and reports the result only as a byte budget. Both ends of a
    /// POPOPX link are this same stack, so reading the budget is the whole of the negotiation available
    /// here, and `bleMaxMTU` is the ceiling we honour by never writing past it.
    private func readLinkMTU(of peripheral: CBPeripheral, linkID: UUID) {
        let usable = Int(peripheral.maximumWriteValueLength(for: .withoutResponse))
        guard usable > 0 else { return }
        linkTable.recordWriteBudget(usableBytes: usable, for: linkID)
    }

    // MARK: - Link events

    private func closeLink(_ linkID: UUID, error: (any Error)?) {
        cancelConnectDeadline(linkID)
        if let peripheral = peripherals.removeValue(forKey: linkID) { peripheral.delegate = nil }
        writeTargets[linkID] = nil
        centrals[linkID] = nil
        resumeConnect(linkID: linkID, with: false)
        guard let outcome = linkTable.close(linkID: linkID) else { return }
        reportDropped(outcome, error: error)
    }

    private func reportDropped(_ outcome: PopopxBLELinkTable.CloseOutcome, error: (any Error)?) {
        for frame in outcome.droppedQueuedFrames {
            delegate?.bleTransport(self, didFailToSend: frame, to: outcome.link.linkID, error: error)
        }
        delegate?.bleTransport(self, didClose: outcome.link.linkID, error: error)
    }

    /// Opens the link's gate. `setCanSend` answers nil when nothing flipped, which is how a link that
    /// was already writable avoids announcing itself writable for the tenth time.
    private func makeLinkWritable(_ linkID: UUID) {
        guard let link = linkTable.setCanSend(true, for: linkID) else { return }
        // A `connect(to:)` still waiting on this link has its answer now, and no later.
        resumeConnect(linkID: linkID, with: true)
        delegate?.bleTransport(self, didBecomeWritable: link)
    }

    // MARK: - Sending

    /// The whole send path for both roles, on `queue`: ask the table, then do what it said.
    private func dispatch(_ data: Data, to linkID: UUID) -> Bool {
        guard wantsToRun else {
            delegate?.bleTransport(self, didFailToSend: data, to: linkID, error: PopopxBLETransportError.radioOff)
            return false
        }
        switch linkTable.requestSend(data, to: linkID) {
        case let .rejected(error):
            // `.frameTooLarge` lands here, and the frame is refused whole rather than truncated.
            // Splitting a message into MTU-sized pieces is the engine's job — it owns fragment
            // lifetimes, relay TTLs and reassembly — while a transport that quietly cut a frame in
            // half would hand the peer a corrupt packet instead of an error it can act on.
            delegate?.bleTransport(self, didFailToSend: data, to: linkID, error: error)
            return false
        case .queued:
            // Accepted, not delivered: the drain for this link owns it from here.
            return true
        case let .transmit(frame):
            return putOnRadio(frame, to: linkID)
        }
    }

    /// Hands one released frame to CoreBluetooth. The frame stays counted as in flight until the radio
    /// reports the buffer drained or the link closes; that is the only acknowledgement ATT writes
    /// without response ever get.
    private func putOnRadio(_ frame: Data, to linkID: UUID) -> Bool {
        linkTable.link(for: linkID)?.isCentralRole == true
            ? writeAsCentral(frame, to: linkID)
            : notifyAsPeripheral(frame, to: linkID)
    }

    private func writeAsCentral(_ frame: Data, to linkID: UUID) -> Bool {
        guard let peripheral = peripherals[linkID], let target = writeTargets[linkID] else {
            // Connected but mute (a restored link whose services are not rediscovered yet, or a peer
            // that dropped our characteristic): the frame has no destination, so it is reported failed
            // rather than parked where nothing will ever drain it.
            linkTable.abandonFrame(linkID: linkID)
            delegate?.bleTransport(self, didFailToSend: frame, to: linkID, error: PopopxBLETransportError.linkNotFound(linkID))
            return false
        }
        // `.withoutResponse` rather than `.withResponse`: a write that demands a response costs a round
        // trip per frame and lets one lagging neighbour stall the link, and the mesh already has its own
        // ACK above this layer. Backpressure comes from `canSendWriteWithoutResponse` and the table.
        peripheral.writeValue(frame, for: target, type: .withoutResponse)
        if !peripheral.canSendWriteWithoutResponse { _ = linkTable.setCanSend(false, for: linkID) }
        return true
    }

    private func notifyAsPeripheral(_ frame: Data, to linkID: UUID) -> Bool {
        guard let characteristic, let central = centrals[linkID],
              (characteristic.subscribedCentrals ?? []).contains(where: { $0.identifier == central.identifier }),
              let peripheralManager
        else {
            // Either the peer never subscribed for notifications or our service is gone: a notification
            // to that central cannot exist, so fail the frame instead of queueing it forever.
            linkTable.abandonFrame(linkID: linkID)
            delegate?.bleTransport(self, didFailToSend: frame, to: linkID, error: PopopxBLETransportError.linkNotFound(linkID))
            return false
        }
        guard !peripheralManager.updateValue(frame, for: characteristic, onSubscribedCentrals: [central]) else {
            return true
        }
        // Refused for a full transmit queue. iOS promises
        // `peripheralManagerIsReady(toUpdateSubscribers:)` afterwards, so the frame keeps its place at
        // the head of this link's queue and the gate shuts until that call — otherwise the rest of the
        // flood would be offered to the same full buffer one frame at a time.
        if !linkTable.returnFrame(frame, to: linkID) {
            delegate?.bleTransport(self, didFailToSend: frame, to: linkID, error: PopopxBLETransportError.writeQueueFull(linkID: linkID))
        }
        _ = linkTable.setCanSend(false, for: linkID)
        return true
    }

    /// Empties a link's queue for as long as the gate is open. It stops by itself three ways: the queue
    /// runs dry, the radio shuts the gate, or the link goes away underneath us.
    private func drain(_ linkID: UUID) {
        while wantsToRun, let frame = linkTable.nextPendingFrame(linkID: linkID) {
            guard putOnRadio(frame, to: linkID) else { return }
            guard linkTable.link(for: linkID)?.canSend == true else { return }
        }
    }

    // MARK: - Receiving

    private func receive(_ data: Data, on linkID: UUID) {
        guard wantsToRun, !data.isEmpty, linkTable.link(for: linkID) != nil else { return }
        delegate?.bleTransport(self, didReceive: data, from: linkID)
    }

    // MARK: - Radio state

    private var combinedState: PopopxBluetoothState {
        Self.combinedState(central: centralRoleState, peripheral: peripheralRoleState)
    }

    private func publishState() {
        publishState(forcing: combinedState)
    }

    private func publishState(forcing state: PopopxBluetoothState) {
        guard state != reportedState else { return }
        reportedState = state
        PopopxMeshLog.ble.notice("radio state \(String(describing: state), privacy: .public)")
        delegate?.bleTransport(self, didUpdateState: state)
    }

    /// Both roles share one radio, so the state the app is shown is the most limiting of the two
    /// managers'. `.poweredOn` only when both are up: a node that can scan but cannot be dialed is not
    /// a mesh member, and the banner should not claim otherwise.
    private static func combinedState(central: CBManagerState, peripheral: CBManagerState) -> PopopxBluetoothState {
        let parts = [state(of: central), state(of: peripheral)]
        if parts.contains(.unauthorized) { return .unauthorized }
        if parts.contains(.poweredOff) { return .poweredOff }
        if parts.contains(.resetting) { return .resetting }
        if parts.contains(.unsupported) { return .unsupported }
        if parts.allSatisfy({ $0 == .poweredOn }) { return .poweredOn }
        return .unknown
    }

    private static func state(of managerState: CBManagerState) -> PopopxBluetoothState {
        switch managerState {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    /// A radio that went down below powered-off took our links with it and rejects commands about them.
    /// Tear down locally only, and let `.poweredOn` rebuild what is still wanted.
    private func handleRadioDown() {
        cancelTimers()
        dropAllLinks(error: PopopxBLETransportError.radioOff)
        writeTargets.removeAll()
        characteristic = nil
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralRoleState = central.state
        publishState()
        switch central.state {
        case .poweredOn:
            // A link restored as connected arrives without its `CBCharacteristic` objects — connected
            // but mute until this process reads the database again.
            if wantsToRun {
                for (linkID, peripheral) in Array(peripherals)
                where peripheral.state == .connected && writeTargets[linkID] == nil {
                    peripheral.delegate = self
                    peripheral.discoverServices([serviceUUID])
                }
            }
            resumeRadioIfReady()
        case .poweredOff, .unauthorized, .resetting, .unsupported:
            handleRadioDown()
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        for peripheral in restored {
            let linkID = peripheral.identifier
            peripheral.delegate = self
            dialablePeripherals[linkID] = peripheral
            guard peripheral.state == .connected else { continue }
            _ = linkTable.open(linkID: linkID, isCentralRole: true)
            linkTable.markHandshakePending(for: linkID)
            peripherals[linkID] = peripheral
            if let link = linkTable.link(for: linkID) {
                delegate?.bleTransport(self, didOpen: link)
            }
        }
        // Nothing is issued from here on a link whose services are not back: CoreBluetooth discards
        // commands sent during restoration. `.poweredOn` rediscovers them a few lines later.
        guard central.state == .poweredOn else { return }
        for (linkID, peripheral) in Array(peripherals) where writeTargets[linkID] == nil {
            peripheral.discoverServices([serviceUUID])
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard wantsToRun, centralRoleIsUsable else { return }
        // Re-checked here even though the scan is filtered: iOS answers a scan response from devices
        // that only partly match, and a dial spent on a stranger is a slot a neighbour did not get.
        guard ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).contains(serviceUUID) else { return }
        guard (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true else { return }

        let linkID = peripheral.identifier
        dialablePeripherals[linkID] = peripheral
        let rssi = Int8(clamping: RSSI.intValue)
        if linkTable.link(for: linkID) != nil {
            linkTable.record(rssi: rssi, for: linkID)
            return
        }
        // Over `bleMaxCentralLinks`: keep the handle, spend nothing. The next duty cycle offers it again.
        guard linkTable.admitsCentralLink() else { return }
        _ = beginDial(linkID, to: peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let linkID = peripheral.identifier
        guard wantsToRun, linkTable.link(for: linkID) != nil else {
            central.cancelPeripheralConnection(peripheral)
            resumeConnect(linkID: linkID, with: false)
            return
        }
        peripherals[linkID] = peripheral
        dialablePeripherals[linkID] = peripheral
        peripheral.delegate = self
        // The deadline keeps running: connected is not the same as usable, and a peer that answers
        // `connect` and then nothing else would otherwise occupy its slot forever.
        if let link = linkTable.link(for: linkID) {
            delegate?.bleTransport(self, didOpen: link)
        }
        resumeConnect(linkID: linkID, with: true)
        peripheral.discoverServices([serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        closeLink(peripheral.identifier, error: error)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        // Keep the handle: it is the cheapest way to redial this neighbour if `connect(to:)` asks
        // before the next discovery event.
        dialablePeripherals[peripheral.identifier] = peripheral
        closeLink(peripheral.identifier, error: error)
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        let linkID = peripheral.identifier
        guard wantsToRun else { return }
        guard error == nil else {
            closeLink(linkID, error: error)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            // Nothing of ours behind that advertisement — stop paying ATT traffic for it.
            centralManager?.cancelPeripheralConnection(peripheral)
            closeLink(linkID, error: nil)
            return
        }
        peripheral.discoverCharacteristics([characteristicUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        let linkID = peripheral.identifier
        guard wantsToRun else { return }
        guard error == nil else {
            closeLink(linkID, error: error)
            return
        }
        guard let target = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
            // Our service without our characteristic is not a POPOPX peer we can speak to.
            centralManager?.cancelPeripheralConnection(peripheral)
            closeLink(linkID, error: nil)
            return
        }
        writeTargets[linkID] = target
        readLinkMTU(of: peripheral, linkID: linkID)
        peripheral.setNotifyValue(true, for: target)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        let linkID = peripheral.identifier
        guard wantsToRun else { return }
        guard error == nil else {
            closeLink(linkID, error: error)
            return
        }
        guard characteristic.isNotifying else { return }
        // The negotiated MTU usually settles around subscription time, so read the budget once more.
        readLinkMTU(of: peripheral, linkID: linkID)
        _ = linkTable.completeHandshake(for: linkID)
        cancelConnectDeadline(linkID)
        makeLinkWritable(linkID)
        drain(linkID)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        let linkID = peripheral.identifier
        guard wantsToRun else { return }
        guard error == nil else {
            closeLink(linkID, error: error)
            return
        }
        guard characteristic.uuid == characteristicUUID, let value = characteristic.value else { return }
        receive(value, on: linkID)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        // Only writes without response are issued on this path, so a callback here means the peer
        // republished the characteristic with different properties. Nothing to retry; say it once.
        guard let error else { return }
        PopopxMeshLog.ble.error(
            "unexpected write error on \(peripheral.identifier.uuidString.prefix(8), privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard wantsToRun else { return }
        let linkID = peripheral.identifier
        makeLinkWritable(linkID)
        drain(linkID)
    }

    // MARK: - CBPeripheralManagerDelegate

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        peripheralRoleState = peripheral.state
        publishState()
        switch peripheral.state {
        case .poweredOn:
            resumeRadioIfReady()
        case .poweredOff, .unauthorized, .resetting, .unsupported:
            handleRadioDown()
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let services = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]) ?? []
        guard let service = services.first(where: { $0.uuid == serviceUUID }),
              let restored = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) as? CBMutableCharacteristic
        else { return }
        characteristic = restored
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        guard let error else { return }
        PopopxMeshLog.ble.error("advertising failed: \(error.localizedDescription, privacy: .public)")
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        guard wantsToRun else { return }
        if let error {
            PopopxMeshLog.ble.error("service add failed: \(error.localizedDescription, privacy: .public)")
            characteristic = nil
            return
        }
        peripheral.startAdvertising(advertisementPayload)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard wantsToRun, characteristic.uuid == characteristicUUID else { return }
        registerSubscriber(central)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == characteristicUUID else { return }
        closeLink(central.identifier, error: nil)
        // Giving up a subscriber is a moment our own advertisement can quietly vanish behind.
        if wantsToRun, peripheralRoleIsUsable, !peripheral.isAdvertising {
            peripheral.startAdvertising(advertisementPayload)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Answer ATT first: a request left hanging for a few milliseconds is a timeout at the peer,
        // whatever we end up doing with the bytes.
        for request in requests {
            peripheral.respond(to: request, withResult: .success)
        }
        guard wantsToRun, let first = requests.first else { return }
        // A prepared (long) write arrives as one batch of offset chunks that belong to a single ATT
        // payload, so concatenated in offset order they are the frame the peer wrote. Forwarding only
        // `requests.first` would deliver its first chunk and orphan the rest.
        var value = Data()
        for request in requests.sorted(by: { $0.offset < $1.offset }) {
            if let chunk = request.value { value.append(chunk) }
        }
        let linkID = first.central.identifier
        if linkTable.link(for: linkID) == nil {
            // A central can write without ever subscribing. That makes it a live link we must be able
            // to attribute traffic to, but not a writable one: notifications need a subscription.
            _ = linkTable.open(linkID: linkID, isCentralRole: false)
            centrals[linkID] = first.central
            if let link = linkTable.link(for: linkID) {
                delegate?.bleTransport(self, didOpen: link)
            }
        }
        receive(value, on: linkID)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard wantsToRun else { return }
        // Our one characteristic is shared, so a full queue is reported without naming the central that
        // caused it: open every gate that has a queue behind it and let the drains find the work. The
        // table keeps a refused frame from overtaking the ones already waiting.
        for linkID in Array(centrals.keys) {
            makeLinkWritable(linkID)
            drain(linkID)
        }
    }

    private func registerSubscriber(_ central: CBCentral) {
        let linkID = central.identifier
        if linkTable.link(for: linkID) == nil {
            _ = linkTable.open(linkID: linkID, isCentralRole: false)
            if let link = linkTable.link(for: linkID) {
                delegate?.bleTransport(self, didOpen: link)
            }
        }
        centrals[linkID] = central
        // The per-central notify budget is the ATT MTU this peer negotiated with us, header included
        // again by the table. Without it a link would sit at the 23-byte default and refuse frames the
        // peer could actually take.
        let usable = Int(central.maximumUpdateValueLength)
        if usable > 0 { linkTable.recordWriteBudget(usableBytes: usable, for: linkID) }
        _ = linkTable.completeHandshake(for: linkID)
        makeLinkWritable(linkID)
        drain(linkID)
    }
}
