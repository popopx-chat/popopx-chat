//
//  PopopxNoiseXX.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Noise_XX_25519_ChaChaPoly_SHA256, hand-written on CryptoKit. Third-party crypto is off-limits
//  here: a bundled libsodium or OpenSSL would collide with symbols already inside libpopopx.a, and
//  the Noise specification needs exactly three primitives — X25519 key agreement,
//  ChaCha20-Poly1305 and SHA-256/HMAC-SHA256 — all of which CryptoKit ships.
//
//  Reference: the Noise Protocol Framework, http://noiseprotocol.org/noise.html
//

import CryptoKit
import Foundation
import os

// MARK: - Errors

public enum PopopxNoiseError: Error, Hashable, Sendable {
    /// A protocol name other than the one this build implements was asked for. Checked before any
    /// state is created: a handshake over a mismatched name would derive keys that silently
    /// disagree with the peer's.
    case protocolNameMismatch
    case messageTooShort(bytes: Int, required: Int)
    /// The message being produced or read is not the one this role owes at this step, including a
    /// message asked for after the three-message pattern has run out. Carries the role that does
    /// own that step.
    case handshakeOutOfOrder(role: PopopxNoiseXXHandshake.Role)
    /// A key the peer sent cannot be used: wrong length, rejected by CryptoKit, or a key agreement
    /// that collapsed to the all-zero secret.
    case peerKeyUnusable
    /// Our own seed cannot be turned into a key. Reachable because
    /// `PopopxMeshIdentity(privateSeed:publicKey:)` accepts an unvalidated seed from storage.
    case localKeyUnusable
    /// The frame is not authentic: a tampered byte, a wrong key, or a nonce prefix that does not
    /// match the counter it claims.
    case decryptionFailed
    case replayed(counter: UInt64)
    /// A peer counter older than anything this session still remembers. Accepting it would need
    /// memory the window deliberately does not spend.
    case counterOutsideWindow(counter: UInt64, windowStart: UInt64)
    /// This side has used every nonce its key may seal. Re-handshaking is the only fix, and that
    /// is the engine's decision, so the session refuses rather than rekeying on its own.
    case localNonceExhausted
    /// The peer sent a counter past the ceiling it should have stopped under.
    case peerNonceExhausted
    /// A symmetric key of the wrong length reached a cipher state.
    case keyLengthInvalid(bytes: Int)
    /// Transport keys were asked for before the handshake had three messages worth of state.
    case handshakeNotComplete
}

// MARK: - Transport keys

/// The two cipher keys a finished handshake splits into, in Noise split order: `k1` encrypts
/// initiator → responder, `k2` the other way. Kept as Data so the struct crosses actors as a plain
/// value, the same reason `PopopxMeshIdentity` stores its seed as Data.
public struct PopopxNoiseTransportKeys: Sendable, Equatable {
    public let sendKey: Data
    public let receiveKey: Data

    public init?(sendKey: Data, receiveKey: Data) {
        guard sendKey.count == PopopxNoiseCipherState.keyByteCount else { return nil }
        guard receiveKey.count == PopopxNoiseCipherState.keyByteCount else { return nil }
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }
}

// MARK: - Handshake result

/// What a finished handshake gives the caller: who the peer is, the keys to talk to it with, and
/// the handshake hash, which both sides can show each other as a channel-binding short code.
public struct PopopxNoiseHandshakeResult: Sendable, Equatable {
    public let peerStaticPublicKey: Data
    public let transportKeys: PopopxNoiseTransportKeys
    public let handshakeHash: Data

    public init?(
        peerStaticPublicKey: Data,
        transportKeys: PopopxNoiseTransportKeys,
        handshakeHash: Data
    ) {
        guard peerStaticPublicKey.count == PopopxNoiseXXHandshake.publicKeySize else { return nil }
        guard handshakeHash.count == PopopxNoiseXXHandshake.publicKeySize else { return nil }
        self.peerStaticPublicKey = peerStaticPublicKey
        self.transportKeys = transportKeys
        self.handshakeHash = handshakeHash
    }
}

