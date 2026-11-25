//
//  PopopxNoiseSession.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  One finished handshake per peer, plus the counters around it.
//
//  The counter travels inside every frame rather than being tracked in step on both ends: the mesh
//  floods, so two packets from one peer routinely reach the next node out of order. A counter kept
//  in step on both ends would force a fresh handshake the first time that happened. The price here
//  is 12 bytes per frame, which is what `PopopxMeshConfig.noiseTransportOverhead` accounts for.
//

import Foundation
import os

// MARK: - Replay window

/// Which side of the remembered range a peer counter falls on.
enum PopopxNoiseCounterPlacement: Hashable, Sendable {
    case accept
    case duplicate
    case tooOld
}

/// A sliding window over the peer's counters: bit `i` says whether `highest - i` has been read
/// already, so an out-of-order frame is accepted exactly once and a duplicate is not accepted at
/// all. Bitchat uses 1024 bits for the same job, which is why that is the default here too.
struct PopopxNoiseReplayWindow: Sendable {
    /// Counters the window remembers, as an offset from the highest one read. A frame at exactly
    /// `size` behind is already outside: the same boundary Bitchat's `isValidNonce` uses.
    let size: Int

    private(set) var highest: UInt64 = 0
    private(set) var hasReadAny = false
    private var bits: [UInt8]

    init(size: Int) {
        self.size = size
        bits = [UInt8](repeating: 0, count: (size + 7) / 8)
    }

    /// The lowest counter still inside the window. Reported by `counterOutsideWindow` so a log line
    /// says how far behind the peer is without leaking anything else about the session.
    var start: UInt64 {
        guard hasReadAny else { return 0 }
        let span = UInt64(size - 1)
        return highest > span ? highest - span : 0
    }

    func place(_ counter: UInt64) -> PopopxNoiseCounterPlacement {
        guard hasReadAny else { return .accept }
        if counter > highest { return .accept }
        if counter == highest { return .duplicate }
        let gap = highest - counter
        guard gap < UInt64(size) else { return .tooOld }
        return isMarked(counter) ? .duplicate : .accept
    }

    /// Records a counter as read. Call it only after the frame opened, so a forged frame cannot
    /// retire a counter the real peer has not finished sending.
    mutating func mark(_ counter: UInt64) {
        guard hasReadAny else {
            hasReadAny = true
            highest = counter
            bits[0] |= 1
            return
        }
        guard counter > highest else {
            setMark(counter)
            return
        }
        let gap = counter - highest
        if gap >= UInt64(size) {
            // Jumped past everything remembered: the window restarts empty.
            bits = [UInt8](repeating: 0, count: bits.count)
        } else {
            shift(by: Int(gap))
        }
        highest = counter
        bits[0] |= 1
    }

    // MARK: Bits

    private func isMarked(_ counter: UInt64) -> Bool {
        let offset = Int(highest - counter)
        return bits[offset / 8] & UInt8(1 << (offset % 8)) != 0
    }

    private mutating func setMark(_ counter: UInt64) {
        let offset = Int(highest - counter)
        bits[offset / 8] |= UInt8(1 << (offset % 8))
    }

    /// Moves every mark `delta` counters further from the new highest, i.e. towards higher bit
    /// positions. Done over a copy because a mark's destination can be another mark's source.
    private mutating func shift(by delta: Int) {
        let source = bits
        let byteShift = delta / 8
        let bitShift = delta % 8
        var index = bits.count - 1
        while index >= 0 {
            var value: UInt8 = 0
            let from = index - byteShift
            if from >= 0 {
                value = source[from] << bitShift
                if bitShift > 0, from > 0 {
                    value |= source[from - 1] >> (8 - bitShift)
                }
            }
            bits[index] = value
            index -= 1
        }
    }
}

// MARK: - Session

/// A peer's established Noise session: the two transport keys, the counter this side is up to, and
/// the window over the peer's. Value semantics on purpose — an actor can hand a copy to a task for
/// one encryption without any locking, and the counter it consumed comes back with the copy.
public struct PopopxNoiseSession: Sendable {
    /// Bitchat's REPLAY_WINDOW_SIZE. Mesh reordering needs more slack than a point-to-point link.
    public static let defaultReplayWindow = 1024

    /// Upper bound on the window a caller may ask for. It is allocated per peer, so an unbounded
    /// size would turn a configured number into a memory problem.
    public static let maxReplayWindow = 16_384

