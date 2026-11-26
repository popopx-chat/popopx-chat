//
//  PopopxMeshRetransmitTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Defect 4's regression net: the mesh must not eat its own retries.
//
//  Three losses were stacked here. A packet was entered into the 30-second flood window *before* this
//  node knew whether it could use it, so the copy that would have finished the job — the sibling
//  fragment of a stream with a hole, the retransmission that arrives after the handshake it was
//  waiting on — carried the same bytes and was dropped on purpose. Nothing re-sent a frame that never
//  got a `BLE_ACK`. And a stream longer than the receiver's ceiling was deleted at the far end by a
//  number the sender never consulted.
//
//  Each has a test at the layer where the decision is actually made: the windows in
//  `PopopxMeshDeduplicator`, fragment flow between two engines over a scripted wire, and the retry
//  budget in `PopopxMessageRouter`. The wire is a fake on purpose; the timings the tests rely on are
//  the ones the config hands them. What this cannot prove — that a real pair of phones 30 cm apart
//  receives every message — is in the report as unverified.
//

import Foundation
import PopopxMeshKit
import Testing

// MARK: - Doubles

/// A radio with the link table the test asks for, and a `send` that can be told to fail.
private final class RetransmitTransport: PopopxBLETransporting, @unchecked Sendable {
    private let lock = TestMutex()
    private var sentFrames: [Data] = []
    private let linkTable: [PopopxBLELink]
    private let radio: PopopxBluetoothState
    private var failWrites = false

    init(radio: PopopxBluetoothState = .poweredOn, links: [PopopxBLELink]) {
        self.radio = radio
        self.linkTable = links
    }

    var state: PopopxBluetoothState { get async { radio } }
    var links: [PopopxBLELink] { get async { linkTable } }

    var frames: [Data] { lock.withLock { sentFrames } }
    var packets: [PopopxMeshPacket] { frames.compactMap { PopopxMeshPacket.decode($0) } }

    func packets(of type: PopopxMeshMessageType) -> [PopopxMeshPacket] {
        packets.filter { $0.decodedType == type }
    }

    /// The fragment stream the radio was asked to carry, keyed by the index inside it. A test that
    /// punches a hole has to name the piece by position, because the run leaves in order but arrives
    /// whenever the actor gets to it.
    var fragmentsByIndex: [Int: Data] {
        var out: [Int: Data] = [:]
        for frame in frames {
            guard let packet = PopopxMeshPacket.decode(frame),
                  packet.decodedType == .fragment,
                  let header = PopopxMeshFragmentHeader(packet: packet) else { continue }
            out[header.index] = frame
        }
        return out
    }

    var fragmentCount: Int { fragmentsByIndex.count }

    func setFailWrites(_ flag: Bool) { lock.withLock { failWrites = flag } }

    func setDelegate(_ delegate: (any PopopxBLETransportDelegate)?) async {}
    func start() async {}
    func stop() async {}

    func send(_ data: Data, to linkID: UUID) async -> Bool {
        if failWrites { return false }
        lock.withLock { sentFrames.append(data) }
        return true
    }

    func notifySubscribers(_ data: Data) async {
        if failWrites { return }
        lock.withLock { sentFrames.append(data) }
    }

    func connect(to linkID: UUID) async {}
    func disconnect(_ linkID: UUID) async {}
}

/// One `.sendFailed` event, as the assertions below read it.
fileprivate struct MeshPublishedFailure: Equatable {
    let messageId: String
    let peer: PopopxMeshPeerID?
    let reason: PopopxMeshSendFailure
}

/// What a mesh hub published, for the assertions that are about silence. `watch` subscribes before it
/// returns, so nothing lands in the gap a late subscription would leave.
private final class MeshEventLog: @unchecked Sendable {
    private let lock = TestMutex()
    private var events: [PopopxMeshEvent] = []
    private var task: Task<Void, Never>?

