//
//  PopopxMeshNicknameStoreTests.swift
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The plaza's local nickname: where it is allowed to live, and what the plaza does with a broadcast
//  the radio refused. The rule that decides the first is module 7's own — it is display state, so it is
//  a file in the mesh sandbox (which the panic wipe erases) and never a Keychain item (which it does
//  not, per row) — and the rule that decides the second is that a plaza with no queue must never lose
//  what the user typed.
//

import Foundation
import Testing
@testable import PopopxMeshUI
import PopopxMeshKit

@Suite("PopopxMeshNicknameStore")
struct PopopxMeshNicknameStoreTests {
    @Test("A nickname survives the round trip through the mesh sandbox")
    func roundTrip() throws {
        let directory = try PopopxMeshTestDirectory(label: "nickname-round-trip")
        defer { directory.remove() }
        let store = PopopxMeshNicknameStore(directory: directory.url)

        #expect(store.read() == nil)
        try store.write("Ada")
        // Written inside the sandbox the panic wipe owns, not in the Keychain. The location claim
        // belongs to the DEFAULT store — the one the fuse and the plaza build — because a test root
        // is a temporary directory the wipe never owns; what the injected root proves is only that the
        // store writes under the root it was handed.
        #expect(PopopxMeshNicknameStore().fileURL.path.contains(PopopxMeshPaths.directoryName))
        #expect(PopopxMeshNicknameStore().fileURL.lastPathComponent == PopopxMeshNicknameStore.fileName)
        #expect(store.fileURL.path.hasPrefix(directory.url.path))
        #expect(store.read() == "Ada")

        try store.write("  trimmed  ")
        #expect(store.read() == "trimmed")

        store.clear()
        #expect(store.read() == nil)
        #expect(!directory.exists(PopopxMeshNicknameStore.fileName))
    }

    @Test("A blank name is one representation, not three")
    func blankIsAbsence() throws {
        let directory = try PopopxMeshTestDirectory(label: "nickname-blank")
        defer { directory.remove() }
        let store = PopopxMeshNicknameStore(directory: directory.url)

        try store.write("   ")
        #expect(store.read() == nil)
        #expect(!directory.exists(PopopxMeshNicknameStore.fileName))

        // A file that was written by an older build and says nothing reads as nothing.
        try store.write("x")
        try Data("{}".utf8).write(to: store.fileURL)
        #expect(store.read() == nil)

        try store.write("y")
        try Data("{\"nickname\":\"\",\"updatedAt\":0}".utf8).write(to: store.fileURL)
        #expect(store.read() == nil)
    }

    @Test("The clamp is a trim plus a grapheme-safe cut, never a refusal")
    func clamping() {
        #expect(PopopxMeshNicknameStore.clamped("  hello  ") == "hello")
        #expect(PopopxMeshNicknameStore.clamped("") == nil)
        #expect(PopopxMeshNicknameStore.clamped("🙂🙂🙂")?.count == 3)
        let long = String(repeating: "n", count: 200)
        #expect(PopopxMeshNicknameStore.clamped(long)?.count == PopopxMeshNicknameStore.maxCharacters)
        // A pasted flag must not be cut in half: prefixing on grapheme boundaries is the point.
        let flags = String(repeating: "🇦🇩", count: 40)
        #expect(PopopxMeshNicknameStore.clamped(flags)?.contains("🇦🇩") == true)
    }

    @Test("The store's file lives in module 1's directory constant")
    func sandboxLocation() {
        #expect(PopopxMeshNicknameStore.fileName.hasSuffix(".json"))
        #expect(PopopxMeshPaths.meshDirectory().lastPathComponent == PopopxMeshPaths.directoryName)
        #expect(PopopxMeshNicknameStore(directory: PopopxMeshPaths.meshDirectory()).fileURL.path
            .hasPrefix(PopopxMeshPaths.meshDirectory().path))
    }
}

@MainActor
@Suite("PopopxMeshPlazaModel")
struct PopopxMeshPlazaModelTests {
    private func makeModel(
        label: String,
        rejection: PopopxMeshSendFailure? = nil
    ) throws -> (PopopxMeshPlazaModel, PopopxMeshFakeOutbound, PopopxMeshTestDirectory) {
        let directory = try PopopxMeshTestDirectory(label: label)
        let journal = PopopxMeshJournal()
        let outbound = PopopxMeshFakeOutbound(journal: journal, rejection: rejection)
        let model = PopopxMeshPlazaModel(
            outbound: outbound,
            source: PopopxMeshStateSource(hub: PopopxMeshEventHub()),
            nicknameStore: PopopxMeshNicknameStore(directory: directory.url)
        )
        return (model, outbound, directory)
    }

