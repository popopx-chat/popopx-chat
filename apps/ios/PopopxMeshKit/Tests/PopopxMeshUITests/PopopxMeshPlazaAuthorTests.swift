//
//  PopopxMeshPlazaAuthorTests.swift
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  A plaza row is a person a host can act on — that is the whole reason the author's mesh public key
//  has to survive the reduction from traffic to a row. Three things were false until this round: the
//  key stopped at `PopopxMeshTimelineMessage` and never reached `PopopxMeshPlazaPost`; a stranger with
//  no announced name was labelled with its own message id, so two posts by one person read as two
//  people; and a row this device wrote carried no key, which is correct but was never pinned, so a
//  future default would have quietly offered the user a menu aimed at themselves.
//

import Foundation
import Testing
@testable import PopopxMeshUI
import PopopxMeshKit

@Suite("PopopxMeshPlazaAuthor")
@MainActor
struct PopopxMeshPlazaAuthorTests {
    private func makeModel(label: String) throws -> (model: PopopxMeshPlazaModel, directory: PopopxMeshTestDirectory) {
        let directory = try PopopxMeshTestDirectory(label: label)
        let model = PopopxMeshPlazaModel(
            outbound: PopopxMeshFakeOutbound(journal: PopopxMeshJournal()),
            source: PopopxMeshStateSource(hub: PopopxMeshEventHub()),
            nicknameStore: PopopxMeshNicknameStore(directory: directory.url)
        )
        return (model, directory)
    }

    private func message(
        id: String,
        peerIDHex: String?,
        keyHex: String?,
        nickname: String? = nil,
        tick: Int = 0
    ) -> PopopxMeshTimelineMessage {
        PopopxMeshTimelineMessage(
            messageID: id,
            // Distinct per row: the reduction orders by timestamp and then by id, and these tests read
            // the rows back in the order they were heard.
            timestamp: Date(timeIntervalSince1970: 100 + Double(tick)),
            text: "heard at \(id)",
            direction: .incoming,
            channel: .offlineMesh(hopCount: 1),
            senderNickname: nickname,
            senderPeerIDHex: peerIDHex,
            senderMeshPublicKeyHex: keyHex
        )
    }

    @Test("A row keeps the public key that is the only thing able to answer it")
    func reductionCarriesTheSendersPublicKey() throws {
        let made = try makeModel(label: "plaza-author-key")
        defer { made.directory.remove() }
        let key = PopopxMeshTestKeys.hex("a")
        let peerA = PopopxMeshTestKeys.peerIDHex("a")

        made.model.rebuildPosts(from: [
            message(id: "with-key", peerIDHex: peerA, keyHex: key, tick: 0),
            // The control: a sender heard before any handshake. If the field were filled from anything
            // other than the frame, this row would come back with a key too.
            message(id: "no-key", peerIDHex: PopopxMeshTestKeys.peerIDHex("b"), keyHex: nil, tick: 1),
        ])

        #expect(made.model.posts.count == 2)
        let withKey = try #require(made.model.posts.first { $0.id == "with-key" })
        let withoutKey = try #require(made.model.posts.first { $0.id == "no-key" })
        #expect(withKey.meshPublicKeyHex == key)
        #expect(withoutKey.meshPublicKeyHex == nil)
        // The 8-byte wire id stays what it was: the key is added to the row, never swapped in for it.
        #expect(withKey.displayName == peerA)
    }

    @Test("Two posts from one nameless stranger name one person, not two")
    func namelessPeerIsNamedOnce() throws {
        let made = try makeModel(label: "plaza-author-naming")
        defer { made.directory.remove() }

        made.model.rebuildPosts(from: [
            message(id: "first", peerIDHex: nil, keyHex: nil),
            message(id: "second", peerIDHex: nil, keyHex: nil),
        ])

        #expect(made.model.posts.count == 2)
        let names = Set(made.model.posts.map(\.displayName))
        #expect(names == [PopopxMeshNicknameStore.defaultNickname])
        // The old fallback labelled the row with the message's own id; that is what made one stranger
        // look like a crowd, and it is what these two ids are here to catch.
        #expect(!made.model.posts.contains { $0.displayName == "first" || $0.displayName == "second" })
    }

    @Test("An announced nickname still wins, and a wire id still names the row")
    func namedPeerIsNamedByItsName() throws {
        let made = try makeModel(label: "plaza-author-named")
        defer { made.directory.remove() }
        let peerIDHex = PopopxMeshTestKeys.peerIDHex("c")

        made.model.rebuildPosts(from: [
            message(id: "one", peerIDHex: peerIDHex, keyHex: nil, nickname: "Ada", tick: 0),
            message(id: "two", peerIDHex: peerIDHex, keyHex: nil, nickname: "  ", tick: 1),
        ])

        let named = try #require(made.model.posts.first { $0.id == "one" })
        let blank = try #require(made.model.posts.first { $0.id == "two" })
        #expect(named.displayName == "Ada")
        // A whitespace nickname is no nickname: the row falls back to the wire id, not to the blank.
        #expect(blank.displayName == peerIDHex)
    }

    @Test("This device's own rows are not somebody to reach")
    func localRowsCarryNoKey() async throws {
        let made = try makeModel(label: "plaza-author-local")
        defer { made.directory.remove() }

        made.model.draft = "from me"
        await made.model.broadcastDraft()

        let mine = try #require(made.model.posts.last)
        #expect(mine.author.isLocal)
        #expect(mine.meshPublicKeyHex == nil)
        // A neighbour row in the same reduction is the other half of the guard the host reads.
        made.model.rebuildPosts(from: [
            message(id: "neighbour", peerIDHex: PopopxMeshTestKeys.peerIDHex("d"), keyHex: PopopxMeshTestKeys.hex("d")),
        ])
        let theirs = try #require(made.model.posts.first { !$0.author.isLocal })
        #expect(theirs.meshPublicKeyHex == PopopxMeshTestKeys.hex("d"))
    }

    @Test("An injected action is answered per row, and says why when it cannot run")
    func actionContractIsPerRow() throws {
        var tapped: [String] = []
        let answerable = PopopxMeshPlazaAuthorAction(
            title: "answer",
            isAvailable: { $0.meshPublicKeyHex != nil },
            unavailableReason: "no key yet"
        ) { post in
            tapped.append(post.id)
        }
        let withKey = PopopxMeshPlazaPost(
            id: "reachable", text: "hi", timestamp: .now,
            author: .neighbour(nickname: nil, peerIDHex: PopopxMeshTestKeys.peerIDHex("e")),
            hopCount: 1, meshPublicKeyHex: PopopxMeshTestKeys.hex("e")
        )
        let withoutKey = PopopxMeshPlazaPost(
            id: "unreachable", text: "hi", timestamp: .now,
            author: .neighbour(nickname: nil, peerIDHex: PopopxMeshTestKeys.peerIDHex("f")),
            hopCount: 1
        )

        #expect(answerable.isAvailable(withKey))
        #expect(!answerable.isAvailable(withoutKey))
        #expect(answerable.unavailableReason == "no key yet")
        answerable.perform(withKey)
        #expect(tapped == ["reachable"])

        // The defaults are the read-only square's contract: a host that passes no predicate gets an
        // action that is never greyed and never silently disabled.
        var plainTapped = false
        let plain = PopopxMeshPlazaAuthorAction(title: "plain") { _ in plainTapped = true }
        #expect(plain.isAvailable(withoutKey))
        #expect(plain.unavailableReason == nil)
        plain.perform(withoutKey)
        #expect(plainTapped)
    }
}