    func watch(_ hub: PopopxMeshEventHub) async {
        let stream = await hub.subscribe()
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.lock.withLock { self.events.append(event) }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    var broadcastTexts: [String] {
        lock.withLock {
            events.compactMap { event in
                guard case let .inbound(message) = event, message.isBroadcast,
                      case let .text(body) = message.body else { return nil }
                return body
            }
        }
    }

    var failures: [MeshPublishedFailure] {
        lock.withLock {
            events.compactMap { event in
                guard case let .sendFailed(messageId, peer, reason) = event else { return nil }
                return MeshPublishedFailure(messageId: messageId, peer: peer, reason: reason)
            }
        }
    }
}

/// A harness problem, so a broken fixture says so instead of failing an unrelated expectation.
private struct RetransmitHarnessFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

private func retransmitDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("popopx-retransmit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Polls until the condition holds or the deadline passes, and returns whether it ever did. Every
/// assertion below is about bytes that left one actor and reached another through a `Task`; a fixed
/// sleep would be either flaky or slow.
private func retransmitUntil(timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

private func makeRetransmitNode(
    nickname: String,
    config: PopopxMeshConfig,
    links: [PopopxBLELink]
) async throws -> (PopopxMeshEngine, RetransmitTransport, MeshEventLog, URL) {
    let directory = try retransmitDirectory()
    let transport = RetransmitTransport(links: links)
    let hub = PopopxMeshEventHub()
    let engine = PopopxMeshEngine(
        config: config,
        transport: transport,
        hub: hub,
        secrets: MeshTestSecrets(),
        groupStore: PopopxGroupStore(secrets: MeshTestSecrets(), directory: directory)
    )
    let log = MeshEventLog()
    await log.watch(hub)
    await engine.start(nickname: nickname)
    return (engine, transport, log, directory)
}

/// Open, writable, and narrow enough that a two-hundred-byte post is a run of fragments.
private func shortLink(mtu: Int = 120) -> PopopxBLELink {
    PopopxBLELink(isCentralRole: true, canSend: true, negotiatedMTU: mtu)
}

private func retransmitConfig() -> PopopxMeshConfig {
    var config = PopopxMeshConfig()
    config.relayMinDelay = 0
    config.relayMaxDelay = 0.001
    return config
}

// MARK: - The three windows

@Test("a packet this node could not use becomes retryable when the short window passes, and stays held inside it")
func refusedPacketIsRetryableAfterTheShortWindow() async {
    let dedup = PopopxMeshDeduplicator(config: retransmitConfig())
    let id = Data((0..<16).map { UInt8($0 + 1) })
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    let window = PopopxMeshConfig.default.refusalPacketWindow

    #expect(await dedup.claim(packetID: id, now: started), "the first sighting is this node's to work on")
    #expect(
        await dedup.claim(packetID: id, now: started.addingTimeInterval(window / 2)) == false,
        "two copies of one flood must not both be worked on"
    )
    #expect(await dedup.claim(packetID: id, now: started.addingTimeInterval(window * 2)))

    let stats = await dedup.stats
    #expect(stats.recentCount == 0, "a packet nobody could use never enters the 30-second flood window")
    #expect(stats.refusalCount == 1, "it is still held, so one undecryptable frame is not decrypted per hop")
    #expect(stats.hits == 1, "the suppressed copy is counted on the deciding call")
}

@Test("confirming an id promotes it out of the retryable hold and into the flood window")
func confirmPromotesIntoTheFloodWindow() async {
    let config = retransmitConfig()
    let dedup = PopopxMeshDeduplicator(config: config)
    let id = Data((0..<16).map { UInt8($0 + 7) })
    let started = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(await dedup.claim(packetID: id, now: started))
    await dedup.confirm(packetID: id, now: started)
    let promoted = await dedup.stats
    #expect(promoted.recentCount == 1)
    #expect(promoted.refusalCount == 0, "one id lives in one window at a time")

    // The flood window, not the hold, is what the rest of that flood is measured against.
    #expect(
        await dedup.claim(packetID: id, now: started.addingTimeInterval(config.refusalPacketWindow * 5)) == false,
        "a used packet stays remembered"
    )
    #expect(await dedup.claim(packetID: id, now: started.addingTimeInterval(config.recentPacketWindow * 2)))
}

@Test("the retryable hold is bounded by count and evicts the oldest refusal")
func refusalHoldIsBounded() async {
    var config = retransmitConfig()
    config.refusalPacketMaxCount = 4
    let dedup = PopopxMeshDeduplicator(config: config)
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    let ids = (0..<6).map { index in Data(repeating: UInt8(index + 1), count: 16) }

    for id in ids {
        #expect(await dedup.claim(packetID: id, now: started))
    }
    let stats = await dedup.stats
    #expect(stats.refusalCount == 4, "a stranger spraying new ids cannot grow this table past the cap")
    #expect(await dedup.claim(packetID: ids[5], now: started) == false, "the newest refusal is still held")
    #expect(await dedup.claim(packetID: ids[0], now: started), "the oldest was evicted, so it is fresh again")
}

@Test("note still pins a packet for the whole flood window, because that packet was used")
func noteKeepsItsOldMeaning() async {
    let dedup = PopopxMeshDeduplicator(config: retransmitConfig())
    let id = Data(repeating: 0x5C, count: 16)
    let started = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(await dedup.note(packetID: id, now: started))
    #expect(await dedup.claim(packetID: id, now: started.addingTimeInterval(1)) == false)
    let stats = await dedup.stats
    #expect(stats.recentCount == 1)
    #expect(stats.refusalCount == 0, "note writes the flood window directly; confirm has nothing left to move")
}

@Test("an id too long to be one this engine mints is neither claimed nor remembered")
func oversizedKeyStaysStateless() async {
    let dedup = PopopxMeshDeduplicator(config: retransmitConfig())
    let foreign = Data(repeating: 0xA1, count: PopopxMeshDeduplicator.maxKeyBytes + 1)

    #expect(await dedup.claim(packetID: foreign, now: .now))
    #expect(await dedup.claim(packetID: foreign, now: .now), "answered 'not seen' twice, so it stays stateless")
    let stats = await dedup.stats
    #expect(stats.recentCount == 0 && stats.refusalCount == 0)
    #expect(stats.hits == 0)
}

// MARK: - Fragments over a scripted wire

@Test("a broadcast that arrives with a hole in its fragment stream completes when the missing piece turns up")
func fragmentHoleIsFilledByALaterCopy() async throws {
    let config = retransmitConfig()
    let text = String(repeating: "p", count: 200)

    let (speaker, speakerTransport, _, speakerDir) = try await makeRetransmitNode(
        nickname: "Speaker", config: config, links: [shortLink()]
    )
    let listenerIngress = shortLink()
    let (listener, listenerTransport, listenerLog, listenerDir) = try await makeRetransmitNode(
        // A second link so the flood the listener re-serves is not what this test is measuring.
        nickname: "Listener", config: config, links: [listenerIngress, shortLink(mtu: 180)]
    )
    let ingress = listenerIngress.linkID

    try await withTeardown {
        try await speaker.sendBroadcast(text: text)
        let fragmented = await retransmitUntil { speakerTransport.fragmentCount >= 2 }
        #expect(fragmented, "a payload longer than the link's budget goes on the air as fragments")
        let total = speakerTransport.fragmentCount
        let byIndex = speakerTransport.fragmentsByIndex

        // Every piece but the middle one: a hole is what a retransmission exists to fill.
        for index in 0..<total where index != 1 {
            guard let frame = byIndex[index] else { continue }
            listener.bleTransport(listenerTransport, didReceive: frame, from: ingress)
        }
        let early = await retransmitUntil(timeout: 1) { !listenerLog.broadcastTexts.isEmpty }
        #expect(!early, "an incomplete stream is held, never delivered as a partial message")

        guard let missing = byIndex[1] else {
            throw RetransmitHarnessFailure("fragment index 1 never left the speaker")
        }
        listener.bleTransport(listenerTransport, didReceive: missing, from: ingress)
        let landed = await retransmitUntil { listenerLog.broadcastTexts == [text] }
        #expect(landed, "the pieces do not have to arrive in delivery order for the stream to complete")

        // The whole run again — the echo a relay produces. One copy reaches the user.
        for index in 0..<total {
            guard let frame = byIndex[index] else { continue }
            listener.bleTransport(listenerTransport, didReceive: frame, from: ingress)
        }
        let doubled = await retransmitUntil(timeout: 1) { listenerLog.broadcastTexts.count > 1 }
        #expect(!doubled)
        #expect(listenerLog.broadcastTexts == [text])
    } teardown: {
        try? FileManager.default.removeItem(at: speakerDir)
        try? FileManager.default.removeItem(at: listenerDir)
        await listener.stop()
        await speaker.stop()
    }
}

@Test("a fragment stream past the receiver's ceiling is refused, and the mesh keeps working afterwards")
func oversizedStreamIsRefusedWithoutWedgingTheReceiver() async throws {
    var speakerConfig = retransmitConfig()
    // The sender is allowed to hold what it sends; the receiver's ceiling is the one under test.
    speakerConfig.maxReassembledBytes = 8192
    var listenerConfig = retransmitConfig()
    listenerConfig.maxReassembledBytes = 256

    let (speaker, speakerTransport, _, speakerDir) = try await makeRetransmitNode(
        nickname: "Speaker", config: speakerConfig, links: [shortLink()]
    )
    let listenerIngress = shortLink()
    let (listener, listenerTransport, listenerLog, listenerDir) = try await makeRetransmitNode(
        nickname: "Listener", config: listenerConfig, links: [listenerIngress]
    )
    let ingress = listenerIngress.linkID

    try await withTeardown {
        try await speaker.sendBroadcast(text: String(repeating: "q", count: 1000))
        let fragmented = await retransmitUntil { speakerTransport.fragmentCount >= 2 }
        #expect(fragmented)
        let oversizedRun = speakerTransport.frames.filter {
            PopopxMeshPacket.decode($0)?.decodedType == .fragment
        }
        for frame in oversizedRun {
            listener.bleTransport(listenerTransport, didReceive: frame, from: ingress)
        }
        let published = await retransmitUntil(timeout: 1) { !listenerLog.broadcastTexts.isEmpty }
        #expect(!published, "nothing is shown from a stream this node was never going to hold")

        // And the refusal released the slot instead of pinning it, which is what a drip of one fragment per
        // window would otherwise cost the node.
        try await speaker.sendBroadcast(text: "still here")
        let shortRun = speakerTransport.packets(of: .message)
        #expect(shortRun.count == 1, "a ten-byte post is one frame: the listener's ceiling is the only difference")
        guard let frame = speakerTransport.frames.last,
              PopopxMeshPacket.decode(frame)?.decodedType == .message else {
            throw RetransmitHarnessFailure("the speaker's short post left no message frame")
        }
        listener.bleTransport(listenerTransport, didReceive: frame, from: ingress)
        let recovered = await retransmitUntil { listenerLog.broadcastTexts == ["still here"] }
        #expect(recovered, "a refused stream must not cost the node its ability to receive the next one")
    } teardown: {
        try? FileManager.default.removeItem(at: speakerDir)
        try? FileManager.default.removeItem(at: listenerDir)
        await listener.stop()
        await speaker.stop()
    }
}

@Test("a broadcast larger than the mesh's own reassembly ceiling is refused at the sender, not lost at the far end")
func oversizedBroadcastIsRefusedLocally() async throws {
    let config = retransmitConfig()
    let (speaker, speakerTransport, speakerLog, speakerDir) = try await makeRetransmitNode(
        nickname: "Speaker", config: config, links: [shortLink()]
    )
    try await withTeardown {
        let text = String(repeating: "x", count: config.maxReassembledBytes + 1)
        await #expect(throws: PopopxMeshSendError.self) {
            try await speaker.sendBroadcast(text: text)
        }
        let published = await retransmitUntil { !speakerLog.failures.isEmpty }
        guard published, let failure = speakerLog.failures.first else {
            throw RetransmitHarnessFailure("the local oversized pre-check published no failure")
        }
        #expect(failure.peer == nil, "a broadcast names no recipient, and nil is the truth rather than a substitute")
        guard case let .oversized(payloadBytes, limitBytes) = failure.reason else {
            throw RetransmitHarnessFailure("expected an oversized refusal, got \(failure.reason)")
        }
        #expect(limitBytes == config.maxReassembledBytes)
        #expect(payloadBytes > limitBytes)
        #expect(
            speakerTransport.packets(of: .message).isEmpty,
            "refusing on the way out means no fragment run was put on the air at all"
        )
    } teardown: {
        try? FileManager.default.removeItem(at: speakerDir)
        await speaker.stop()
    }
}

