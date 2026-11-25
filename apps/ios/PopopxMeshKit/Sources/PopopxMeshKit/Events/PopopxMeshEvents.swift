//
//  PopopxMeshEvents.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The only surface the mesh exposes to the POPOPX app: a value-type event stream. Nothing in
//  here imports the app, so the app-side layers (banner, router, timeline) are consumers, never
//  dependencies.
//

import Foundation

// MARK: - Radio state

public enum PopopxBluetoothState: Hashable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    public var isUsable: Bool { self == .poweredOn }
}

// MARK: - Peers

public struct PopopxMeshPeer: Hashable, Sendable {
    public let peerID: PopopxMeshPeerID
    /// The X25519 public key, once an announce or a Noise handshake has revealed it. `peerID`
    /// alone is not enough to build a session.
    public var meshPublicKey: Data?
    public var nickname: String?
    /// Hops away, measured as (origin TTL - received TTL); 0 when this radio holds the link.
    public var hopCount: Int
    public var lastSeenAt: Date
    public var rssi: Int8?
    /// True when a link of ours carries the peer, false when a neighbour relays for it.
    public var isDirect: Bool
}

// MARK: - Traffic

public struct PopopxMeshEnvelope: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text
        case control
    }

    /// Globally unique message id, minted by the sender and reused verbatim if the router later
    /// re-sends the same text over SMP. Every dedup and ACK in the system keys on this value.
    public let id: String
    public let sentAt: UInt64
    public let kind: Kind
    /// For `.control`, the frame text, e.g. `SYS_POPOPX_REQ:popopx:/contact#…`.
    public let body: String

    public init(id: String, sentAt: UInt64 = PopopxMeshPacket.nowMillis, kind: PopopxMeshEnvelope.Kind, body: String) {
        self.id = id
        self.sentAt = sentAt
        self.kind = kind
        self.body = body
    }

    public var controlFrame: PopopxMeshControlFrame? {
        kind == .control ? PopopxMeshControlFrame(body) : nil
    }

    public static func text(id: String, body: String) -> PopopxMeshEnvelope {
        PopopxMeshEnvelope(id: id, kind: .text, body: body)
    }

    public static func control(id: String, frame: PopopxMeshControlFrame) -> PopopxMeshEnvelope {
        PopopxMeshEnvelope(id: id, kind: .control, body: frame.text)
    }
}

public struct PopopxMeshInbound: Hashable, Sendable {
    public let messageId: String
    public let sender: PopopxMeshPeerID
    /// Nil until a handshake ties the 8-byte wire id to a public key.
    public let senderMeshPublicKey: Data?
    /// Nil for a broadcast.
    public let recipient: PopopxMeshPeerID?
    public let hopCount: Int
    public let isBroadcast: Bool
    public let receivedAt: Date
    public let body: PopopxMeshBody

    public var controlFrame: PopopxMeshControlFrame? {
        if case let .control(frame) = body { frame } else { nil }
    }
}

public enum PopopxMeshBody: Hashable, Sendable {
    case text(String)
    case control(PopopxMeshControlFrame)
    case binary(Data)
}

// MARK: - Events

public enum PopopxMeshSendFailure: Hashable, Sendable {
    case noLinkToPeer
    case linkDropped
    case ttlExhausted
    case oversized(payloadBytes: Int, limitBytes: Int)
    case noSessionWithPeer
    case radioUnavailable(PopopxBluetoothState)
}

public enum PopopxMeshEvent: Sendable {
    case bluetoothState(PopopxBluetoothState)
    case peerAppeared(PopopxMeshPeer)
    case peerDisappeared(PopopxMeshPeerID)
    case inbound(PopopxMeshInbound)
    /// The mesh could not put a message on the radio at all. Distinct from a Bluetooth ACK
    /// timeout, which module 4 owns: this is "never left the device".
    case sendFailed(messageId: String, peer: PopopxMeshPeerID?, reason: PopopxMeshSendFailure)
}

// MARK: - Fan-out

/// One publisher, many consumers. The engine publishes; the pairing manager, the health monitor
/// and (in phase 2) the router subscribe. A subscriber that stops iterating its stream is
/// removed when its continuation finishes, so a leaked subscription cannot stall the mesh.
public actor PopopxMeshEventHub {
    public static let shared = PopopxMeshEventHub()

    private var subscriptions: [UUID: AsyncStream<PopopxMeshEvent>.Continuation] = [:]

    public init() {}

    public func subscribe(bufferingPolicy: AsyncStream<PopopxMeshEvent>.Continuation.BufferingPolicy = .unbounded)
        -> AsyncStream<PopopxMeshEvent>
    {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PopopxMeshEvent>.makeStream(bufferingPolicy: bufferingPolicy)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        subscriptions[id] = continuation
        return stream
    }

    public func unsubscribe(_ id: UUID) {
        subscriptions[id]?.finish()
        subscriptions[id] = nil
    }

    public func publish(_ event: PopopxMeshEvent) {
        for continuation in subscriptions.values {
            continuation.yield(event)
        }
    }

    public var subscriberCount: Int { subscriptions.count }
}