// MARK: - Cipher state

/// One ChaCha20-Poly1305 key plus the framing around it. Deliberately stateless about counters:
/// the nonce is an argument, so the same value can open a message the caller has already vetted
/// against its replay window, and nothing here can reuse a nonce by accident.
public struct PopopxNoiseCipherState: Sendable {
    public static let keyByteCount = 32
    public static let nonceByteCount = 12
    public static let tagByteCount = 16

    /// Bytes a transport frame carries over its plaintext: the 12-byte nonce prefix plus the
    /// 16-byte tag. Equal to `PopopxMeshConfig.noiseTransportOverhead`.
    public static let frameOverhead = nonceByteCount + tagByteCount

    /// The first counter that is refused, so one key seals 2^32 - 1 messages. Staying under 2^32
    /// keeps the counter inside the last four bytes of the prefix, which is the width the mesh's
    /// extracted-nonce framing has always carried; past it Noise requires a fresh handshake.
    public static let messageLimit: UInt64 = (1 << 32) - 1

    private let key: SymmetricKey

    public init(key: Data) throws {
        guard key.count == Self.keyByteCount else {
            PopopxMeshLog.noise.warning("Noise cipher key of \(key.count) bytes rejected, 32 required")
            throw PopopxNoiseError.keyLengthInvalid(bytes: key.count)
        }
        self.init(key: SymmetricKey(data: key))
    }

    init(key: SymmetricKey) {
        self.key = key
    }

    /// 4 zero bytes ++ the counter little-endian — the nonce Noise §12.3 specifies for ChaChaPoly
    /// ("32 bits of zeros followed by little-end encoding of n"), which is also what the mesh's
    /// extracted-nonce framing puts on the wire, so one relayed frame can be opened on its own,
    /// out of order. The frame prefix and the ChaCha20 nonce are the same 12 bytes.
    ///
    /// The encoding is not a style choice: it is mixed into the handshake transcript, because the
    /// `s` token encrypts the peer's static key. A big-endian counter opens its own frames and
    /// agrees with the spec on every Diffie-Hellman output, yet reports a different binding hash.
    static func nonceBytes(counter: UInt64) -> Data {
        var bytes = Data(capacity: Self.nonceByteCount)
        bytes.append(contentsOf: [0, 0, 0, 0])
        let littleEndian = counter.littleEndian
        withUnsafeBytes(of: littleEndian) { bytes.append(contentsOf: $0) }
        return bytes
    }

    /// The counter a nonce prefix carries, or nil when it does not start with the four zero bytes
    /// this format uses.
    static func counter(nonceBytes bytes: some DataProtocol) -> UInt64? {
        guard bytes.count == Self.nonceByteCount else { return nil }
        var cursor = bytes.startIndex
        for _ in 0..<4 {
            guard bytes[cursor] == 0 else { return nil }
            cursor = bytes.index(after: cursor)
        }
        var counter: UInt64 = 0
        for (shift, byte) in bytes.suffix(8).enumerated() {
            counter |= UInt64(byte) << (8 * shift)
        }
        return counter
    }

    /// Reads the nonce out of a wire frame without touching the ciphertext, so a session can run
    /// its replay check before spending an AEAD on the frame.
    public static func nonce(inFrame frame: some DataProtocol) throws -> UInt64 {
        guard frame.count >= Self.frameOverhead else {
            throw PopopxNoiseError.messageTooShort(bytes: frame.count, required: Self.frameOverhead)
        }
        guard let counter = counter(nonceBytes: frame.prefix(Self.nonceByteCount)) else {
            throw PopopxNoiseError.decryptionFailed
        }
        return counter
    }