    @Test("The plaza starts with the fallback name and keeps what it saved")
    func nicknameRoundTripThroughThePlaza() async throws {
        let made = try makeModel(label: "plaza-nickname")
        let model = made.0
        defer { made.2.remove() }

        #expect(model.nickname == PopopxMeshNicknameStore.defaultNickname)
        model.nickname = "  Nobody  "
        await model.saveNickname()
        #expect(model.nickname == "Nobody")
        #expect(made.2.exists(PopopxMeshNicknameStore.fileName))

        model.nickname = "changed but not saved"
        model.reloadNickname()
        #expect(model.nickname == "Nobody")
    }

    @Test("A broadcast the radio refused still appears, and says why")
    func refusedBroadcastStaysLocal() async throws {
        let made = try makeModel(
            label: "plaza-refused",
            rejection: .radioUnavailable(.poweredOff)
        )
        let model = made.0
        defer { made.2.remove() }

        model.draft = "  still here  "
        await model.broadcastDraft()
        #expect(model.posts.map(\.text) == ["still here"])
        #expect(model.posts.first?.author == .local)
        #expect(model.lastFailure == .radioUnavailable(.poweredOff))
        #expect(model.draft.isEmpty)
        #expect(model.isSending == false)

        // A blank draft is not a post.
        model.draft = "   "
        await model.broadcastDraft()
        #expect(model.posts.count == 1)
    }

    @Test("A successful broadcast clears the failure")
    func successfulBroadcastClearsFailure() async throws {
        let made = try makeModel(label: "plaza-success")
        let model = made.0
        defer { made.2.remove() }

        model.draft = "first"
        await model.broadcastDraft()
        let sent = await made.1.sentBroadcasts
        #expect(sent == ["first"])
        #expect(model.lastFailure == nil)
    }

    @Test("The composer is enabled only when the radio can carry a draft")
    func canBroadcastNeedsRadioAndText() async throws {
        let directory = try PopopxMeshTestDirectory(label: "plaza-can")
        defer { directory.remove() }
        let source = PopopxMeshStateSource(hub: PopopxMeshEventHub())
        let model = PopopxMeshPlazaModel(
            outbound: PopopxMeshFakeOutbound(journal: PopopxMeshJournal()),
            source: source,
            nicknameStore: PopopxMeshNicknameStore(directory: directory.url)
        )
        model.start()
        defer { model.stop() }

        model.draft = "hello"
        // Nothing has been heard from the mirror yet, so the plaza cannot promise a delivery.
        #expect(model.canBroadcast == false)

        source.ingest(.bluetoothState(.poweredOn))
        try await popopxMeshWaitUntil("the radio state to reach the plaza") { model.radioState == .poweredOn }
        #expect(model.canBroadcast == true)

        source.ingest(.bluetoothState(.poweredOff))
        try await popopxMeshWaitUntil("the radio to go down") { model.radioState == .poweredOff }
        #expect(model.canBroadcast == false)
    }

    @Test("Two neighbours flooding the same id show once")
    func postsAreDedupedById() {
        let stamp = Date(timeIntervalSince1970: 100)
        let first = PopopxMeshPlazaPost(
            id: "same", text: "one", timestamp: stamp,
            author: .neighbour(nickname: "Ada", peerIDHex: PopopxMeshTestKeys.peerIDHex("a")),
            hopCount: 1
        )
        let duplicate = PopopxMeshPlazaPost(
            id: "same", text: "one", timestamp: stamp,
            author: .neighbour(nickname: "Bob", peerIDHex: PopopxMeshTestKeys.peerIDHex("b")),
            hopCount: 2
        )
        let mine = PopopxMeshPlazaPost(
            id: "mine", text: "two", timestamp: stamp.addingTimeInterval(1),
            author: .local, hopCount: 0
        )
        let deduped = PopopxMeshPlazaModel.deduped([first, duplicate, mine])
        #expect(deduped.map(\.id) == ["same", "mine"])
        #expect(deduped.first?.hopCount == 1)  // the copy heard first is the one kept
        #expect(deduped.last?.displayName == "You")
    }

    @Test("The scope line is the TTL the config carries, stated as a radius")
    func scopeIsFromConfig() throws {
        let made = try makeModel(label: "plaza-scope")
        let model = made.0
        defer { made.2.remove() }

        let hops = Int(PopopxMeshConfig.default.ttlDefault)
        #expect(model.scopeDescription == PopopxMeshReachEstimate.description(hops: hops))
        #expect(PopopxMeshReachEstimate.metres(hops: 7) == 7 * PopopxMeshReachEstimate.metresPerHop)
        #expect(PopopxMeshReachEstimate.radius(hops: 34) == "1.0 km")
        #expect(PopopxMeshReachEstimate.radius(hops: 1) == "30 m")
    }
}
