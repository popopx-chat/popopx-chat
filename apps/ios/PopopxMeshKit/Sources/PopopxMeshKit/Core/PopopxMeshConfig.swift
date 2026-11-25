//
//  PopopxMeshConfig.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Single source of truth for the mesh's numbers. The Bluetooth values carry the name of the
//  Bitchat constant they were taken from (grep that name in
//  `/Users/elliot/popopx-chat/bitchat/bitchat/Services/TransportConfig.swift` to re-derive it);
//  the reachability and ACK timeouts are the prompt's routing rules, not Bitchat's.
//

import Foundation

public struct PopopxMeshConfig: Sendable {
    public static let `default` = PopopxMeshConfig()

    // MARK: Mesh flooding

    /// messageTTLDefault
    public var ttlDefault: UInt8 = 7
    /// bleFragmentRelayTtlCap — the TTL a relayed fragment may still carry.
    public var fragmentRelayTtlCap: UInt8 = 7
    /// bleHighDegreeThreshold — above this neighbour count, broadcast TTL gets clamped.
    public var highDegreeThreshold: Int = 6
    /// The clamp itself, denseBroadcastTtlCap in RelayController.
    public var denseBroadcastTtlCap: UInt8 = 5
    /// bleDefaultFragmentSize — the payload slice that fits one MTU after framing.
    public var fragmentSize: Int = 469
    /// bleMaxMTU
    public var maxMTU: Int = 512
    /// bleFragmentLifetimeSeconds — an assembly older than this is dropped.
    public var fragmentLifetime: TimeInterval = 30
    /// bleMaxInFlightAssemblies
    public var maxInFlightAssemblies: Int = 128
    /// bleFragmentRelayMinDelayMs / bleFragmentRelayMaxDelayMs — jitter before a relay re-floods.
    public var relayMinDelay: TimeInterval = 0.008
    public var relayMaxDelay: TimeInterval = 0.025

    // MARK: Deduplication

    /// bleRecentPacketWindowSeconds / bleRecentPacketWindowMaxCount — what a relay remembers
    /// while a flood is in flight.
    public var recentPacketWindow: TimeInterval = 30
    public var recentPacketMaxCount: Int = 100
    /// messageDedupMaxAgeSeconds / messageDedupMaxCount — the longer memory for whole messages.
    public var messageDedupMaxAge: TimeInterval = 300
    public var messageDedupMaxCount: Int = 1000

    // MARK: Discovery and presence

    /// bleDutyOnDuration / bleDutyOffDuration — the scan duty cycle on a sparse mesh.
    public var scanOnDuration: TimeInterval = 5
    public var scanOffDuration: TimeInterval = 10
    /// bleAnnounceIntervalSeconds
    public var announceInterval: TimeInterval = 4
    /// bleConnectTimeoutSeconds
    public var connectTimeout: TimeInterval = 8
    /// bleMaxCentralLinks
    public var maxCentralLinks: Int = 6
    /// bleMaintenanceInterval
    public var maintenanceInterval: TimeInterval = 5

    // MARK: POPOPX reachability and delivery rules

    /// Module 4: a peer not heard of for this long is "Bluetooth unreachable".
    public var peerReachabilityTimeout: TimeInterval = 15
    /// Module 4: an outbound Bluetooth message with no BLE_ACK this late goes to the router.
    public var bleAckTimeout: TimeInterval = 5
    /// Module 5: how long to wait for an SMP server ACK before Bluetooth is considered in parallel.
    public var smpAckTimeout: TimeInterval = 3

    // MARK: Transport identity

    /// Bitchat advertises F47B5E2D-…-8E1D2C3A4B5C. POPOPX deliberately uses its own UUID: with
    /// Bitchat's, the two apps would answer each other's connections and neither would work.
    public var serviceUUID: String = "D3A6F5A1-2C4E-4B9A-8F7D-1E2C3B4A5960"
    public var characteristicUUID: String = "B7C1D4E2-5A6F-4B3C-9D8E-0F1A2B3C4D5E"
    public var centralRestoreIdentifier: String = "chat.popopx.mesh.central"
    public var peripheralRestoreIdentifier: String = "chat.popopx.mesh.peripheral"

    /// ChaChaPoly2013 adds a 16-byte tag and POPOPX prepends the 12-byte nonce, so an encrypted
    /// frame is 28 bytes longer than its plaintext. Bitchat's transportCiphertextOverhead is 20
    /// because it derives the nonce instead of sending it.
    public var noiseTransportOverhead: Int = 28

    public init() {}
}