    /// `frame` is `nonce(12B) ++ ciphertext ++ tag(16B)`. The tag comes back separately because a
    /// a forwarding node deduplicates on the tag's few bytes rather than re-hashing the frame.
    public func encrypt(_ plaintext: Data, nonce: UInt64) throws -> (frame: Data, tag: Data) {
        guard nonce < Self.messageLimit else {
            throw PopopxNoiseError.localNonceExhausted
        }
        let box = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: ChaChaPoly.Nonce(data: Self.nonceBytes(counter: nonce)),
            authenticating: Data()
        )
        var frame = Self.nonceBytes(counter: nonce)
        frame.append(box.ciphertext)
        frame.append(box.tag)
        return (frame, box.tag)
    }

    /// Opens a wire frame at a counter the caller has already vetted. The ChaCha20 nonce is rebuilt
    /// from that counter rather than taken from the frame, so flipping a byte in the prefix fails
    /// the tag check instead of quietly moving the frame to another nonce.
    public func decrypt(_ frame: some DataProtocol, nonce: UInt64) throws -> Data {
        guard frame.count >= Self.frameOverhead else {
            throw PopopxNoiseError.messageTooShort(bytes: frame.count, required: Self.frameOverhead)
        }
        guard nonce < Self.messageLimit else {
            throw PopopxNoiseError.peerNonceExhausted
        }
        let body = frame.dropFirst(Self.nonceByteCount)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: Self.nonceBytes(counter: nonce)),
                ciphertext: body.dropLast(Self.tagByteCount),
                tag: body.suffix(Self.tagByteCount)
            )
            return try ChaChaPoly.open(box, using: key, authenticating: Data())
        } catch {
            PopopxMeshLog.noise.debug("Noise transport frame failed to open at nonce \(nonce)")
            throw PopopxNoiseError.decryptionFailed
        }
    }

    // MARK: Handshake field format

    /// Handshake fields are bare `ciphertext ++ tag` with the handshake hash as associated data:
    /// no nonce prefix, because both sides already track the handshake nonce themselves.
    func encryptHandshakeField(_ plaintext: Data, nonce: UInt64, authenticating hash: Data) throws -> Data {
        guard nonce < Self.messageLimit else {
            throw PopopxNoiseError.localNonceExhausted
        }
        let box = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: ChaChaPoly.Nonce(data: Self.nonceBytes(counter: nonce)),
            authenticating: hash
        )
        var field = box.ciphertext
        field.append(box.tag)
        return field
    }

    func decryptHandshakeField(_ field: Data, nonce: UInt64, authenticating hash: Data) throws -> Data {
        guard field.count >= Self.tagByteCount else {
            throw PopopxNoiseError.messageTooShort(bytes: field.count, required: Self.tagByteCount)
        }
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: Self.nonceBytes(counter: nonce)),
                ciphertext: field.dropLast(Self.tagByteCount),
                tag: field.suffix(Self.tagByteCount)
            )
            return try ChaChaPoly.open(box, using: key, authenticating: hash)
        } catch {
            PopopxMeshLog.noise.debug("Noise handshake field failed to open at nonce \(nonce)")
            throw PopopxNoiseError.decryptionFailed
        }
    }
}

// MARK: - Symmetric state

/// The Noise SymmetricState object: handshake hash `h`, chaining key `ck`, and the key the message
/// fields are encrypted under. Internal, because it only ever exists inside a handshake.
struct PopopxNoiseSymmetricState {
    static let hashByteCount = 32

