//
//  PopopxMeshPendingForwardTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Defect 3's regression net. A send made while the mesh is up and the radio is on, with no link yet
//  able to take it, is held rather than lost: it goes out once — when the first writable link opens —
//  and never twice. Nothing on this path consults SMP: the queue belongs to the engine, and the only
//  router it feeds is the one that runs when the mesh itself cannot carry the packet.
//
//  The radio-off case is here too and goes the other way, because it is the half the report asked to
//  keep honest: a radio that is off buffers nothing and says 「蓝牙未开启」 instead of pretending a
//  neighbour is about to appear.
//

import Foundation
import PopopxMeshKit
import Testing

// MARK: - Doubles

/// A radio whose link table the test owns: it starts with no links at all, which is the state that
/// used to fail a send, and the test opens one when it wants the flush to have somewhere to go.
private final class HeldLinkTransport: PopopxBLETransporting, @unchecked Sendable {
    private let lock = TestMutex()
    private var sentFrames: [Data] = []
    private var linkTable: [PopopxBLELink]
    private let radio: PopopxBluetoothState

    init(radio: PopopxBluetoothState = .poweredOn, links: [PopopxBLELink] = []) {
        self.radio = radio
        self.linkTable = links
    }

    var state: PopopxBluetoothState { get async { radio } }
    var links: [PopopxBLELink] { get async { lock.withLock { linkTable } } }

    var frames: [Data] { lock.withLock { sentFrames } }
    var packets: [PopopxMeshPacket] { frames.compactMap { PopopxMeshPacket.decode($0) } }

    func packets(of type: PopopxMeshMessageType) -> [PopopxMeshPacket] {
        packets.filter { $0.decodedType == type }
    }

    /// Puts a writable link in the table and hands it back, which is the order CoreBluetooth uses: the
    /// link is enumerable before it reports itself writable.
    @discardableResult
    func openWritableLink(mtu: Int = 517) -> PopopxBLELink {
        let link = PopopxBLELink(isCentralRole: true, canSend: true, negotiatedMTU: mtu)
        lock.withLock { linkTable.append(link) }
        return link
    }

    func setDelegate(_ delegate: (any PopopxBLETransportDelegate)?) async {}
    func start() async {}
    func stop() async {}

    func send(_ data: Data, to linkID: UUID) async -> Bool {
        lock.withLock { sentFrames.append(data) }
        return true
    }

    func notifySubscribers(_ data: Data) async {
        lock.withLock { sentFrames.append(data) }
    }

    func connect(to linkID: UUID) async {}
    func disconnect(_ linkID: UUID) async {}
}

