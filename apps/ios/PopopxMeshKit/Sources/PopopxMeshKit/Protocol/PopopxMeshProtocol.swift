//
//  PopopxMeshProtocol.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Wire format mirrors Bitchat's protocol v1 header so that the two engines could, in
//  principle, read each other's frames. Bitchat's v2 header, source routing and zlib
//  compression are deliberately not implemented: nothing in POPOPX needs them and both
//  widen the attack surface of an unauthenticated inbound parser.
//

import CryptoKit
import Foundation

// MARK: - Message types

/// The `type` byte of a mesh packet. Values are Bitchat's, minus the ones that exist only
/// to carry Nostr (0x23 boardPost, 0x28 nostrCarrier) or features outside this phase.
public enum PopopxMeshMessageType: UInt8, Sendable {
    case announce = 0x01
    case message = 0x02
    case leave = 0x03
    case noiseHandshake = 0x10
    case noiseEncrypted = 0x11
    case fragment = 0x20
    case ping = 0x26
    case pong = 0x27
    case pairingRequest = 0x30
    case pairingAck = 0x31
    case deliveryAck = 0x32

    // MARK: Private groups (0x40 and up are this package's own space)

    /// Creator-signed group state — an invite, a key rotation, a removal. Directed, and the payload
    /// is a Noise frame, so only the peer the session authenticated can read it. Bitchat carries the
    /// same thing as NoisePayloadType 0x06/0x07; giving it its own mesh type is what lets a node
    /// that is not the recipient still relay it.
    case groupState = 0x40
    /// Group traffic: flooded, outer layer deliberately unsigned (a relay never needs to know who
    /// signed it, and signing the outer frame would make the flood dedupable only by sender), and
    /// unreadable to every node that does not hold the group key. Bitchat's MessageType 0x25.
    case groupMessage = 0x41
}

// MARK: - Peer identity on the wire

/// The 8-byte sender/recipient field. Derived from the mesh public key, not chosen by the peer.
public struct PopopxMeshPeerID: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 8

    public let bytes: Data

    public init?(_ data: some DataProtocol) {
        let raw = Data(data)
        guard raw.count == Self.byteCount else { return nil }
        self.bytes = raw
    }

    /// First 8 bytes of SHA256(pubkey) — the same truncation Bitchat shows as a 16-hex peer id.
    public init(publicKey: Data) {
        let digest = SHA256.hash(data: publicKey)
        self.bytes = Data(digest.prefix(Self.byteCount))
    }

    public var u64: UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    public var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { hex }
}

// MARK: - Control frames

/// Single-token text frames. The prefix is the whole protocol: everything after the first
/// colon is the argument, and the argument may itself contain colons (an invite link does).
public enum PopopxMeshControlFrame: Hashable, Sendable {
    public static let pairingRequestPrefix = "SYS_POPOPX_REQ:"
    public static let pairingAckPrefix = "SYS_POPOPX_ACK:"
    public static let deliveryAckPrefix = "BLE_ACK:"

    case pairingRequest(inviteLink: String)
    case pairingAck(meshPublicKey: String)
    case deliveryAck(messageId: String)

    /// nil for anything that is not one of the three frames, or whose argument is unusable.
    public init?(_ text: String) {
        if text.hasPrefix(Self.pairingRequestPrefix) {
            let link = String(text.dropFirst(Self.pairingRequestPrefix.count))
            guard !link.isEmpty else { return nil }
            self = .pairingRequest(inviteLink: link)
        } else if text.hasPrefix(Self.pairingAckPrefix) {
            let key = String(text.dropFirst(Self.pairingAckPrefix.count))
            guard PopopxMeshControlFrame.isMeshPublicKey(key) else { return nil }
            self = .pairingAck(meshPublicKey: key)
        } else if text.hasPrefix(Self.deliveryAckPrefix) {
            let id = String(text.dropFirst(Self.deliveryAckPrefix.count))
            guard !id.isEmpty, id.count <= PopopxMeshControlFrame.maxArgumentLength else { return nil }
            self = .deliveryAck(messageId: id)
        } else {
            return nil
        }
    }

    public static func isMeshPublicKey(_ candidate: some StringProtocol) -> Bool {
        candidate.count == 64 && candidate.allSatisfy(\.isHexDigit)
    }