    private(set) var hash: Data
    private var chainingKey: Data
    private var cipher: PopopxNoiseCipherState?
    private var nonce: UInt64 = 0

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        // Spec: a name of 32 bytes or less is the initial h verbatim, zero-padded.
        // "Noise_XX_25519_ChaChaPoly_SHA256" is exactly 32, so h starts as the ASCII name itself.
        if name.count <= Self.hashByteCount {
            hash = name + Data(repeating: 0, count: Self.hashByteCount - name.count)
        } else {
            hash = Data(SHA256.hash(data: name))
        }
        chainingKey = hash
    }

    var hasKey: Bool { cipher != nil }

    mutating func mixHash(_ data: some DataProtocol) {
        var hasher = SHA256()
        hasher.update(data: hash)
        hasher.update(data: data)
        hash = Data(hasher.finalize())
    }

    /// Every MixKey also restarts the field nonce, which is why message 2's static key and message
    /// 2's payload both sit at nonce 0 while message 3's static key sits at nonce 1.
    mutating func mixKey(_ inputKeyMaterial: Data) {
        let outputs = Self.hkdf(chainingKey, inputKeyMaterial, outputs: 2)
        chainingKey = outputs[0]
        cipher = PopopxNoiseCipherState(key: SymmetricKey(data: outputs[1]))
        nonce = 0
    }

    /// Without a key the field travels in the clear and only feeds h — that is message 1 of XX.
    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let cipher else {
            mixHash(plaintext)
            return plaintext
        }
        let field = try cipher.encryptHandshakeField(plaintext, nonce: nonce, authenticating: hash)
        nonce += 1
        mixHash(field)
        return field
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let cipher else {
            mixHash(ciphertext)
            return ciphertext
        }
        let plaintext = try cipher.decryptHandshakeField(ciphertext, nonce: nonce, authenticating: hash)
        nonce += 1
        mixHash(ciphertext)
        return plaintext
    }

    /// Split into the two transport keys, then wipe what produced them. In a value type the caller
    /// may still hold a copy of the pre-split state, which is why this is an honesty measure rather
    /// than a guarantee — the handshake struct drops the reference as soon as it has the keys.
    mutating func split() -> (first: Data, second: Data) {
        let outputs = Self.hkdf(chainingKey, Data(), outputs: 2)
        chainingKey = Data(repeating: 0, count: chainingKey.count)
        hash = Data(repeating: 0, count: hash.count)
        cipher = nil
        nonce = 0
        return (outputs[0], outputs[1])
    }

    /// HKDF-SHA256 in the shape Noise uses: Extract over the chaining key, then an Expand chain of
    /// HMACs over h1 || 0x02, h2 || 0x03, so one call covers MixKey's two outputs and Split's two.
    static func hkdf(_ chainingKey: Data, _ inputKeyMaterial: Data, outputs: Int) -> [Data] {
        let tempKey = Data(
            HMAC<SHA256>.authenticationCode(for: inputKeyMaterial, using: SymmetricKey(data: chainingKey))
        )
        let expandKey = SymmetricKey(data: tempKey)
        var results: [Data] = []
        results.reserveCapacity(outputs)
        var previous = Data()
        for index in 1...outputs {
            var input = previous
            input.append(UInt8(index))
            previous = Data(HMAC<SHA256>.authenticationCode(for: input, using: expandKey))
            results.append(previous)
        }
        return results
    }
}

// MARK: - Handshake

/// One XX handshake, in one direction. The instance is spent after `finalize()`: starting a second
/// handshake with it would reuse the ephemeral key, which is the one thing that breaks forward
/// secrecy in Noise.
public struct PopopxNoiseXXHandshake: Sendable {
    public enum Role: Sendable {
        case initiator
        case responder
    }

    public static let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"
    public static let publicKeySize = 32

    /// The `s` token once a key exists: a 32-byte public key under a 16-byte tag.
    public static let encryptedPublicKeySize = publicKeySize + PopopxNoiseCipherState.tagByteCount

    private enum Token {
        case e, ee, s, es, se
    }

    /// XX exactly as the spec writes it: `-> e`, `<- e, ee, s, es`, `-> s, se`.
    private static let messagePatterns: [[Token]] = [
        [.e],
        [.e, .ee, .s, .es],
        [.s, .se],
    ]

    private let role: Role
    private let identity: PopopxMeshIdentity
    private var symmetric: PopopxNoiseSymmetricState
    /// Index of the message owed next. Even indices are spoken by the initiator, so the index alone
    /// says whose turn it is and both peers keep in step without exchanging a counter.
    private var step = 0
    private var localEphemeralSeed: Data?
    private var remoteEphemeralPublicKey: Data?
    private var remoteStaticPublicKey: Data?
    private var finalized: PopopxNoiseHandshakeResult?