private func temporaryHoldDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("popopx-held-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func held(timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

/// One node: an engine over a transport it was started with no links on.
private func makeHeldEngine(
    nickname: String,
    radio: PopopxBluetoothState = .poweredOn
) async throws -> (PopopxMeshEngine, HeldLinkTransport, URL) {
    let directory = try temporaryHoldDirectory()
    let transport = HeldLinkTransport(radio: radio)
    let engine = PopopxMeshEngine(
        config: PopopxMeshConfig(),
        transport: transport,
        hub: PopopxMeshEventHub(),
        secrets: MeshTestSecrets(),
        groupStore: PopopxGroupStore(secrets: MeshTestSecrets(), directory: directory)
    )
    await engine.start(nickname: nickname)
    return (engine, transport, directory)
}

private func packet(id tag: String) -> PopopxMeshPacket {
    PopopxMeshPacket(
        type: PopopxMeshMessageType.message.rawValue,
        ttl: 7,
        timestamp: 1_700_000_000_000,
        senderID: Data(repeating: 0xAB, count: 8),
        recipientID: nil,
        payload: Data(tag.utf8)
    )
}

// MARK: - The queue itself

@Test("the held queue is first-in-first-out and drops the oldest send when it overflows")
func queueIsBoundedFifo() {
    var queue = PopopxMeshPendingForwardQueue(capacity: 3)
    for index in 1...5 {
        // Every `enqueue` result is bound to a name first: the queue mutates, and an assertion macro
        // cannot wrap a mutating call in its autoclosure.
        let accepted = queue.enqueue(
            PopopxMeshPendingForward(packet: packet(id: "m\(index)"), messageID: "m\(index)")
        )
        #expect(accepted)
    }
    #expect(queue.count == 3)
    #expect(!queue.contains(messageID: "m1"))
    #expect(!queue.contains(messageID: "m2"))
    let drained = queue.drain()
    #expect(drained.map(\.messageID) == ["m3", "m4", "m5"])
    #expect(queue.isEmpty)
}

@Test("re-offering an id the queue already holds adds nothing")
func queueIsIdempotentByMessageId() {
    var queue = PopopxMeshPendingForwardQueue(capacity: 4)
    let first = queue.enqueue(PopopxMeshPendingForward(packet: packet(id: "once"), messageID: "once"))
    #expect(first)
    // A flush that runs while another is pending is the case this protects: the same text must not
    // reach a neighbour twice because the engine was asked twice.
    let second = queue.enqueue(PopopxMeshPendingForward(packet: packet(id: "once"), messageID: "once"))
    #expect(!second)
    #expect(queue.count == 1)
    #expect(queue.drain().count == 1)
}

@Test("draining empties the queue and removing all leaves it empty")
func queueEmpties() {
    var queue = PopopxMeshPendingForwardQueue(capacity: 4)
    queue.enqueue(PopopxMeshPendingForward(packet: packet(id: "a"), messageID: "a"))
    queue.enqueue(PopopxMeshPendingForward(packet: packet(id: "b"), messageID: "b"))
    let drained = queue.drain()
    #expect(drained.map(\.messageID) == ["a", "b"])
    let again = queue.drain()
    #expect(again.isEmpty)
    queue.enqueue(PopopxMeshPendingForward(packet: packet(id: "c"), messageID: "c", peerMeshPublicKeyHex: "ff"))
    queue.removeAll()
    #expect(queue.isEmpty)
    #expect(!queue.contains(messageID: "c"))
}

// MARK: - Engine: group send

@Test("a group message with no link is held and reaches the radio once, when a link becomes writable")
func groupSendIsHeldThenFlushedOnce() async throws {
    let (engine, transport, directory) = try await makeHeldEngine(nickname: "Holder")
    defer { try? FileManager.default.removeItem(at: directory) }

    let group = try await engine.createGroup(named: "Held")
    await #expect(throws: PopopxMeshGroupError.deliveryFailed(peerMeshPublicKeyHexes: [], failure: .pendingForward(queued: 1))) {
        try await engine.sendGroupMessage("carry me", toGroupID: group.id)
    }
    // The claim that used to be false: the packet still exists, and nothing was put on the radio.
    #expect(transport.frames.isEmpty)
    #expect(await engine.meshGroups().count == 1)

    // An open-but-unwritable link is not a flush: writing into a characteristic nobody subscribed to is
    // the loss this queue exists to prevent.
    engine.bleTransport(transport, didOpen: PopopxBLELink(isCentralRole: true, canSend: false, negotiatedMTU: 517))
    let early = await held(timeout: 0.3) { !transport.frames.isEmpty }
    #expect(!early)

    let link = transport.openWritableLink()
    engine.bleTransport(transport, didBecomeWritable: link)
    let flushed = await held { transport.packets(of: .groupMessage).count == 1 }
    #expect(flushed)
    let sent = try #require(transport.packets(of: .groupMessage).first)
    // What went out is what was held: same flood TTL, same ciphertext.
    #expect(sent.isBroadcast)
    #expect(sent.ttl == PopopxMeshConfig().ttlDefault)

    // A second writability signal — the drain of a write queue, which CoreBluetooth reports per frame —
    // must not resend the message the neighbour already has.
    engine.bleTransport(transport, didBecomeWritable: link)
    let doubled = await held(timeout: 0.5) { transport.packets(of: .groupMessage).count > 1 }
    #expect(!doubled)
    #expect(transport.packets(of: .groupMessage).count == 1)

    await engine.stop()
}

@Test("held messages flush oldest first, which is the order the user sent them in")
func heldBroadcastsKeepTheirOrder() async throws {
    let (engine, transport, directory) = try await makeHeldEngine(nickname: "Ordered")
    defer { try? FileManager.default.removeItem(at: directory) }

    // The plaza path, not the group one, because a broadcast payload is the text: what left the device
    // in what order is readable rather than inferred from three indistinguishable ciphertexts.
    let texts = ["first", "second", "third"]
    for (index, text) in texts.enumerated() {
        do {
            try await engine.sendBroadcast(text: text)
            Issue.record("\(text) reported success with no link")
        } catch {
            // The depth grows with each send, which is the number the UI shows.
            #expect(error.failure == .pendingForward(queued: index + 1))
        }
    }
    let link = transport.openWritableLink()
    engine.bleTransport(transport, didBecomeWritable: link)
    let flushed = await held { transport.packets(of: .message).count == texts.count }
    #expect(flushed)
    #expect(
        transport.packets(of: .message).map { String(decoding: $0.payload, as: UTF8.self) } == texts
    )

    await engine.stop()
}