    /// The peer's X25519 static key. Read-only outside: a session's identity is set by the
    /// handshake that produced its keys, and nothing may be pointed at a different peer afterwards.
    public private(set) var peerPublicKey: Data
    private let send: PopopxNoiseCipherState
    private let receive: PopopxNoiseCipherState
    private var sendCounter: UInt64 = 0
    private var window: PopopxNoiseReplayWindow

    /// nil when the key material is not three 32-byte values or the window is not a usable size.
    public init?(peerPublicKey: Data, keys: PopopxNoiseTransportKeys, replayWindow: Int = 1024) {
        guard peerPublicKey.count == PopopxNoiseXXHandshake.publicKeySize else {
            PopopxMeshLog.noise.warning("Noise session refused: peer key of \(peerPublicKey.count) bytes, 32 required")
            return nil
        }
        guard replayWindow > 0, replayWindow <= PopopxNoiseSession.maxReplayWindow else {
            PopopxMeshLog.noise.warning("Noise session refused: replay window of \(replayWindow) outside 1...\(PopopxNoiseSession.maxReplayWindow)")
            return nil
        }
        guard let send = try? PopopxNoiseCipherState(key: keys.sendKey),
              let receive = try? PopopxNoiseCipherState(key: keys.receiveKey) else {
            PopopxMeshLog.noise.warning("Noise session refused: transport keys not 32 bytes")
            return nil
        }
        self.peerPublicKey = peerPublicKey
        self.send = send
        self.receive = receive
        self.window = PopopxNoiseReplayWindow(size: replayWindow)
    }

    /// The same key as the 64 hex characters the pairing frames and the mapping table use.
    public var peerMeshPublicKeyHex: String { peerPublicKey.popopxHex }

    /// Messages this side has sealed, which is what an engine watches to decide when to
    /// renegotiate.
    public var messagesSent: UInt64 { sendCounter }

    /// Where the peer's counter stands, which is the counter its next frame must carry: the highest
    /// one accepted plus one, nil before the first frame. Mirrors `messagesSent`, so an engine can
    /// compare the two and see who is behind.
    public var peerCounter: UInt64? { window.hasReadAny ? window.highest + 1 : nil }

    /// `nonce(12B) ++ ciphertext ++ tag(16B)`, so 28 bytes longer than the plaintext.
    public mutating func encrypt(_ plaintext: Data) throws -> Data {
        let counter = sendCounter
        guard counter < PopopxNoiseCipherState.messageLimit else {
            // Refused, not rekeyed: fresh keys mean a fresh handshake with the peer, and deciding
            // when to spend that round trip belongs to the engine.
            let peer = peerMeshPublicKeyHex
            PopopxMeshLog.noise.warning("Noise send counter exhausted at \(counter) for peer \(peer.prefix(8))")
            throw PopopxNoiseError.localNonceExhausted
        }
        sendCounter = counter + 1
        return try send.encrypt(plaintext, nonce: counter).frame
    }

    /// Opens a frame the caller took off the wire. The counter is checked against the window first,
    /// so a replay costs a comparison rather than an AEAD.
    public mutating func decrypt(_ frame: Data) throws -> Data {
        let counter = try PopopxNoiseCipherState.nonce(inFrame: frame)
        guard counter < PopopxNoiseCipherState.messageLimit else {
            let peer = peerMeshPublicKeyHex
            PopopxMeshLog.noise.warning("Noise peer counter \(counter) past the ceiling for \(peer.prefix(8))")
            throw PopopxNoiseError.peerNonceExhausted
        }
        // Rejections here are attacker-triggerable and can arrive at flood rate, so the lines carry
        // the counter and nothing that has to be formatted per peer.
        switch window.place(counter) {
        case .accept:
            break
        case .duplicate:
            PopopxMeshLog.noise.debug("Noise frame rejected: counter \(counter) already read")
            throw PopopxNoiseError.replayed(counter: counter)
        case .tooOld:
            let start = window.start
            PopopxMeshLog.noise.debug("Noise frame rejected: counter \(counter) older than window start \(start)")
            throw PopopxNoiseError.counterOutsideWindow(counter: counter, windowStart: start)
        }
        let plaintext = try receive.decrypt(frame, nonce: counter)
        // Marked only now: a frame that failed to open was not from the peer, and letting it retire
        // a counter would let an attacker lock out the real message that follows.
        window.mark(counter)
        return plaintext
    }
}