    /// Test hook: pins the one ephemeral this role writes, so a handshake hash can be locked to a
    /// literal instead of re-derived from random keys. Cleared on use, so it cannot leak onward.
    var ephemeralSeedOverride: Data?

    public init(role: Role, localIdentity: PopopxMeshIdentity) {
        self.init(
            role: role,
            localIdentity: localIdentity,
            symmetric: PopopxNoiseSymmetricState(protocolName: Self.protocolName)
        )
    }

    /// The door a caller uses when the protocol name came from configuration rather than from the
    /// constant above.
    init(
        role: Role,
        localIdentity: PopopxMeshIdentity,
        protocolName: String,
        ephemeralSeed: Data? = nil
    ) throws {
        guard protocolName == PopopxNoiseXXHandshake.protocolName else {
            PopopxMeshLog.noise.warning("Noise handshake refused for \(protocolName): only XX/25519/ChaChaPoly/SHA256 is built in")
            throw PopopxNoiseError.protocolNameMismatch
        }
        self.init(
            role: role,
            localIdentity: localIdentity,
            symmetric: PopopxNoiseSymmetricState(protocolName: protocolName),
            ephemeralSeed: ephemeralSeed
        )
    }

    private init(
        role: Role,
        localIdentity: PopopxMeshIdentity,
        symmetric: PopopxNoiseSymmetricState,
        ephemeralSeed: Data? = nil
    ) {
        self.role = role
        self.identity = localIdentity
        self.symmetric = symmetric
        self.ephemeralSeedOverride = ephemeralSeed
    }

    public var isComplete: Bool { step >= Self.messagePatterns.count }

    /// Message 1 for the initiator, message 2 for the responder.
    ///
    /// - Important: message 1 is written before any key exists, so a payload passed to the
    ///   initiator's first call goes out in the clear. The mesh sends empty payloads there.
    public mutating func nextMessage(payload: Data) throws -> Data {
        try requireTurn(isReading: false)
        var buffer = Data(
            capacity: Self.publicKeySize * 2
                + payload.count
                + PopopxNoiseCipherState.tagByteCount * 2
        )
        for token in Self.messagePatterns[step] {
            try write(token, into: &buffer)
        }
        buffer.append(try symmetric.encryptAndHash(payload))
        step += 1
        return buffer
    }

    /// The peer's half of the message this role is waiting for.
    public mutating func consume(_ message: Data) throws -> (payload: Data, complete: Bool) {
        try requireTurn(isReading: true)
        let bytes = [UInt8](message)
        var offset = 0
        for token in Self.messagePatterns[step] {
            offset = try read(token, from: bytes, offset: offset)
        }
        let payload = try symmetric.decryptAndHash(Data(bytes[offset...]))
        step += 1
        return (payload, step >= Self.messagePatterns.count)
    }

    /// Transport keys plus the binding hash. Idempotent, so a caller that stored the result and
    /// asks again is handed the same one.
    public mutating func finalize() throws -> PopopxNoiseHandshakeResult {
        if let finalized { return finalized }
        guard isComplete else {
            let stalledAt = step
            PopopxMeshLog.noise.warning("Noise transport keys asked for at step \(stalledAt), handshake incomplete")
            throw PopopxNoiseError.handshakeNotComplete
        }
        guard let peerStatic = remoteStaticPublicKey else {
            // Unreachable with the XX pattern table, but the key is the identity of the peer: the
            // session must not be built on a nil where a name should be.
            PopopxMeshLog.noise.warning("Noise handshake reports complete with no peer static key")
            throw PopopxNoiseError.peerKeyUnusable
        }
        // Read before split(): split wipes the state that produced the hash, and the hash is what
        // both sides quote to each other for channel binding.
        let handshakeHash = symmetric.hash
        let (first, second) = symmetric.split()
        guard let keys = PopopxNoiseTransportKeys(
            sendKey: role == .initiator ? first : second,
            receiveKey: role == .initiator ? second : first
        ) else {
            PopopxMeshLog.noise.warning("Noise split returned keys of \(first.count)/\(second.count) bytes, 32 required")
            throw PopopxNoiseError.keyLengthInvalid(bytes: first.count)
        }
        guard let result = PopopxNoiseHandshakeResult(
            peerStaticPublicKey: peerStatic,
            transportKeys: keys,
            handshakeHash: handshakeHash
        ) else {
            PopopxMeshLog.noise.warning("Noise handshake hash of \(handshakeHash.count) bytes is not 32")
            throw PopopxNoiseError.keyLengthInvalid(bytes: handshakeHash.count)
        }
        finalized = result
        return result
    }