@Test("a write the radio refused is reported, with no peer attached")
func broadcastWriteFailureIsReported() async throws {
    let config = retransmitConfig()
    let link = shortLink()
    let (speaker, speakerTransport, speakerLog, speakerDir) = try await makeRetransmitNode(
        nickname: "Speaker", config: config, links: [link]
    )
    try await withTeardown {
        try await speaker.sendBroadcast(text: "the write never landed")
        let frame = try #require(speakerTransport.frames.first)
        let packet = try #require(PopopxMeshPacket.decode(frame))
        #expect(packet.recipientPeerID == nil, "this is the broadcast case the old guard returned on")
        let before = speakerLog.failures.count

        speaker.bleTransport(speakerTransport, didFailToSend: frame, to: link.linkID, error: nil)
        let reported = await retransmitUntil { speakerLog.failures.count > before }
        #expect(reported, "a frame CoreBluetooth refused used to be reported for a directed packet only")
        let failure = try #require(speakerLog.failures.last)
        #expect(failure.messageId == packet.packetID.popopxHex, "module 4 arms its guard on this same id")
        #expect(failure.peer == nil)
    } teardown: {
        try? FileManager.default.removeItem(at: speakerDir)
        await speaker.stop()
    }
}

// MARK: - The router's retry budget

@Test("the first ACK timeout goes back on the radio before the network is asked, keeping the id")
func firstTimeoutRetriesOnTheRadio() async throws {
    let sandbox = try MeshTestSandbox()
    defer { sandbox.reset() }
    let store = try sandbox.makeStore()
    let hex = meshTestHex("e001")
    try await bindAsContact(store, hex: hex, tempConnId: 901, contactId: 201)
    let (router, parts) = await makeRouterParts(
        store: store, online: false, reachable: [hex], ackInTime: true
    )
    defer { parts.openLatches() }

    let routed = await router.send(
        PopopxOutboundMessage(messageId: "id-retry", target: .contactId(201), text: "retry me")
    )
    #expect(routed.outcome == .meshSent(peerMeshPublicKeyHex: hex))
    #expect(await parts.outbound.sentMessageIds == ["id-retry"])
    await parts.network.setConnected(true)

    let outcome = await router.onBluetoothDeliveryFailed(messageId: "id-retry", peerMeshKey: hex)
    #expect(
        outcome == .meshSent(peerMeshPublicKeyHex: hex),
        "an ACK timeout is not proof the frame was never sent, so the radio gets it again"
    )
    #expect(
        await parts.outbound.sentMessageIds == ["id-retry", "id-retry"],
        "the retry keeps the id; a new one would show the message twice"
    )
    #expect(await parts.core.requests.isEmpty, "the public network was not consulted yet")
    #expect(await parts.judge.lastAskedTimeout == PopopxMeshConfig.default.peerReachabilityTimeout)
}

