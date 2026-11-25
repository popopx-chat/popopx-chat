//
//  PopopxMeshEngine.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The mesh's only façade: it owns the radio, the per-peer Noise sessions, the fragment path, the
//  flood decisions and the identity key. Everything above it — module 3 pairing, module 4 health,
//  module 5 routing — talks to either `PopopxMeshOutbound` or the event hub, never to CoreBluetooth.
//
//  Two invariants hold this file together. A peer is only ever addressed by a public key that a
//  handshake or an announce proved, never by the 8-byte wire id alone; and every packet that is
//  neither for us nor seen before is re-flooded once, with one less hop, never back out of the
//  link it came in on.
//

import Foundation

public actor PopopxMeshEngine {
    public static let shared = PopopxMeshEngine()

    private struct PeerRecord {
        let meshPublicKeyHex: String
        var peerID: PopopxMeshPeerID
        var nickname: String?
        var hopCount: Int
        var lastSeenAt: Date
        var isDirect: Bool
        var linkIDs: Set<UUID>
        var session: PopopxNoiseSession?
        var handshake: PopopxNoiseXXHandshake?
        /// When our msg1 went out, so a stalled initiator is retried instead of hanging forever.
        var handshakeStartedAt: Date?

        var peer: PopopxMeshPeer {
            PopopxMeshPeer(
                peerID: peerID,
                meshPublicKey: Data(popopxHex: meshPublicKeyHex),
                nickname: nickname,
                hopCount: hopCount,
                lastSeenAt: lastSeenAt,
                rssi: nil,
                isDirect: isDirect
            )
        }
    }

    private let config: PopopxMeshConfig
    private let transport: any PopopxBLETransporting
    private let hub: PopopxMeshEventHub
    private let secrets: any PopopxMeshSecretStoring

    private(set) public var identity: PopopxMeshIdentity

    private var peersByHex: [String: PeerRecord] = [:]
    private var meshHexByPeerID: [String: String] = [:]
    private var meshHexByLink: [UUID: String] = [:]
    /// Responder handshakes, keyed by the initiator's 8-byte wire id. Until msg3 decrypts we do not
    /// know the initiator's public key, so nothing else can index them.
    private var responders: [String: (handshake: PopopxNoiseXXHandshake, startedAt: Date)] = [:]
    private var handshakeWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private var radioState: PopopxBluetoothState = .unknown
    private var running = false
    private var maintenanceTask: Task<Void, Never>?
    private var nickname: String?
    private var lastAnnounceAt: Date?

    private var recentPackets: PopopxMeshDeduplicator
    private var fragments: PopopxMeshFragmentAssembler

    /// module 8: the private-group state machine. It does no I/O — this type is the only thing that
    /// touches the radio, and the group layer is handed bytes that already arrived.
    private let groups: PopopxGroupCoordinator

    private static let identityKeychainService = "chat.popopx.mesh.identity"
    private static let identityKeychainAccount = "noise-static-key"
    /// How far back a peer's nonce may move before a frame is called a replay.
    private static let noiseReplayWindow = PopopxNoiseSession.defaultReplayWindow

    /// Announce payload keys: our public key and the nickname we chose, advertised in the clear the
    /// way Bitchat advertises its peer id, so a neighbour can bind an 8-byte wire id to a contact
    /// before any handshake.
    public static let announcePublicKeyField = "pubkey"
    public static let announceNicknameField = "nickname"
    /// The Ed25519 signing key, in the same dictionary. This is an added *key in the JSON*, not a
    /// change to the packet or to the dictionary's shape: every reader here decodes `[String: String]`
    /// and picks the fields it knows, so a build without module 8 keeps parsing our announce exactly as
    /// before and simply does not learn our signing key. Bitchat's roster rows carry a signing key
    /// sourced from the announce for the same reason (`GroupProtocol.swift:23`).
    public static let announceSigningKeyField = "signpub"

    public init(
        config: PopopxMeshConfig = .default,
        transport: any PopopxBLETransporting = PopopxBLETransport(),
        hub: PopopxMeshEventHub = .shared,
        secrets: any PopopxMeshSecretStoring = PopopxMeshKeychain.shared,
        groupStore: PopopxGroupStore? = nil,
        groupHub: PopopxMeshGroupEventHub = .shared
    ) {
        self.config = config
        self.transport = transport
        self.hub = hub
        self.secrets = secrets
        self.recentPackets = PopopxMeshDeduplicator(config: config)
        self.fragments = PopopxMeshFragmentAssembler(
            lifetime: config.fragmentLifetime,
            maxInFlight: config.maxInFlightAssemblies
        )
        self.identity = PopopxMeshEngine.loadOrMakeIdentity(secrets: secrets)
        self.groups = PopopxGroupCoordinator(
            meshPublicKeyHex: identity.meshPublicKeyHex,
            secrets: secrets,
            store: groupStore,
            hub: groupHub
        )
    }

    // MARK: - Identity

    private static func loadOrMakeIdentity(secrets: any PopopxMeshSecretStoring) -> PopopxMeshIdentity {
        if let stored = try? secrets.data(service: identityKeychainService, account: identityKeychainAccount),
           let restored = PopopxMeshIdentity(privateSeed: stored) {
            return restored
        }
        let fresh = PopopxMeshIdentity.generate()
        do {
            try secrets.set(
                fresh.privateSeed,
                service: identityKeychainService,
                account: identityKeychainAccount
            )
        } catch {
            // A node that cannot keep its static key loses its identity at the next launch, which
            // silently invalidates every pairing bound to it. Say so; do not run a second key by
            // accident and let the two drift apart.
            PopopxMeshLog.store.error(
                "❌ mesh identity not persisted: \(String(describing: error), privacy: .public)"
            )
        }
        return fresh
    }

    public var localMeshPublicKeyHex: String { identity.meshPublicKeyHex }

    /// Panic wipe (module 7), the group half. `destroyIdentity()` cannot call this: it is synchronous
    /// and app-facing, while burning group state is an actor hop, a Keychain `removeAll` and a file
    /// removal. Kept separate so the app can burn the mesh identity alone (the existing module 7
    /// contract) and add this to the same call site.
    public func destroyGroupState() async {
        await groups.destroyAll()
    }

    /// Panic wipe (module 7) calls this after it has cleared the mapping table: the static key leaves
    /// the Keychain and memory, and every session dies with it.
    public func destroyIdentity() {
        identity = PopopxMeshIdentity.generate()
        peersByHex.removeAll()
        meshHexByPeerID.removeAll()
        meshHexByLink.removeAll()
        responders.removeAll()
        try? secrets.remove(service: Self.identityKeychainService, account: Self.identityKeychainAccount)
    }

    // MARK: - Lifecycle

    /// Opens the radio. The global switch (module 1 `meshEnabled`) is read by the host, so a Mesh that
    /// is off never leaves a manager scanning.
    public func start(nickname: String? = nil) async {
        guard !running else { return }
        running = true
        self.nickname = nickname
        await groups.setLocalNickname(nickname ?? PopopxGroupCoordinator.defaultNickname)
        await transport.setDelegate(self)
        radioState = await transport.state
        await transport.start()
        let interval = config.maintenanceInterval
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.maintain()
            }
        }
        await publish(.bluetoothState(radioState))
        PopopxMeshLog.route.notice("▶️ mesh engine up, peer \(self.identity.peerID.hex, privacy: .public)")
    }

    /// Stops everything and forgets every session: with the fuse off the app must behave exactly as
    /// the stock build, with no mesh state left in memory.
    public func stop() async {
        guard running else { return }
        running = false
        maintenanceTask?.cancel()
        maintenanceTask = nil
        await transport.stop()
        await transport.setDelegate(nil)
        peersByHex.removeAll()
        meshHexByPeerID.removeAll()
        meshHexByLink.removeAll()
        responders.removeAll()
        settleAllHandshakeWaiters()
        recentPackets = PopopxMeshDeduplicator(config: config)
        fragments = PopopxMeshFragmentAssembler(
            lifetime: config.fragmentLifetime,
            maxInFlight: config.maxInFlightAssemblies
        )
        radioState = .unknown
        PopopxMeshLog.route.notice("⏹ mesh engine down")
    }

    public var isRunning: Bool { running }

    /// What the radio is doing, for the UI's "Bluetooth unavailable" copy (module 4 rule 2).
    public var bluetoothState: PopopxBluetoothState { radioState }

    // MARK: - Outbound

    public func send(envelope: PopopxMeshEnvelope, to meshPublicKeyHex: String) async throws(PopopxMeshSendError) {
        try await send(
            plaintext: Self.encode(envelope),
            as: .noiseEncrypted,
            to: meshPublicKeyHex,
            messageId: envelope.id
        )
    }

    /// One plaintext, sealed in the Noise session with `meshPublicKeyHex` and put on the radio as
    /// `type`. Both the chat envelope (`.noiseEncrypted`) and a group state blob (`.groupState`) go
    /// through here, because the framing, the session bookkeeping and the TTL rule are the same and
    /// the last thing either of them should do is drift apart in a second copy of this code.
    private func send(
        plaintext: Data,
        as type: PopopxMeshMessageType,
        to meshPublicKeyHex: String,
        messageId: String
    ) async throws(PopopxMeshSendError) {
        guard running else {
            throw PopopxMeshSendError(messageId: messageId, failure: .radioUnavailable(radioState))
        }
        var session = try await openSession(with: meshPublicKeyHex, messageId: messageId)
        let ciphertext: Data
        do {
            ciphertext = try session.encrypt(plaintext)
        } catch {
            // The nonce space is spent, or the session was never keyed: drop it so the next send
            // re-handshakes rather than emitting frames this peer cannot read.
            peersByHex[meshPublicKeyHex]?.session = nil
            throw PopopxMeshSendError(messageId: messageId, failure: .noSessionWithPeer)
        }
        // A session is a value: its counters only move if the used copy goes back.
        peersByHex[meshPublicKeyHex]?.session = session
        guard let peer = peersByHex[meshPublicKeyHex] else {
            throw PopopxMeshSendError(messageId: messageId, failure: .noSessionWithPeer)
        }
        let packet = PopopxMeshPacket(
            type: type.rawValue,
            ttl: outboundTTL(broadcast: false),
            timestamp: PopopxMeshPacket.nowMillis,
            senderID: identity.peerID.bytes,
            recipientID: peer.peerID.bytes,
            payload: ciphertext
        )
        await deliver(packet, messageId: messageId, peer: peer, origin: nil)
        // module 4's ACK watchdog only ever sees envelope traffic: it tracks `PopopxMeshEnvelope.id`,
        // and a group state blob is not an envelope. Saying so here rather than letting a group send
        // look like it had an acknowledgement it would never receive.
        if type == .noiseEncrypted {
            await BluetoothHealthMonitor.shared.recordOutbound(
                messageId: messageId,
                peerMeshPublicKeyHex: meshPublicKeyHex,
                peerIDHex: peer.peerID.hex
            )
        }
    }

    /// The local `#mesh` plaza: unencrypted, flooded, never acknowledged.
    public func sendBroadcast(text: String) async throws(PopopxMeshSendError) {
        guard running else {
            throw PopopxMeshSendError(messageId: identity.peerID.hex, failure: .radioUnavailable(radioState))
        }
        let packet = PopopxMeshPacket(
            type: PopopxMeshMessageType.message.rawValue,
            ttl: outboundTTL(broadcast: true),
            timestamp: PopopxMeshPacket.nowMillis,
            senderID: identity.peerID.bytes,
            recipientID: nil,
            payload: Data(text.utf8)
        )
        await deliver(packet, messageId: packet.packetID.popopxHex, peer: nil, origin: nil)
    }

    /// Asks a peer to identify itself again. The reply refreshes its reachability, so a ping is how
    /// module 4's 15-second window gets evidence for a silent contact.
    public func ping(_ meshPublicKeyHex: String) async {
        guard running, let peer = peersByHex[meshPublicKeyHex] else { return }
        let nonce = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let packet = PopopxMeshPacket(
            type: PopopxMeshMessageType.ping.rawValue,
            ttl: outboundTTL(broadcast: false),
            timestamp: PopopxMeshPacket.nowMillis,
            senderID: identity.peerID.bytes,
            recipientID: peer.peerID.bytes,
            payload: nonce
        )
        await deliver(packet, messageId: packet.packetID.popopxHex, peer: peer, origin: nil)
    }

    public func peers() -> [PopopxMeshPeer] {
        peersByHex.values
            .map { record in
                PopopxMeshPeer(
                    peerID: record.peerID,
                    meshPublicKey: Data(popopxHex: record.meshPublicKeyHex),
                    nickname: record.nickname,
                    hopCount: record.hopCount,
                    lastSeenAt: record.lastSeenAt,
                    rssi: nil,
                    isDirect: record.isDirect
                )
            }
            .sorted { $0.peerID.hex < $1.peerID.hex }
    }

    public func meshPublicKeyHex(forPeerIDHex peerIDHex: String) -> String? {
        meshHexByPeerID[peerIDHex.lowercased()]
    }

    // MARK: - Sessions

    /// The Noise session with a peer, handshaking on demand: a paired contact whose link just came
    /// up is reachable the first time the router tries to send, without anyone calling
    /// `beginHandshake`.
    private func openSession(with meshPublicKeyHex: String, messageId: String) async throws(PopopxMeshSendError) -> PopopxNoiseSession {
        if let session = peersByHex[meshPublicKeyHex]?.session { return session }
        try await startHandshake(asInitiatorWith: meshPublicKeyHex, messageId: messageId)
        await waitForHandshake(toSettle: meshPublicKeyHex, timeout: config.connectTimeout)
        guard let session = peersByHex[meshPublicKeyHex]?.session else {
            throw PopopxMeshSendError(messageId: messageId, failure: .noSessionWithPeer)
        }
        return session
    }

    /// Opens a Noise_XX session with a peer whose public key we know — from a `SYS_POPOPX_*`
    /// exchange, an announce, or a previous contact. Safe to call while a handshake is in flight.
    public func beginHandshake(with meshPublicKeyHex: String) async {
        do {
            try await startHandshake(asInitiatorWith: meshPublicKeyHex, messageId: meshPublicKeyHex)
        } catch {
            PopopxMeshLog.noise.debug(
                "🚫 cannot open a session with \(meshPublicKeyHex.prefix(8), privacy: .public): \(String(describing: error.failure), privacy: .public)"
            )
        }
    }

    private func startHandshake(asInitiatorWith meshPublicKeyHex: String, messageId: String) async throws(PopopxMeshSendError) {
        guard running else {
            throw PopopxMeshSendError(messageId: messageId, failure: .radioUnavailable(radioState))
        }
        let peer = try peerRecord(named: meshPublicKeyHex, messageId: messageId)
        guard peer.session == nil, peer.handshake == nil else { return }
        var handshake = PopopxNoiseXXHandshake(role: .initiator, localIdentity: identity)
        let message: Data
        do {
            message = try handshake.nextMessage(payload: Data())
        } catch {
            PopopxMeshLog.noise.error(
                "❌ msg1 for \(meshPublicKeyHex.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw PopopxMeshSendError(messageId: messageId, failure: .noSessionWithPeer)
        }
        peersByHex[meshPublicKeyHex]?.handshake = handshake
        peersByHex[meshPublicKeyHex]?.handshakeStartedAt = .now
        let packet = PopopxMeshPacket(
            type: PopopxMeshMessageType.noiseHandshake.rawValue,
            ttl: outboundTTL(broadcast: false),
            timestamp: PopopxMeshPacket.nowMillis,
            senderID: identity.peerID.bytes,
            recipientID: peer.peerID.bytes,
            payload: message
        )
        await deliver(packet, messageId: packet.packetID.popopxHex, peer: peer, origin: nil)
    }

    /// The record for a peer named by public key, created from that key if we have never seen it.
    /// A malformed key is refused here, which is the one place a caller-supplied hex becomes mesh
    /// state, so it is also the one place it has to be checked.
    private func peerRecord(named meshPublicKeyHex: String, messageId: String) throws(PopopxMeshSendError) -> PeerRecord {
        if let known = peersByHex[meshPublicKeyHex] { return known }
        guard meshPublicKeyHex.count == PopopxMeshIdentity.keyByteCount * 2,
              let peerPublicKey = Data(popopxHex: meshPublicKeyHex) else {
            throw PopopxMeshSendError(messageId: messageId, failure: .noSessionWithPeer)
        }
        let created = PeerRecord(
            meshPublicKeyHex: meshPublicKeyHex,
            peerID: PopopxMeshPeerID(publicKey: peerPublicKey),
            nickname: nil,
            hopCount: 0,
            lastSeenAt: .now,
            isDirect: false,
            linkIDs: [],
            session: nil,
            handshake: nil,
            handshakeStartedAt: nil
        )
        peersByHex[meshPublicKeyHex] = created
        meshHexByPeerID[created.peerID.hex] = meshPublicKeyHex
        return created
    }

    private func waitForHandshake(toSettle meshPublicKeyHex: String, timeout: TimeInterval) async {
        if peersByHex[meshPublicKeyHex]?.session != nil { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            handshakeWaiters[meshPublicKeyHex, default: []].append(continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.settleHandshakeWaiters(meshPublicKeyHex)
            }
        }
    }

    /// Resumes everyone waiting on this peer. Idempotent, so a completion and its timeout racing is
    /// harmless: only the first caller finds the waiters.
    private func settleHandshakeWaiters(_ meshPublicKeyHex: String) {
        guard let waiters = handshakeWaiters.removeValue(forKey: meshPublicKeyHex) else { return }
        for waiter in waiters { waiter.resume() }
    }

    private func settleAllHandshakeWaiters() {
        for meshPublicKeyHex in handshakeWaiters.keys { settleHandshakeWaiters(meshPublicKeyHex) }
    }

    // MARK: - Delivery

    /// Puts one packet on the radio, fragmented if a link cannot take it whole. `origin` is the link
    /// the packet arrived on, for a relay: a frame is never sent back the way it came. A peer with a
    /// live link of ours gets it there and only there; anything else is flooded and dedup keeps the
    /// loops out of it.
    ///
    /// The answer is "was any frame of this packet handed to CoreBluetooth", which is what the group
    /// send path needs to report honestly: an envelope send has an ACK of its own and ignores this,
    /// a group state blob has nothing else that can tell the caller it never left the device.
    @discardableResult
    private func deliver(
        _ packet: PopopxMeshPacket,
        messageId: String,
        peer: PeerRecord?,
        origin: UUID?
    ) async -> Bool {
        guard running else {
            await publish(.sendFailed(messageId: messageId, peer: peer?.peerID, reason: .radioUnavailable(radioState)))
            return false
        }
        let links = await transport.links
        var writable = links.filter { $0.canSend && $0.linkID != origin }
        if let peer, !peer.linkIDs.isEmpty {
            let direct = writable.filter { peer.linkIDs.contains($0.linkID) }
            if !direct.isEmpty { writable = direct }
        }
        guard !writable.isEmpty else {
            await publish(.sendFailed(messageId: messageId, peer: peer?.peerID, reason: .noLinkToPeer))
            return false
        }
        guard let encoded = packet.encoded(padded: false) else {
            await publish(
                .sendFailed(
                    messageId: messageId,
                    peer: peer?.peerID,
                    reason: .oversized(payloadBytes: packet.payload.count, limitBytes: Int(UInt16.max))
                )
            )
            return false
        }
        let frames = frames(of: packet, encoded: encoded, for: writable)
        var handedOff = false
        for frame in frames {
            for link in writable {
                guard frame.count <= link.usablePayloadBytes else {
                    await publish(
                        .sendFailed(
                            messageId: messageId,
                            peer: peer?.peerID,
                            reason: .oversized(payloadBytes: frame.count, limitBytes: link.usablePayloadBytes)
                        )
                    )
                    continue
                }
                if await transport.send(frame, to: link.linkID) { handedOff = true }
            }
        }
        guard handedOff else {
            await publish(.sendFailed(messageId: messageId, peer: peer?.peerID, reason: .noLinkToPeer))
            return false
        }
        // Remember it as soon as we transmit, so our own flood coming back is dropped, and only
        // after the fragments exist, so a failed send stays retryable.
        _ = await recentPackets.note(packetID: packet.packetID)
        return true
    }

    /// One frame when the smallest link can take it, otherwise a fragment stream. The budget is the
    /// link's payload minus what every fragment packet itself carries: the fixed header plus the
    /// sender and recipient fields, which the fragmenter keeps so a relay still dedups the run.
    private func frames(of packet: PopopxMeshPacket, encoded: Data, for links: [PopopxBLELink]) -> [Data] {
        let smallest = links.map(\.usablePayloadBytes).min() ?? 0
        guard encoded.count > smallest else { return [encoded] }
        let frameOverhead = PopopxMeshPacket.headerSize + PopopxMeshPeerID.byteCount * 2
        let budget = smallest - frameOverhead
        guard budget > PopopxMeshFragmentHeader.byteCount,
              let fragments = PopopxMeshFragmenter.fragment(packet, maxPayloadBytes: budget) else {
            return [encoded]
        }
        return fragments.compactMap { $0.encoded(padded: false) }
    }

    /// A dense neighbourhood makes a full-TTL broadcast the most expensive frame in the mesh, so
    /// broadcasts are clamped the way Bitchat clamps them. Directed traffic keeps its TTL: losing
    /// hops there means losing the message.
    private func outboundTTL(broadcast: Bool) -> UInt8 {
        guard broadcast else { return config.ttlDefault }
        let neighbours = peersByHex.values.filter(\.isDirect).count
        guard neighbours > config.highDegreeThreshold else { return config.ttlDefault }
        return min(config.ttlDefault, config.denseBroadcastTtlCap)
    }

    // MARK: - Inbound

    fileprivate func receive(data: Data, linkID: UUID) async {
        guard running else { return }
        guard let packet = PopopxMeshPacket.decode(data) else {
            PopopxMeshLog.route.debug("🗑 undecodable frame from link \(linkID.uuidString.prefix(8), privacy: .public)")
            return
        }
        guard packet.senderID.count == PopopxMeshPeerID.byteCount else { return }
        if packet.senderPeerID == identity.peerID { return }
        guard await recentPackets.note(packetID: packet.packetID) else { return }

        let hopCount = max(0, Int(config.ttlDefault) - Int(packet.ttl))
        if let sender = packet.senderPeerID, let meshHex = meshHexByPeerID[sender.hex] {
            touch(meshPublicKeyHex: meshHex, hopCount: hopCount, linkID: linkID)
        }

        let isForUs = packet.isBroadcast || packet.recipientPeerID == identity.peerID
        if isForUs { await consume(packet, hopCount: hopCount, linkID: linkID) }
        await relay(packet, incoming: linkID)
    }

    private func consume(_ packet: PopopxMeshPacket, hopCount: Int, linkID: UUID) async {
        switch packet.decodedType {
        case .noiseHandshake:
            await consumeHandshake(packet, hopCount: hopCount, linkID: linkID)
        case .noiseEncrypted:
            await consumeEncrypted(packet, hopCount: hopCount, linkID: linkID)
        case .fragment:
            await consumeFragment(packet, hopCount: hopCount, linkID: linkID)
        case .announce:
            await consumeAnnounce(packet, hopCount: hopCount, linkID: linkID)
        case .message:
            await consumeBroadcastMessage(packet, hopCount: hopCount)
        case .ping:
            await consumePing(packet)
        case .pong:
            break
        case .leave:
            await consumeLeave(packet)
        case .groupState:
            await consumeGroupState(packet, hopCount: hopCount, linkID: linkID)
        case .groupMessage:
            await consumeGroupMessage(packet, hopCount: hopCount)
        case .pairingRequest, .pairingAck, .deliveryAck:
            // These ride `.noiseEncrypted`; a bare one on the wire is not ours to trust.
            PopopxMeshLog.pairing.debug("🚫 unencrypted control frame type \(packet.type, privacy: .public) ignored")
        default:
            PopopxMeshLog.route.debug("🤷 frame type \(packet.type, privacy: .public) not in this mesh")
        }
    }

    private func consumeHandshake(_ packet: PopopxMeshPacket, hopCount: Int, linkID: UUID) async {
        guard let sender = packet.senderPeerID else { return }
        let knownMeshPublicKeyHex = meshHexByPeerID[sender.hex]
        if packet.recipientPeerID == identity.peerID,
           let meshHex = knownMeshPublicKeyHex,
           var handshake = peersByHex[meshHex]?.handshake {
            // We sent msg1: this is msg2, or the msg3 of a session the peer opened with us.
            let reply: (payload: Data, complete: Bool)
            do {
                reply = try handshake.consume(packet.payload)
            } catch {
                peersByHex[meshHex]?.handshake = nil
                peersByHex[meshHex]?.handshakeStartedAt = nil
                settleHandshakeWaiters(meshHex)
                PopopxMeshLog.noise.warning(
                    "🚫 handshake from \(meshHex.prefix(8), privacy: .public) aborted: \(String(describing: error), privacy: .public)"
                )
                return
            }
            await apply(
                reply,
                handshake: handshake,
                from: sender,
                knownMeshPublicKeyHex: meshHex,
                hopCount: hopCount,
                linkID: linkID
            )
            return
        }
        // msg1, from a peer we have never named: we are the responder, and the initiator's public key
        // is not knowable yet, because msg1 carries no identity at all.
        var responder = PopopxNoiseXXHandshake(role: .responder, localIdentity: identity)
        let reply: (payload: Data, complete: Bool)
        do {
            reply = try responder.consume(packet.payload)
        } catch {
            PopopxMeshLog.noise.warning(
                "🚫 handshake msg from \(sender.hex, privacy: .public) rejected: \(String(describing: error), privacy: .public)"
            )
            return
        }
        if reply.complete {
            responders[sender.hex] = nil
        } else {
            responders[sender.hex] = (handshake: responder, startedAt: .now)
        }
        await apply(
            reply,
            handshake: responder,
            from: sender,
            knownMeshPublicKeyHex: knownMeshPublicKeyHex,
            hopCount: hopCount,
            linkID: linkID
        )
    }

    /// Applies one handshake step: sends whatever the handshake produced, keeps the in-flight state
    /// for the peer it belongs to, and installs the session once the peer's static key is proven.
    private func apply(
        _ reply: (payload: Data, complete: Bool),
        handshake: PopopxNoiseXXHandshake,
        from sender: PopopxMeshPeerID,
        knownMeshPublicKeyHex: String?,
        hopCount: Int,
        linkID: UUID
    ) async {
        if !reply.complete, let knownMeshPublicKeyHex, peersByHex[knownMeshPublicKeyHex]?.session == nil {
            // A struct: this copy carries the state the next message needs, so it has to be kept
            // rather than dropped on return.
            peersByHex[knownMeshPublicKeyHex]?.handshake = handshake
        }
        if !reply.payload.isEmpty {
            let packet = PopopxMeshPacket(
                type: PopopxMeshMessageType.noiseHandshake.rawValue,
                ttl: outboundTTL(broadcast: false),
                timestamp: PopopxMeshPacket.nowMillis,
                senderID: identity.peerID.bytes,
                recipientID: sender.bytes,
                payload: reply.payload
            )
            await deliverKnownPeer(packet, messageId: packet.packetID.popopxHex, peerIDHex: sender.hex, on: linkID)
        }
        guard reply.complete else { return }
        responders[sender.hex] = nil
        var finished = handshake
        let result: PopopxNoiseHandshakeResult
        do {
            result = try finished.finalize()
        } catch {
            PopopxMeshLog.noise.error(
                "🚫 handshake completed but keys are unusable: \(String(describing: error), privacy: .public)"
            )
            if let knownMeshPublicKeyHex {
                peersByHex[knownMeshPublicKeyHex]?.handshake = nil
                peersByHex[knownMeshPublicKeyHex]?.handshakeStartedAt = nil
                settleHandshakeWaiters(knownMeshPublicKeyHex)
            }
            return
        }
        guard let session = PopopxNoiseSession(
            peerPublicKey: result.peerStaticPublicKey,
            keys: result.transportKeys,
            replayWindow: Self.noiseReplayWindow
        ) else {
            PopopxMeshLog.noise.error("🚫 transport keys rejected by the session")
            return
        }
        let meshHex = result.peerStaticPublicKey.popopxHex
        let derived = PopopxMeshPeerID(publicKey: result.peerStaticPublicKey)
        guard derived == sender else {
            // The key that came out of the handshake does not hash to the id on the wire, so this is
            // not the peer it claims to be. No session is stored under either name.
            PopopxMeshLog.noise.error("🚫 handshake identity mismatch: \(derived.hex, privacy: .public) vs \(sender.hex, privacy: .public)")
            settleHandshakeWaiters(knownMeshPublicKeyHex ?? meshHex)
            return
        }
        var record = peersByHex[meshHex] ?? PeerRecord(
            meshPublicKeyHex: meshHex,
            peerID: derived,
            nickname: nil,
            hopCount: hopCount,
            lastSeenAt: .now,
            isDirect: false,
            linkIDs: [],
            session: nil,
            handshake: nil,
            handshakeStartedAt: nil
        )
        record.session = session
        record.handshake = nil
        record.handshakeStartedAt = nil
        touch(hopCount: hopCount, linkID: linkID, into: &record)
        peersByHex[meshHex] = record
        meshHexByPeerID[derived.hex] = meshHex
        await publish(.peerAppeared(record.peer))
        settleHandshakeWaiters(meshHex)
        if let previous = knownMeshPublicKeyHex, previous != meshHex { settleHandshakeWaiters(previous) }
        PopopxMeshLog.noise.notice("🔐 session up with \(meshHex.prefix(8), privacy: .public)")
    }

    private func deliverKnownPeer(
        _ packet: PopopxMeshPacket,
        messageId: String,
        peerIDHex: String,
        on linkID: UUID?
    ) async {
        if let meshHex = meshHexByPeerID[peerIDHex] {
            await deliver(packet, messageId: messageId, peer: peersByHex[meshHex], origin: nil)
            return
        }
        let links = await transport.links
        let targets = links.filter { link in
            link.canSend && (linkID == nil || link.linkID == linkID)
        }
        guard let data = packet.encoded(padded: false),
              targets.contains(where: { data.count <= $0.usablePayloadBytes }) else {
            await publish(.sendFailed(messageId: messageId, peer: PopopxMeshPeerID(packet.senderID), reason: .noLinkToPeer))
            return
        }
        for link in targets where data.count <= link.usablePayloadBytes {
            _ = await transport.send(data, to: link.linkID)
        }
        _ = await recentPackets.note(packetID: packet.packetID)
    }

    private func consumeEncrypted(_ packet: PopopxMeshPacket, hopCount: Int, linkID: UUID) async {
        guard let sender = packet.senderPeerID,
              let meshHex = meshHexByPeerID[sender.hex],
              var session = peersByHex[meshHex]?.session else {
            PopopxMeshLog.noise.debug("🚫 encrypted frame with no session from \(packet.senderID.popopxHex.prefix(16), privacy: .public)")
            return
        }
        guard packet.recipientPeerID == identity.peerID else {
            // Directed at someone else: module 4 must not credit a neighbour for traffic that was not
            // ours, and we cannot read it anyway.
            return
        }
        let plaintext: Data
        do {
            plaintext = try session.decrypt(packet.payload)
        } catch {
            PopopxMeshLog.noise.warning(
                "🚫 replay or tampering from \(meshHex.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }
        // A session is a value: the receiver's counter and replay window only move if the copy that
        // just decrypted goes back, or the next frame would be checked against a stale window.
        peersByHex[meshHex]?.session = session
        touch(meshPublicKeyHex: meshHex, hopCount: hopCount, linkID: linkID)
        guard let envelope = Self.decodeEnvelope(plaintext) else {
            PopopxMeshLog.route.debug("🗑 undecodable envelope from \(meshHex.prefix(8), privacy: .public)")
            return
        }
        let body: PopopxMeshBody
        switch envelope.kind {
        case .text:
            body = .text(envelope.body)
        case .control:
            guard let frame = PopopxMeshControlFrame(envelope.body) else {
                PopopxMeshLog.pairing.debug("🚫 unknown control frame from \(meshHex.prefix(8), privacy: .public)")
                return
            }
            body = .control(frame)
        }
        await publish(
            .inbound(
                PopopxMeshInbound(
                    messageId: envelope.id,
                    sender: sender,
                    senderMeshPublicKey: Data(popopxHex: meshHex),
                    recipient: packet.recipientPeerID,
                    hopCount: hopCount,
                    isBroadcast: false,
                    receivedAt: .now,
                    body: body
                )
            )
        )
        // Everything we can read and that is not itself an acknowledgement gets acknowledged:
        // module 4's 5-second guard is waiting on exactly this reply.
        if case let .control(frame) = body, case .deliveryAck = frame { return }
        await acknowledge(messageId: envelope.id, to: meshHex)
    }

    /// `BLE_ACK:<messageId>`, back over the same session the message came in on.
    private func acknowledge(messageId: String, to meshPublicKeyHex: String) async {
        guard running, messageId.count <= PopopxMeshControlFrame.maxArgumentLength else { return }
        let frame = PopopxMeshControlFrame.deliveryAck(messageId: messageId)
        guard var record = peersByHex[meshPublicKeyHex], var session = record.session else { return }
        let envelope = PopopxMeshEnvelope.control(
            id: UUID().uuidString.lowercased(),
            frame: frame
        )
        let ciphertext: Data
        do {
            ciphertext = try session.encrypt(Self.encode(envelope))
        } catch {
            return
        }
        // The acknowledgement's nonce is spent whether or not the radio takes it, so the advanced
        // session goes back before anything else.
        peersByHex[meshPublicKeyHex]?.session = session
        record.session = session
        let packet = PopopxMeshPacket(
            type: PopopxMeshMessageType.noiseEncrypted.rawValue,
            ttl: outboundTTL(broadcast: false),
            timestamp: PopopxMeshPacket.nowMillis,
            senderID: identity.peerID.bytes,
            recipientID: record.peerID.bytes,
            payload: ciphertext
        )
        await deliver(packet, messageId: packet.packetID.popopxHex, peer: record, origin: nil)
    }

    private func consumeFragment(_ packet: PopopxMeshPacket, hopCount: Int, linkID: UUID) async {
        guard packet.isBroadcast || packet.recipientPeerID == identity.peerID else { return }
        guard case .complete(_, let originalType, let payload)? = await fragments.append(packet) else { return }
        guard originalType != PopopxMeshMessageType.fragment.rawValue,
              originalType != PopopxMeshMessageType.noiseHandshake.rawValue else {
            // A stream that reassembles into another fragment, or into a handshake we would feed to
            // the cipher, is a wrapper loop. A node cannot name our handshake messages for us.
            PopopxMeshLog.route.debug("🚫 fragment stream reassembles to type \(originalType, privacy: .public)")
            return
        }
        // The fragmenter repeats the sender, recipient, timestamp, TTL and signature on every piece,
        // so the finished payload needs no second frame to become a packet.
        let inner = PopopxMeshPacket(
            type: originalType,
            ttl: packet.ttl,
            timestamp: packet.timestamp,
            senderID: packet.senderID,
            recipientID: packet.recipientID,
            payload: payload,
            signature: packet.signature,
            version: packet.version
        )
        guard inner.senderPeerID != identity.peerID else { return }
        guard await recentPackets.note(packetID: inner.packetID) else { return }
        await consume(inner, hopCount: hopCount, linkID: linkID)
    }

    private func consumeAnnounce(_ packet: PopopxMeshPacket, hopCount: Int, linkID: UUID) async {
        guard let sender = packet.senderPeerID,
              let fields = try? JSONDecoder().decode([String: String].self, from: packet.payload),
              let keyHex = fields[Self.announcePublicKeyField],
              keyHex.count == PopopxMeshIdentity.keyByteCount * 2,
              let peerPublicKey = Data(popopxHex: keyHex),
              PopopxMeshPeerID(publicKey: peerPublicKey) == sender else {
            return
        }
        let meshHex = peerPublicKey.popopxHex
        var record = peersByHex[meshHex] ?? PeerRecord(
            meshPublicKeyHex: meshHex,
            peerID: sender,
            nickname: nil,
            hopCount: hopCount,
            lastSeenAt: .now,
            isDirect: false,
            linkIDs: [],
            session: nil,
            handshake: nil,
            handshakeStartedAt: nil
        )
        record.nickname = fields[Self.announceNicknameField] ?? record.nickname
        touch(hopCount: hopCount, linkID: linkID, into: &record)
        peersByHex[meshHex] = record
        meshHexByPeerID[sender.hex] = meshHex
        // module 8: the same key-by-key read the announce already does. A peer whose announce carries
        // no `signpub` — an older build, or one that has not started its group layer — is simply not
        // invitable into a group yet, and `invite` reports that rather than guessing a key.
        if let signingHex = fields[Self.announceSigningKeyField] {
            await groups.recordPeer(
                meshPublicKeyHex: meshHex,
                signingPublicKeyHex: signingHex,
                nickname: fields[Self.announceNicknameField]
            )
        }
        await publish(.peerAppeared(record.peer))
    }

    private func consumeBroadcastMessage(_ packet: PopopxMeshPacket, hopCount: Int) async {
        guard let sender = packet.senderPeerID, packet.isBroadcast else { return }
        await publish(
            .inbound(
                PopopxMeshInbound(
                    messageId: packet.packetID.popopxHex,
                    sender: sender,
                    senderMeshPublicKey: meshHexByPeerID[sender.hex].flatMap { Data(popopxHex: $0) },
                    recipient: nil,
                    hopCount: hopCount,
                    isBroadcast: true,
                    receivedAt: .now,
                    body: .text(String(decoding: packet.payload, as: UTF8.self))
                )
            )
        )
    }

    private func consumePing(_ packet: PopopxMeshPacket) async {
        guard let sender = packet.senderPeerID, packet.recipientPeerID == identity.peerID else { return }
        let packet = PopopxMeshPacket(
            type: PopopxMeshMessageType.pong.rawValue,
            ttl: outboundTTL(broadcast: false),
            timestamp: PopopxMeshPacket.nowMillis,
            senderID: identity.peerID.bytes,
            recipientID: sender.bytes,
            payload: packet.payload
        )
        await deliverKnownPeer(packet, messageId: packet.packetID.popopxHex, peerIDHex: sender.hex, on: nil)
    }

    private func consumeLeave(_ packet: PopopxMeshPacket) async {
        guard let sender = packet.senderPeerID, let meshHex = meshHexByPeerID[sender.hex] else { return }
        forget(meshHex)
        await publish(.peerDisappeared(sender))
    }

    // MARK: - Relay

    /// The flood: TTL 7 hops, never back out of the ingress link, never twice the same packet, and
    /// jittered so that two neighbours that heard the frame at once do not collide on the link.
    private func relay(_ packet: PopopxMeshPacket, incoming linkID: UUID) async {
        guard packet.ttl > 1 else {
            // A frame that dies at our door is not a delivery failure of ours: module 4 owns that
            // verdict for traffic we sent, and this traffic belongs to someone else.
            PopopxMeshLog.route.debug(
                "⏳ ttl spent, \(packet.decodedType.map { String($0.rawValue) } ?? "?", privacy: .public) not forwarded"
            )
            return
        }
        var forwarded = packet
        forwarded.ttl = packet.ttl - 1
        let delay = TimeInterval.random(in: config.relayMinDelay...config.relayMaxDelay)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard running else { return }
        let peer = packet.recipientPeerID.flatMap { meshHexByPeerID[$0.hex] }.flatMap { peersByHex[$0] }
        await deliver(forwarded, messageId: packet.packetID.popopxHex, peer: peer, origin: linkID)
    }

    // MARK: - Private groups (module 8)

    /// The group layer's outbound half. Everything here is a thin wrapper: the decisions — who to
    /// believe, what a roster means, whether a message is ours to read — live in
    /// `PopopxGroupCoordinator`, and this is the part that puts bytes on the radio and hands bytes
    /// back to it.
    public func createGroup(named name: String) async throws(PopopxMeshGroupError) -> PopopxMeshGroup {
        try await groups.createGroup(named: name)
    }

    public func meshGroups() async -> [PopopxMeshGroup] {
        await groups.groups()
    }

    public func meshGroupMembers(of groupID: Data) async -> [PopopxMeshGroupMember] {
        await groups.members(of: groupID)
    }

    public var localSigningPublicKeyHex: String? {
        get async { await groups.localSigningPublicKeyHex }
    }

    public func invitableMeshPeers() async -> [String] {
        await groups.invitablePeers()
    }

    /// An invite: the coordinator rotates the key, advances the epoch, signs the roster and says who
    /// gets which blob; this puts each blob in that peer's Noise session.
    ///
    /// A peer the radio could not take is reported in `.deliveryFailed` *after* the local rotation
    /// has already happened. Undoing it is not on the table — the epoch would then move backwards
    /// for everyone who did get the state — so the honest answer is the list of peers to retry.
    public func invite(
        peerMeshPublicKeyHex: String,
        toGroupID groupID: Data
    ) async throws(PopopxMeshGroupError) -> PopopxGroupDistribution {
        try await distribute(await groups.invite(
            peerMeshPublicKeyHex: peerMeshPublicKeyHex,
            toGroupID: groupID
        ))
    }

    public func removeMeshGroupMember(
        _ peerMeshPublicKeyHex: String,
        fromGroupID groupID: Data
    ) async throws(PopopxMeshGroupError) -> PopopxGroupDistribution {
        try await distribute(await groups.removeMember(
            peerMeshPublicKeyHex,
            fromGroupID: groupID
        ))
    }

    private func distribute(
        _ distribution: PopopxGroupDistribution
    ) async throws(PopopxMeshGroupError) -> PopopxGroupDistribution {
        guard running else {
            throw PopopxMeshGroupError.deliveryFailed(
                peerMeshPublicKeyHexes: distribution.recipients,
                failure: .radioUnavailable(radioState)
            )
        }
        var undelivered: [String] = []
        var failure: PopopxMeshSendFailure?
        for stateSend in distribution.sends {
            do {
                // One id per send, so a failure names the frame that failed rather than the blob.
                try await send(
                    plaintext: stateSend.payload,
                    as: .groupState,
                    to: stateSend.recipientMeshPublicKeyHex,
                    messageId: "groupstate:\(distribution.group.idHex):\(stateSend.recipientMeshPublicKeyHex.prefix(8))"
                )
            } catch {
                undelivered.append(stateSend.recipientMeshPublicKeyHex)
                if failure == nil { failure = error.failure }
            }
        }
        if let failure {
            throw PopopxMeshGroupError.deliveryFailed(
                peerMeshPublicKeyHexes: undelivered,
                failure: failure
            )
        }
        return distribution
    }

    /// Seals one message under the group's current epoch and floods it. `deliver` is the same path a
    /// `#mesh` plaza post takes: broadcast TTL from the config, fragmentation if a link needs it,
    /// and the flood window remembers the packet so our own echo is dropped.
    public func sendGroupMessage(_ text: String, toGroupID groupID: Data) async throws(PopopxMeshGroupError) {
        guard running else {
            throw PopopxMeshGroupError.deliveryFailed(peerMeshPublicKeyHexes: [], failure: .radioUnavailable(radioState))
        }
        let (payload, message) = try await groups.sealMessage(text, toGroupID: groupID)
        let packet = PopopxMeshPacket(
            type: PopopxMeshMessageType.groupMessage.rawValue,
            ttl: outboundTTL(broadcast: true),
            timestamp: PopopxMeshPacket.nowMillis,
            senderID: identity.peerID.bytes,
            recipientID: nil,
            payload: payload
        )
        let handedOff = await deliver(packet, messageId: message.id, peer: nil, origin: nil)
        guard handedOff else {
            // The message is in the local timeline already, with the `.sendFailed` marker `deliver` published.
            // A broadcast names no peer, so this payload is empty by construction: `.noLinkToPeer` is the whole diagnosis.
            throw PopopxMeshGroupError.deliveryFailed(peerMeshPublicKeyHexes: [], failure: .noLinkToPeer)
        }
    }

    /// A directed, session-authenticated group state blob: an invite, a rotation, a removal notice.
    /// The peer the handshake authenticated has to be the creator the state names, which is the
    /// first check inside `applyState` and the reason this hands it the session's key and not the
    /// header's.
    private func consumeGroupState(_ packet: PopopxMeshPacket, hopCount: Int, linkID: UUID) async {
        guard let sender = packet.senderPeerID,
              let meshHex = meshHexByPeerID[sender.hex],
              var session = peersByHex[meshHex]?.session else {
            PopopxMeshLog.route.debug(
                "🚫 group state with no session from \(packet.senderID.popopxHex.prefix(16), privacy: .public) dropped"
            )
            return
        }
        guard packet.recipientPeerID == identity.peerID else {
            // Addressed to someone else: we are a hop in its delivery, and the relay already ran.
            return
        }
        let blob: Data
        do {
            blob = try session.decrypt(packet.payload)
        } catch {
            PopopxMeshLog.noise.warning(
                "🚫 group state frame from \(meshHex.prefix(8), privacy: .public) would not open: \(String(describing: error), privacy: .public)"
            )
            return
        }
        peersByHex[meshHex]?.session = session
        touch(meshPublicKeyHex: meshHex, hopCount: hopCount, linkID: linkID)
        _ = await groups.applyState(blob, fromMeshPublicKeyHex: meshHex)
    }

    /// The flooded half. A node without the group key answers nil here without logging more than a
    /// debug line, and the packet has already been re-flooded by `relay` — that is the whole design:
    /// everyone carries it, only members read it.
    private func consumeGroupMessage(_ packet: PopopxMeshPacket, hopCount: Int) async {
        guard packet.isBroadcast || packet.recipientPeerID == identity.peerID else { return }
        _ = await groups.receiveMessage(packet.payload, hopCount: hopCount)
    }

    // MARK: - Peers

    /// Records that this peer was heard at this many hops, on this link. The `linkID` a frame
    /// arrived on proves the peer is one hop away *if the link is ours*; a relayed frame carries no
    /// link at all, so `nil` keeps the peer indirect.
    private func touch(hopCount: Int, linkID: UUID?, into record: inout PeerRecord) {
        record.hopCount = hopCount
        record.lastSeenAt = .now
        if let linkID {
            record.linkIDs.insert(linkID)
            meshHexByLink[linkID] = record.meshPublicKeyHex
            record.isDirect = true
        }
    }

    private func touch(meshPublicKeyHex: String, hopCount: Int, linkID: UUID?) {
        guard var record = peersByHex[meshPublicKeyHex] else { return }
        touch(hopCount: hopCount, linkID: linkID, into: &record)
        peersByHex[meshPublicKeyHex] = record
    }

    private func forget(_ meshPublicKeyHex: String) {
        guard let record = peersByHex.removeValue(forKey: meshPublicKeyHex) else { return }
        meshHexByPeerID[record.peerID.hex] = nil
        for (linkID, bound) in meshHexByLink where bound == meshPublicKeyHex { meshHexByLink[linkID] = nil }
        settleHandshakeWaiters(meshPublicKeyHex)
    }

    // MARK: - Maintenance

    private func maintain() async {
        let now = Date.now
        for (meshHex, record) in peersByHex {
            if record.session == nil, let started = record.handshakeStartedAt,
               now.timeIntervalSince(started) > config.connectTimeout {
                peersByHex[meshHex]?.handshake = nil
                peersByHex[meshHex]?.handshakeStartedAt = nil
                settleHandshakeWaiters(meshHex)
                PopopxMeshLog.noise.warning("⌛ handshake with \(meshHex.prefix(8), privacy: .public) went nowhere")
            }
            // A peer we could not reach for four of module 4's windows, on no link of ours, is dropped;
            // its record is not the evidence a delivery failure is drawn from, that is the monitor.
            if record.linkIDs.isEmpty,
               record.session == nil,
               now.timeIntervalSince(record.lastSeenAt) > config.peerReachabilityTimeout * 4 {
                forget(meshHex)
            }
        }
        for (senderHex, handshake) in responders
        where now.timeIntervalSince(handshake.startedAt) > config.connectTimeout {
            responders[senderHex] = nil
        }
        await recentPackets.prune(now: now)
        await fragments.prune(now: now)
        guard running, radioState.isUsable else { return }
        await announceIfNeeded(now: now)
    }

    private func announceIfNeeded(now: Date) async {
        if let last = lastAnnounceAt, now.timeIntervalSince(last) < config.announceInterval { return }
        lastAnnounceAt = now
        let packet = PopopxMeshPacket(
            type: PopopxMeshMessageType.announce.rawValue,
            ttl: outboundTTL(broadcast: true),
            timestamp: PopopxMeshPacket.nowMillis,
            senderID: identity.peerID.bytes,
            recipientID: nil,
            payload: await announcePayload()
        )
        await deliver(packet, messageId: packet.packetID.popopxHex, peer: nil, origin: nil)
    }

    /// Announce carries our public key, nickname and Ed25519 signing key in the clear, so a neighbour
    /// can bind our 8-byte wire id to a POPOPX contact before either of us has a session, and so the
    /// creator of a group can write a roster row for us at all — a signing key has to be reachable
    /// from somewhere, and the only broadcast this protocol has is this one.
    ///
    /// Cost, stated plainly: a third long-term public key per node, visible to anyone in Bluetooth
    /// range, which is one more value that can be used to recognise the same device across days.
    /// Bitchat pays it for the same reason (`GroupProtocol.swift:23`), and unlike its announce the
    /// field is additive inside a JSON dictionary, so a node that does not know module 8 ignores it.
    private func announcePayload() async -> Data {
        var fields: [String: String] = [Self.announcePublicKeyField: identity.meshPublicKeyHex]
        if let nickname, !nickname.isEmpty { fields[Self.announceNicknameField] = nickname }
        if let signingHex = await groups.localSigningPublicKeyHex, !signingHex.isEmpty {
            fields[Self.announceSigningKeyField] = signingHex
        }
        return (try? JSONEncoder().encode(fields)) ?? Data()
    }

    // MARK: - Envelope codec

    /// The envelope JSON is what a Noise frame encrypts, so both ends of a session run this one
    /// codec. Sorted keys keep the bytes stable; `decodeEnvelope` answers nil for anything that is
    /// not our own JSON rather than guessing at a shape a stranger chose.
    nonisolated static func encode(_ envelope: PopopxMeshEnvelope) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(envelope)) ?? Data()
    }

    nonisolated static func decodeEnvelope(_ data: Data) -> PopopxMeshEnvelope? {
        try? JSONDecoder().decode(PopopxMeshEnvelope.self, from: data)
    }

    private func publish(_ event: PopopxMeshEvent) async {
        await hub.publish(event)
    }
}

