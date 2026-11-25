//
//  PopopxMeshOutboundContract.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The engine's send side, described as a protocol so module 3 (pairing) and module 5 (router) can be
//  built and tested against a fake instead of a live radio.
//

import Foundation

/// Why a frame could not be handed to the mesh. Wraps the engine's own failure value so callers
/// get one thrown type while the event stream keeps the richer `PopopxMeshSendFailure`.
public struct PopopxMeshSendError: Error, Hashable, Sendable {
    public let messageId: String
    public let failure: PopopxMeshSendFailure

    public init(messageId: String, failure: PopopxMeshSendFailure) {
        self.messageId = messageId
        self.failure = failure
    }
}

public protocol PopopxMeshOutbound: Sendable {
    /// Our X25519 public key in hex. Pairing frames quote it, so the peer we answer can bind our
    /// identity without a second handshake.
    var localMeshPublicKeyHex: String { get async }

    /// Sends one envelope to one peer, over the Noise session with that peer. `throws` means the
    /// frame never reached the radio — a frame that reached the radio and went unanswered is an
    /// ACK timeout, which module 4 reports.
    func send(envelope: PopopxMeshEnvelope, to meshPublicKeyHex: String) async throws(PopopxMeshSendError)

    /// The local `#mesh` plaza: unencrypted, flooded, never acknowledged.
    func sendBroadcast(text: String) async throws(PopopxMeshSendError)
}

public extension PopopxMeshOutbound {
    /// Convenience for control frames; the id is minted here so every envelope carries one.
    func send(control frame: PopopxMeshControlFrame, to meshPublicKeyHex: String) async throws(PopopxMeshSendError) {
        let messageId = UUID().uuidString.lowercased()
        return try await send(
            envelope: PopopxMeshEnvelope.control(id: messageId, frame: frame),
            to: meshPublicKeyHex
        )
    }
}