@Test("the retry budget is meshDeliveryRetries, and only then does the same id go to SMP once")
func retryBudgetThenSMPOnce() async throws {
    let sandbox = try MeshTestSandbox()
    defer { sandbox.reset() }
    let store = try sandbox.makeStore()
    let hex = meshTestHex("e002")
    let budget = PopopxMeshConfig.default.meshDeliveryRetries
    try await bindAsContact(store, hex: hex, tempConnId: 902, contactId: 202)
    let (router, parts) = await makeRouterParts(
        store: store, online: false, reachable: [hex], ackInTime: true
    )
    defer { parts.openLatches() }

    _ = await router.send(
        PopopxOutboundMessage(messageId: "id-budget", target: .contactId(202), text: "budget")
    )
    await parts.network.setConnected(true)

    for retry in 1...budget {
        let outcome = await router.onBluetoothDeliveryFailed(messageId: "id-budget", peerMeshKey: hex)
        #expect(outcome == .meshSent(peerMeshPublicKeyHex: hex), "retry \(retry) of \(budget)")
    }
    #expect(
        await parts.outbound.sentMessageIds == Array(repeating: "id-budget", count: budget + 1),
        "the original send plus the budget, and no more"
    )
    #expect(await parts.core.requests.isEmpty, "the budget is spent only after every copy timed out")

    let rerouted = await router.onBluetoothDeliveryFailed(messageId: "id-budget", peerMeshKey: hex)
    #expect(rerouted == .smpAcknowledged(contactId: 202))
    #expect(await parts.core.sentMessageIds == ["id-budget"], "one id reaches the public network once")

    let extra = await router.onBluetoothDeliveryFailed(messageId: "id-budget", peerMeshKey: hex)
    #expect(extra == .nothingToReroute(messageId: "id-budget"), "and a late echo re-sends nothing anywhere")
    #expect(await parts.outbound.sentMessageIds.count == budget + 1, "the retry does not restart after SMP")
}