extension PopopxMeshEngine: PopopxMeshOutbound {}

extension PopopxMeshEngine: PopopxMeshGroupOutbound {}

extension PopopxMeshEngine: PopopxBLETransportDelegate {
    public nonisolated func bleTransport(
        _ transport: any PopopxBLETransporting,
        didReceive data: Data,
        from linkID: UUID
    ) {
        Task { await self.receive(data: data, linkID: linkID) }
    }

    public nonisolated func bleTransport(
        _ transport: any PopopxBLETransporting,
        didUpdateState state: PopopxBluetoothState
    ) {
        Task { await self.radioChanged(state) }
    }

    public nonisolated func bleTransport(_ transport: any PopopxBLETransporting, didOpen link: PopopxBLELink) {
        Task { await self.linkOpened(link) }
    }

    public nonisolated func bleTransport(
        _ transport: any PopopxBLETransporting,
        didBecomeWritable link: PopopxBLELink
    ) {
        Task { await self.linkWritable(link) }
    }

    public nonisolated func bleTransport(
        _ transport: any PopopxBLETransporting,
        didClose linkID: UUID,
        error: (any Error)?
    ) {
        Task { await self.linkClosed(linkID, error: error) }
    }

    public nonisolated func bleTransport(
        _ transport: any PopopxBLETransporting,
        didFailToSend data: Data,
        to linkID: UUID,
        error: (any Error)?
    ) {
        Task { await self.writeFailed(data, linkID: linkID, error: error) }
    }