    // MARK: Turn taking

    private static func speaker(of step: Int) -> Role {
        step.isMultiple(of: 2) ? .initiator : .responder
    }

    private func requireTurn(isReading: Bool) throws {
        guard step < Self.messagePatterns.count else {
            PopopxMeshLog.noise.warning("Noise message asked for at step \(self.step): handshake already finished")
            throw PopopxNoiseError.handshakeOutOfOrder(role: role)
        }
        let speaker = Self.speaker(of: step)
        let speaksThisStep = role == speaker
        guard isReading ? !speaksThisStep : speaksThisStep else {
            PopopxMeshLog.noise.warning("Noise step \(self.step) belongs to \(String(describing: speaker)), not to \(String(describing: self.role))")
            throw PopopxNoiseError.handshakeOutOfOrder(role: speaker)
        }
    }

    // MARK: Tokens

    private mutating func write(_ token: Token, into buffer: inout Data) throws {
        switch token {
        case .e:
            buffer.append(try writeEphemeral())
        case .s:
            let staticPublic = identity.publicKey
            guard staticPublic.count == Self.publicKeySize else {
                PopopxMeshLog.noise.warning("Noise handshake cannot send a local public key of \(staticPublic.count) bytes")
                throw PopopxNoiseError.localKeyUnusable
            }
            buffer.append(try symmetric.encryptAndHash(staticPublic))
        case .ee, .es, .se:
            symmetric.mixKey(try sharedSecret(for: token))
        }
    }

    private mutating func read(_ token: Token, from bytes: [UInt8], offset: Int) throws -> Int {
        var cursor = offset
        switch token {
        case .e:
            let key = try Self.take(Self.publicKeySize, from: bytes, at: &cursor)
            _ = try Self.validatedPeerPublicKey(key)
            remoteEphemeralPublicKey = key
            symmetric.mixHash(key)
        case .s:
            // In messages 2 and 3 the static key arrives under the handshake cipher, so its field
            // is 16 bytes longer than the key; reading 32 would leave the tag at the payload start.
            let size = symmetric.hasKey ? Self.encryptedPublicKeySize : Self.publicKeySize
            let field = try Self.take(size, from: bytes, at: &cursor)
            let key = try symmetric.decryptAndHash(field)
            _ = try Self.validatedPeerPublicKey(key)
            remoteStaticPublicKey = key
        case .ee, .es, .se:
            symmetric.mixKey(try sharedSecret(for: token))
        }
        return cursor
    }

