//
//  PopopxMeshGroupEvents.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The group layer's own event stream, on purpose separate from `PopopxMeshEvent`. Group traffic has
//  a different lifecycle (a roster change is not a neighbour appearing) and a different consumer
//  (Cabin's group threads, not the module 4 health monitor), and adding cases to the existing enum would
//  make every app-side `switch` over mesh events a compile error in a target this package does not
//  own. One publisher, many consumers, same fan-out shape as `PopopxMeshEventHub`.
//

import Foundation

public enum PopopxMeshGroupEvent: Hashable, Sendable {
    /// Created, joined, or its roster/epoch moved. The whole group, not a delta: a consumer that
    /// missed one of these still converges on the next.
    case changed(PopopxMeshGroup)
    /// Removed locally — because the creator's signed roster no longer includes us, or because we
    /// left. `name` is carried because the timeline has nothing else to label the row with.
    case removed(groupID: Data, name: String)
    /// One decrypted, signature-verified group message, including our own echo.
    case message(PopopxMeshGroupMessage)
    /// Inbound state we refused. Surfaced so the host can say "the invite did not take" instead of
    /// leaving a silent failure; the reason is which ordered check fired.
    case stateRefused(groupIDHex: String?, reason: PopopxGroupRejection)
}

/// Why a flooded group message was dropped by a node that could see it. Not user-facing copy —
/// a log line and a test assertion, which is the difference between "the relay worked" and "the
/// member's client silently ate a message".
public enum PopopxGroupMessageRejection: String, Hashable, Sendable {
    /// We hold no group with this id: the packet is someone else's traffic and we are the relay.
    case notOurGroup
    /// The message is not under the epoch we hold, i.e. it predates our last roster change.
    case wrongEpoch
    /// The metadata is here and the Keychain key is not.
    case keyMissing
    /// AEAD or signature failure — a wrong key, a moved epoch, a tampered byte.
    case unreadable
    /// The signer is not pinned in the creator-signed roster. Key possession is not authorship.
    case senderNotInRoster
    /// Our own flood, echoed back by a neighbour.
    case selfEcho
    /// Already delivered on another path.
    case duplicate
}

public actor PopopxMeshGroupEventHub {
    public static let shared = PopopxMeshGroupEventHub()

    private var subscriptions: [UUID: AsyncStream<PopopxMeshGroupEvent>.Continuation] = [:]

    public init() {}

    public func subscribe(
        bufferingPolicy: AsyncStream<PopopxMeshGroupEvent>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<PopopxMeshGroupEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PopopxMeshGroupEvent>.makeStream(bufferingPolicy: bufferingPolicy)
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

    public func publish(_ event: PopopxMeshGroupEvent) {
        for continuation in subscriptions.values {
            continuation.yield(event)
        }
    }

    public var subscriberCount: Int { subscriptions.count }
}