// MARK: - Engine: plaza broadcast

@Test("a plaza post with no link is held rather than dropped, and says how many are waiting")
func broadcastIsHeldThenFlushed() async throws {
    let (engine, transport, directory) = try await makeHeldEngine(nickname: "Poster")
    defer { try? FileManager.default.removeItem(at: directory) }

    do {
        try await engine.sendBroadcast(text: "held post")
        Issue.record("a flood with no link must not report success")
    } catch {
        #expect(error.failure == .pendingForward(queued: 1))
        #expect(!error.messageId.isEmpty)
    }
    #expect(transport.frames.isEmpty)

    let link = transport.openWritableLink()
    engine.bleTransport(transport, didBecomeWritable: link)
    let flushed = await held { transport.packets(of: .message).count == 1 }
    #expect(flushed)

    await engine.stop()
}

// MARK: - Engine: the two states that must NOT queue

@Test("a send with the radio off is refused as an unusable radio and nothing is buffered for it")
func radioOffIsRefusedRatherThanHeld() async throws {
    let (engine, transport, directory) = try await makeHeldEngine(nickname: "Off", radio: .poweredOff)
    defer { try? FileManager.default.removeItem(at: directory) }

    let group = try await engine.createGroup(named: "Off")
    await #expect(throws: PopopxMeshGroupError.deliveryFailed(peerMeshPublicKeyHexes: [], failure: .radioUnavailable(.poweredOff))) {
        try await engine.sendGroupMessage("nowhere", toGroupID: group.id)
    }
    // The link arrives anyway, as it would if the test were a radio coming back up: with nothing held,
    // there is nothing to send, and the user was told the truth instead of 「待转发」.
    let link = transport.openWritableLink()
    engine.bleTransport(transport, didBecomeWritable: link)
    let late = await held(timeout: 0.5) { !transport.frames.isEmpty }
    #expect(!late)

    await engine.stop()
}

@Test("held sends do not outlive the switch: stop drops them and a fresh start does not resend")
func stopDropsHeldSends() async throws {
    let (engine, transport, directory) = try await makeHeldEngine(nickname: "Fuse")
    defer { try? FileManager.default.removeItem(at: directory) }

    let group = try await engine.createGroup(named: "Fuse")
    await #expect(throws: PopopxMeshGroupError.deliveryFailed(peerMeshPublicKeyHexes: [], failure: .pendingForward(queued: 1))) {
        try await engine.sendGroupMessage("dies with the switch", toGroupID: group.id)
    }
    await engine.stop()

    // The same transport, a link that is writable, and a restart: "with the fuse off no mesh state is
    // left in memory" is what `stop()` claims, and a queue that survived it would contradict it.
    let link = transport.openWritableLink()
    await engine.start(nickname: "Fuse")
    engine.bleTransport(transport, didBecomeWritable: link)
    let resend = await held(timeout: 0.5) { !transport.packets(of: .groupMessage).isEmpty }
    #expect(!resend)
    // …and the silence above is the queue being empty, not the path being dead: a send made now does
    // reach the radio.
    try await engine.sendGroupMessage("fresh", toGroupID: group.id)
    let live = await held { transport.packets(of: .groupMessage).count == 1 }
    #expect(live)

    await engine.stop()
}

@Test("a radio that dies mid-wait drops what it was holding")
func radioTurningOffDropsHeldSends() async throws {
    let (engine, transport, directory) = try await makeHeldEngine(nickname: "Dying")
    defer { try? FileManager.default.removeItem(at: directory) }

    let group = try await engine.createGroup(named: "Dying")
    await #expect(throws: PopopxMeshGroupError.deliveryFailed(peerMeshPublicKeyHexes: [], failure: .pendingForward(queued: 1))) {
        try await engine.sendGroupMessage("short lived", toGroupID: group.id)
    }
    engine.bleTransport(transport, didUpdateState: .poweredOff)
    // Come back up with a link: the held send is gone with the sessions, so a message the user was told
    // was waiting cannot be delivered an hour later out of a queue the radio had no business keeping.
    engine.bleTransport(transport, didUpdateState: .poweredOn)
    let link = transport.openWritableLink()
    engine.bleTransport(transport, didBecomeWritable: link)
    let delivered = await held(timeout: 0.5) { !transport.packets(of: .groupMessage).isEmpty }
    #expect(!delivered)
    // Same calibration as the fuse test: the radio is back and a send made now does go out.
    try await engine.sendGroupMessage("after", toGroupID: group.id)
    let live = await held { transport.packets(of: .groupMessage).count == 1 }
    #expect(live)

    await engine.stop()
}