    /// Generates — or, under the test hook, takes — the ephemeral for this message and mixes its
    /// public half into the handshake hash.
    private mutating func writeEphemeral() throws -> Data {
        let seed: Data
        if let pinned = ephemeralSeedOverride {
            seed = pinned
            ephemeralSeedOverride = nil
        } else {
            seed = Data(Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        }
        let key = try Self.privateKey(from: seed)
        localEphemeralSeed = seed
        let publicBytes = key.publicKey.rawRepresentation
        symmetric.mixHash(publicBytes)
        return publicBytes
    }

    /// The DH each token means, with the operand order flipped by role the way the spec requires.
    private func sharedSecret(for token: Token) throws -> Data {
        let localSeed: Data?
        let peerPublic: Data?
        switch token {
        case .ee:
            localSeed = localEphemeralSeed
            peerPublic = remoteEphemeralPublicKey
        case .es:
            // Initiator: DH(ephemeral, peer static). Responder: DH(static, peer ephemeral).
            localSeed = role == .initiator ? localEphemeralSeed : identity.privateSeed
            peerPublic = role == .initiator ? remoteStaticPublicKey : remoteEphemeralPublicKey
        case .se:
            // Initiator: DH(static, peer ephemeral). Responder: DH(ephemeral, peer static).
            localSeed = role == .initiator ? identity.privateSeed : localEphemeralSeed
            peerPublic = role == .initiator ? remoteEphemeralPublicKey : remoteStaticPublicKey
        case .e, .s:
            localSeed = nil
            peerPublic = nil
        }
        guard let seed = localSeed else {
            PopopxMeshLog.noise.warning("Noise token \(String(describing: token)) asked for before its local key exists")
            throw PopopxNoiseError.localKeyUnusable
        }
        guard let peer = peerPublic else {
            PopopxMeshLog.noise.warning("Noise token \(String(describing: token)) asked for before the peer key arrived")
            throw PopopxNoiseError.peerKeyUnusable
        }
        return try Self.keyAgreement(localSeed: seed, peerPublicKey: peer)
    }

    // MARK: Key material

    private static func privateKey(from seed: Data) throws -> Curve25519.KeyAgreement.PrivateKey {
        guard seed.count == publicKeySize,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed) else {
            PopopxMeshLog.noise.warning("Noise local key unusable: seed of \(seed.count) bytes")
            throw PopopxNoiseError.localKeyUnusable
        }
        return key
    }

    static func validatedPeerPublicKey(_ data: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        guard data.count == publicKeySize else {
            PopopxMeshLog.noise.debug("Noise peer key of \(data.count) bytes rejected")
            throw PopopxNoiseError.peerKeyUnusable
        }
        // The all-zero encoding is the identity element: a DH against it says nothing about who is
        // on the other end, so it is refused rather than mixed into the keys.
        var accumulator: UInt8 = 0
        for byte in data { accumulator |= byte }
        guard accumulator != 0 else {
            PopopxMeshLog.noise.debug("Noise peer key rejected: all-zero encoding")
            throw PopopxNoiseError.peerKeyUnusable
        }
        do {
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
        } catch {
            PopopxMeshLog.noise.debug("Noise peer key rejected by CryptoKit")
            throw PopopxNoiseError.peerKeyUnusable
        }
    }

    private static func keyAgreement(localSeed: Data, peerPublicKey peer: Data) throws -> Data {
        let local = try privateKey(from: localSeed)
        let remote = try validatedPeerPublicKey(peer)
        let secret: Data
        do {
            secret = try local.sharedSecretFromKeyAgreement(with: remote).withUnsafeBytes { Data($0) }
        } catch {
            PopopxMeshLog.noise.debug("Noise key agreement refused a 32-byte peer key")
            throw PopopxNoiseError.peerKeyUnusable
        }
        // A low-order peer point makes the shared secret independent of our private key, so the
        // peer already knows it. CryptoKit's X25519 throws on the encodings it recognises as
        // degenerate; the all-zero output is checked on top of that, because a key agreement that
        // says nothing about who is on the other end is not an authenticated session.
        var accumulator: UInt8 = 0
        for byte in secret { accumulator |= byte }
        guard accumulator != 0 else {
            PopopxMeshLog.noise.debug("Noise key agreement produced an all-zero shared secret")
            throw PopopxNoiseError.peerKeyUnusable
        }
        return secret
    }

    /// Field reader over an unindexed copy of the message, so a caller's `Data` slice indices can
    /// never leak into the parse.
    private static func take(_ count: Int, from bytes: [UInt8], at cursor: inout Int) throws -> Data {
        let remaining = bytes.count - cursor
        let needed = cursor + count
        guard remaining >= count else {
            PopopxMeshLog.noise.debug("Noise handshake message of \(bytes.count) bytes truncated, \(needed) needed")
            throw PopopxNoiseError.messageTooShort(bytes: bytes.count, required: needed)
        }
        defer { cursor += count }
        return Data(bytes[cursor..<(cursor + count)])
    }
}