@Test("a peer module 4 no longer hears from is not retried; the re-route happens at once")
func unreachablePeerIsNotRetried() async throws {
    let sandbox = try MeshTestSandbox()
    defer { sandbox.reset() }
    let store = try sandbox.makeStore()
    let hex = meshTestHex("e003")
    try await bindAsContact(store, hex: hex, tempConnId: 903, contactId: 203)
    let (router, parts) = await makeRouterParts(
        store: store, online: false, reachable: [hex], ackInTime: true
    )
    defer { parts.openLatches() }

    _ = await router.send(
        PopopxOutboundMessage(messageId: "id-gone", target: .contactId(203), text: "out of range")
    )
    await parts.network.setConnected(true)
    // Reachable when it was sent, silent by the time the ACK deadline ran out.
    await parts.judge.setReachable([])

    let outcome = await router.onBluetoothDeliveryFailed(messageId: "id-gone", peerMeshKey: hex)
    #expect(outcome == .smpAcknowledged(contactId: 203))
    #expect(await parts.outbound.sentMessageIds == ["id-gone"], "one radio copy: no retry was attempted")
    #expect(await parts.core.sentMessageIds == ["id-gone"])
}

@Test("a failure while our own radio is off is not retried onto a dead radio")
func deadRadioDoesNotBurnRetries() async throws {
    let sandbox = try MeshTestSandbox()
    defer { sandbox.reset() }
    let store = try sandbox.makeStore()
    let hex = meshTestHex("e004")
    try await bindAsContact(store, hex: hex, tempConnId: 904, contactId: 204)
    let (router, parts) = await makeRouterParts(
        store: store, online: false, radio: .poweredOff, reachable: [hex], ackInTime: true
    )
    defer { parts.openLatches() }

    let routed = await router.send(
        PopopxOutboundMessage(messageId: "id-dead", target: .contactId(204), text: "radio off")
    )
    #expect(routed.bluetooth == .radioUnavailable(.poweredOff))
    #expect(await parts.outbound.sent.isEmpty)

    await parts.network.setConnected(true)
    let outcome = await router.onBluetoothDeliveryFailed(messageId: "id-dead", peerMeshKey: hex)
    #expect(outcome == .smpAcknowledged(contactId: 204), "a dead radio leaves the network as the only channel")
    #expect(await parts.judge.askedKeys.isEmpty, "and it must not even be asked whether the peer is there")
    #expect(await parts.outbound.sent.isEmpty, "no frame was pushed at a radio that is off")
}