    /// An ACK id is ours (`PopopxMessageID`) and never longer; caps the attacker's string before
    /// it reaches a dictionary key.
    public static let maxArgumentLength = 128

    public var text: String {
        switch self {
        case let .pairingRequest(link): Self.pairingRequestPrefix + link
        case let .pairingAck(key): Self.pairingAckPrefix + key
        case let .deliveryAck(id): Self.deliveryAckPrefix + id
        }
    }

    public var messageType: PopopxMeshMessageType {
        switch self {
        case .pairingRequest: .pairingRequest
        case .pairingAck: .pairingAck
        case .deliveryAck: .deliveryAck
        }
    }

    public var payload: Data { Data(text.utf8) }
}

// MARK: - Packet

public struct PopopxMeshPacket: Equatable, Sendable {
    public static let headerSize = 14
    public static let signatureSize = 64

    struct Flags {
        static let hasRecipient: UInt8 = 0x01
        static let hasSignature: UInt8 = 0x02
    }

    public let version: UInt8
    public let type: UInt8
    public var ttl: UInt8
    public let timestamp: UInt64
    public let senderID: Data
    public let recipientID: Data?
    public let payload: Data
    public let signature: Data?

    public init(
        type: UInt8,
        ttl: UInt8,
        timestamp: UInt64,
        senderID: Data,
        recipientID: Data?,
        payload: Data,
        signature: Data? = nil,
        version: UInt8 = 1
    ) {
        self.version = version
        self.type = type
        self.ttl = ttl
        self.timestamp = timestamp
        self.senderID = senderID
        self.recipientID = recipientID
        self.payload = payload
        self.signature = signature
    }

    /// A broadcast carries no recipient field, or the all-ones recipient a relay uses to re-flood
    /// a packet it took in as directed. Both mean "for everyone".
    public var isBroadcast: Bool {
        guard let recipientID else { return true }
        return recipientID.count == PopopxMeshPeerID.byteCount
            && recipientID.allSatisfy { $0 == 0xFF }
    }

    /// Content-derived id used for flood deduplication: free to recompute on a relayed packet,
    /// and it changes if any relayed field changes.
    public var packetID: Data {
        var hasher = SHA256()
        hasher.update(data: [type])
        hasher.update(data: senderID)
        let stamp = timestamp.bigEndian
        withUnsafeBytes(of: stamp) { hasher.update(data: Data($0)) }
        hasher.update(data: payload)
        return Data(hasher.finalize().prefix(16))
    }

    public var senderPeerID: PopopxMeshPeerID? { PopopxMeshPeerID(senderID) }

    public var recipientPeerID: PopopxMeshPeerID? {
        if let recipientID { PopopxMeshPeerID(recipientID) } else { nil }
    }

    public var isSigned: Bool { signature != nil }

    public var decodedType: PopopxMeshMessageType? { PopopxMeshMessageType(rawValue: type) }

    /// Milliseconds since epoch, the unit the `timestamp` field carries.
    public static var nowMillis: UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - Codec

public extension PopopxMeshPacket {
    /// Traffic-analysis padding buckets, copied from Bitchat's MessagePadding.blockSizes.
    static let blockSizes: [Int] = [256, 512, 1024, 2048]

    /// nil when the packet cannot be represented: a bad version, an oversized payload, or a
    /// sender/recipient field that is neither absent nor 8 bytes.
    func encoded(padded: Bool = true) -> Data? {
        guard version == 1 else { return nil }
        guard payload.count <= Int(UInt16.max) else { return nil }
        guard senderID.count == PopopxMeshPeerID.byteCount else { return nil }
        if let recipientID, recipientID.count != PopopxMeshPeerID.byteCount { return nil }
        if let signature, signature.count != Self.signatureSize { return nil }

        var flags: UInt8 = 0
        if recipientID != nil { flags |= Flags.hasRecipient }
        if signature != nil { flags |= Flags.hasSignature }

        var data = Data(capacity: Self.headerSize + payload.count + 16)
        data.append(version)
        data.append(type)
        data.append(ttl)
        let stamp = timestamp.bigEndian
        withUnsafeBytes(of: stamp) { data.append(contentsOf: $0) }
        data.append(flags)
        data.append(UInt8((UInt16(payload.count) >> 8) & 0xFF))
        data.append(UInt8(UInt16(payload.count) & 0xFF))
        data.append(senderID)
        if let recipientID { data.append(recipientID) }
        data.append(payload)
        if let signature { data.append(signature) }

        guard padded else { return data }
        return Self.pad(data, toSize: Self.optimalBlockSize(for: data.count))
    }

