//
//  PopopxBLETransportContract.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The transport is described here as a protocol, not a class, for two reasons: the engine holds
//  it behind `any PopopxBLETransporting` so unit tests can drive the mesh with an in-memory fake,
//  and CoreBluetooth's Objective-C delegate shape forces the real implementation to be a class
//  confined to one serial queue. Everything the engine needs is async and Sendable.
//

import Foundation

/// One Bluetooth link, in either role. The transport knows nothing about mesh identity: a link
/// is a pipe, and the engine binds a link to a peer from the first packet that arrives on it.
public struct PopopxBLELink: Hashable, Sendable {
    public let linkID: UUID
    /// True when this device dialed the link (central role), false when the peer dialed us
    /// (we are the peripheral). Both directions are live on every dual-role node.
    public let isCentralRole: Bool
    /// Whether the link can take a frame right now: a writable characteristic on the central
    /// side, at least one subscriber on the peripheral side.
    public var canSend: Bool
    /// The ATT MTU the system negotiated; 23 if the peer never answered a request.
    public var negotiatedMTU: Int
    public var rssi: Int8?

    /// Public so the host target can hand a fake link to a fake transport in its own tests; the
    /// package has no other way to name a link it did not open itself.
    public init(
        linkID: UUID = UUID(),
        isCentralRole: Bool,
        canSend: Bool = false,
        negotiatedMTU: Int = 23,
        rssi: Int8? = nil
    ) {
        self.linkID = linkID
        self.isCentralRole = isCentralRole
        self.canSend = canSend
        self.negotiatedMTU = negotiatedMTU
        self.rssi = rssi
    }

    /// ATT leaves 3 bytes for the write/notify header.
    public var usablePayloadBytes: Int {
        max(20, negotiatedMTU - 3)
    }
}

public protocol PopopxBLETransportDelegate: AnyObject, Sendable {
    func bleTransport(_ transport: any PopopxBLETransporting, didUpdateState state: PopopxBluetoothState)
    /// A link is open but not yet writable.
    func bleTransport(_ transport: any PopopxBLETransporting, didOpen link: PopopxBLELink)
    /// The link can take a frame now, for the first time or after a drain.
    func bleTransport(_ transport: any PopopxBLETransporting, didBecomeWritable link: PopopxBLELink)
    func bleTransport(_ transport: any PopopxBLETransporting, didClose linkID: UUID, error: (any Error)?)
    func bleTransport(_ transport: any PopopxBLETransporting, didReceive data: Data, from linkID: UUID)
    func bleTransport(
        _ transport: any PopopxBLETransporting,
        didFailToSend data: Data,
        to linkID: UUID,
        error: (any Error)?
    )
}

public protocol PopopxBLETransporting: Sendable {
    var state: PopopxBluetoothState { get async }
    var links: [PopopxBLELink] { get async }

    /// Held weakly by the implementation: a transport must not keep its delegate alive.
    func setDelegate(_ delegate: (any PopopxBLETransportDelegate)?) async

    /// Starts scanning, advertising and connecting. Safe to call twice; does nothing while the
    /// radio is off, and reports `.poweredOff` instead.
    func start() async
    /// Stops everything and drops every link. Called by the global switch and by panic wipe.
    func stop() async

    /// Returns false when the link is unknown or closed. A true result means "handed to
    /// CoreBluetooth", not "the peer got it" — that is what the BLE ACK is for.
    func send(_ data: Data, to linkID: UUID) async -> Bool

    /// Peripheral side of a dual-role node: pushes a frame to every central subscribed to our
    /// characteristic. Used for broadcast floods we originate or relay.
    func notifySubscribers(_ data: Data) async

    func connect(to linkID: UUID) async
    func disconnect(_ linkID: UUID) async
}

public enum PopopxBLETransportError: Error, Hashable, Sendable {
    case radioOff
    case unauthorized
    case linkNotFound(UUID)
    case writeQueueFull(linkID: UUID)
    case frameTooLarge(bytes: Int, usable: Int)
}