@Test("a retry the radio refuses outright falls through to SMP in the same call")
func refusedRetryFallsThroughToSMP() async throws {
    let sandbox = try MeshTestSandbox()
    defer { sandbox.reset() }
    let store = try sandbox.makeStore()
    let hex = meshTestHex("e005")
    try await bindAsContact(store, hex: hex, tempConnId: 905, contactId: 205)
    let (router, parts) = await makeRouterParts(
        store: store, online: false, reachable: [hex], ackInTime: true
    )
    defer { parts.openLatches() }

    _ = await router.send(
        PopopxOutboundMessage(messageId: "id-refused", target: .contactId(205), text: "session lost")
    )
    await parts.network.setConnected(true)
    // The peer's session is gone: the retry throws instead of timing out a second time.
    await parts.outbound.setRefuses(true)
    let outcome = await router.onBluetoothDeliveryFailed(messageId: "id-refused", peerMeshKey: hex)
    #expect(
        outcome == .smpAcknowledged(contactId: 205),
        "waiting five seconds for an ACK that can never arrive would only delay the channel that works"
    )
    #expect(await parts.core.sentMessageIds == ["id-refused"])
}

@Test("retries while offline park one queue entry, never one per attempt")
func retriesOfflineParkTheIdOnce() async throws {
    let sandbox = try MeshTestSandbox()
    defer { sandbox.reset() }
    let store = try sandbox.makeStore()
    let hex = meshTestHex("e006")
    let budget = PopopxMeshConfig.default.meshDeliveryRetries
    try await bindAsContact(store, hex: hex, tempConnId: 906, contactId: 206)
    let (router, parts) = await makeRouterParts(store: store, online: false, reachable: [hex])
    defer { parts.openLatches() }

    _ = await router.send(
        PopopxOutboundMessage(messageId: "id-parked", target: .contactId(206), text: "parked after retrying")
    )
    var outcomes: [PopopxRouteOutcome] = []
    for _ in 0..<(budget + 2) {
        outcomes.append(await router.onBluetoothDeliveryFailed(messageId: "id-parked", peerMeshKey: hex))
    }
    let meshCopies = outcomes.filter {
        if case .meshSent = $0 { return true }
        return false
    }
    #expect(meshCopies.count == budget, "one send, then \(budget) retries, then nothing left to retry: \(outcomes)")
    #expect(await parts.outbound.sentMessageIds.count == budget + 1)
    #expect(await parts.core.sentMessageIds.isEmpty, "offline means the public network is never contacted")

    let queue = await router.unacknowledgedMeshMessages
    #expect(queue.count == 1, "the spent attempts park the id once, not once per attempt")
    #expect(queue["id-parked"]?.text == "parked after retrying")
}