    static func decode(_ data: Data) -> PopopxMeshPacket? {
        decodeExact(data) ?? decodeExact(unpad(data))
    }

    static func encode(
        _ type: PopopxMeshMessageType,
        ttl: UInt8,
        senderID: Data,
        recipientID: Data?,
        payload: Data,
        timestamp: UInt64 = nowMillis,
        padded: Bool = true
    ) -> Data? {
        let packet = PopopxMeshPacket(
            type: type.rawValue,
            ttl: ttl,
            timestamp: timestamp,
            senderID: senderID,
            recipientID: recipientID,
            payload: payload
        )
        return packet.encoded(padded: padded)
    }

    // MARK: Padding

    /// PKCS#7-style, as Bitchat does it: every pad byte equals the pad length, which is what
    /// `unpad` verifies. A request that needs more than 255 pad bytes is declined rather than
    /// faked, so a frame far below its bucket travels at its natural length.
    static func pad(_ data: Data, toSize targetSize: Int) -> Data {
        guard data.count < targetSize else { return data }
        let paddingNeeded = targetSize - data.count
        guard paddingNeeded <= 255 else { return data }
        var padded = data
        padded.append(contentsOf: [UInt8](repeating: UInt8(paddingNeeded), count: paddingNeeded))
        return padded
    }

    static func unpad(_ data: Data) -> Data {
        guard let last = data.last else { return data }
        let paddingLength = Int(last)
        guard paddingLength > 0, paddingLength <= data.count else { return data }
        let start = data.count - paddingLength
        guard data[start...].allSatisfy({ $0 == last }) else { return data }
        return Data(data[..<start])
    }

    /// Bitchat adds 16 bytes of headroom here because it pads plaintext before encryption.
    /// This engine pads the finished outer frame, so an eavesdropper already sees the ciphertext
    /// and no allowance is needed.
    static func optimalBlockSize(for size: Int) -> Int {
        for blockSize in blockSizes where size <= blockSize {
            return blockSize
        }
        return size
    }

    private static func decodeExact(_ raw: Data) -> PopopxMeshPacket? {
        guard raw.count >= headerSize + PopopxMeshPeerID.byteCount else { return nil }
        guard raw[raw.startIndex] == 1 else { return nil }

        let base = raw.startIndex
        let type = raw[base + 1]
        let ttl = raw[base + 2]
        var timestamp: UInt64 = 0
        for index in 0..<8 {
            timestamp = (timestamp << 8) | UInt64(raw[base + 3 + index])
        }
        let flags = raw[base + 11]
        let payloadLength = (Int(raw[base + 12]) << 8) | Int(raw[base + 13])

        var offset = headerSize
        guard let senderID = takeBytes(PopopxMeshPeerID.byteCount, from: raw, at: &offset) else { return nil }

        var recipientID: Data?
        if flags & Flags.hasRecipient != 0 {
            recipientID = takeBytes(PopopxMeshPeerID.byteCount, from: raw, at: &offset)
            guard recipientID != nil else { return nil }
        }

        guard let payload = takeBytes(payloadLength, from: raw, at: &offset) else { return nil }

        var signature: Data?
        if flags & Flags.hasSignature != 0 {
            signature = takeBytes(Self.signatureSize, from: raw, at: &offset)
            guard signature != nil else { return nil }
        }

        // Anything past the last field is padding; a shorter buffer than the declared payload
        // already failed above.
        return PopopxMeshPacket(
            type: type,
            ttl: ttl,
            timestamp: timestamp,
            senderID: senderID,
            recipientID: recipientID,
            payload: payload,
            signature: signature
        )
    }

    private static func takeBytes(_ count: Int, from data: Data, at offset: inout Int) -> Data? {
        let start = data.startIndex + offset
        guard count >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        return data.subdata(in: start..<(start + count))
    }
}