    private func radioChanged(_ state: PopopxBluetoothState) async {
        radioState = state
        await publish(.bluetoothState(state))
        guard !state.isUsable else { return }
        // A radio that died takes its sessions with it: the next start re-handshakes rather than
        // writing into a session CoreBluetooth has already forgotten.
        peersByHex.removeAll()
        meshHexByPeerID.removeAll()
        meshHexByLink.removeAll()
        responders.removeAll()
        settleAllHandshakeWaiters()
    }

    private func linkOpened(_ link: PopopxBLELink) async {
        // Nothing is bound yet: a link becomes a peer's link when a packet names it.
        PopopxMeshLog.ble.debug(
            "🔗 link open mtu=\(link.negotiatedMTU, privacy: .public) central=\(link.isCentralRole, privacy: .public)"
        )
    }

    private func linkWritable(_ link: PopopxBLELink) async {
        guard let meshHex = meshHexByLink[link.linkID] else { return }
        touch(meshPublicKeyHex: meshHex, hopCount: 0, linkID: link.linkID)
        guard let peer = peersByHex[meshHex] else { return }
        await publish(.peerAppeared(peer.peer))
    }

    private func linkClosed(_ linkID: UUID, error: (any Error)?) async {
        guard let meshHex = meshHexByLink.removeValue(forKey: linkID) else { return }
        peersByHex[meshHex]?.linkIDs.remove(linkID)
        guard var peer = peersByHex[meshHex] else { return }
        if peer.linkIDs.isEmpty {
            peer.isDirect = false
            peersByHex[meshHex] = peer
            // module 4 turns this into onBluetoothDeliveryFailed for everything still in flight.
            await publish(.peerDisappeared(peer.peerID))
        }
        PopopxMeshLog.ble.debug(
            "✂️ link \(linkID.uuidString.prefix(8), privacy: .public) closed: \(String(describing: error), privacy: .public)"
        )
    }

    private func writeFailed(_ data: Data, linkID: UUID, error: (any Error)?) async {
        guard let packet = PopopxMeshPacket.decode(data), let peer = packet.recipientPeerID else { return }
        let reason: PopopxMeshSendFailure
        if !radioState.isUsable {
            reason = .radioUnavailable(radioState)
        } else if error is PopopxBLETransportError {
            reason = .linkDropped
        } else {
            reason = .noLinkToPeer
        }
        await publish(.sendFailed(messageId: packet.packetID.popopxHex, peer: peer, reason: reason))
        if case .linkDropped = reason, let meshHex = meshHexByPeerID[peer.hex] {
            peersByHex[meshHex]?.session = nil
        }
    }
}
