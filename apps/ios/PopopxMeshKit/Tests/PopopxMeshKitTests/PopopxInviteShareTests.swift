//
//  PopopxInviteShareTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The share formatter's contract. Every expectation is a spelled-out literal: "a share never
//  names its SMP server" is only proved if the test names the host that must not appear and the
//  address the code must open back to.
//

import Foundation
import Testing

@testable import PopopxMeshKit

private typealias Codec = PopopxOpaqueInviteCodec
private typealias Share = PopopxInviteShare

/// A full invitation address: it names the SMP host in its `smp=` parameter.
private let fullAddress = "https://popopx.chat/invitation#/?v=2&smp=smp%3A%2F%2F8yH7w55jipblnSA3Fk5l2T3BHFXTzZFvbX1CrsiDhBc%40smp7.popopx.im%2FAbCdEfGh0123456789IJKL&x3dh=MDEyMzQ1Njc4OQ%3D%3D"

/// The core's short form of the same invitation: the host moved into the query, it did not leave.
private let shortAddress = "popopx:/i#AbCdEfGh0123456789IJKL?h=smp1.popopx.im&p=5223&c=Zm9vYmFyYmF6"

/// The tappable spelling of `shortAddress`, which is what a share carries before sealing.
private let shortTappable = "https://popopx.chat/i#AbCdEfGh0123456789IJKL?h=smp1.popopx.im&p=5223&c=Zm9vYmFyYmF6"

private let pinnedNonce = Data((0..<Codec.nonceBytes).map { UInt8($0) })

@Suite("PopopxInviteShare")
struct PopopxInviteShareTests {

    private func pinned() -> (String) -> String? {
        { Codec.link(forURI: $0, nonce: pinnedNonce) }
    }

    /// Every literal a share must never carry, taken from the address it was made from.
    private func expectNoServerNamed(_ text: String) {
        #expect(text.hasPrefix(Codec.linkPrefix), "displayed \(text)")
        #expect(!text.contains("smp1.popopx.im"), "a share named its server: \(text)")
        #expect(!text.contains("smp7.popopx.im"), "a share named its server: \(text)")
        #expect(!text.contains("popopx.im"), "a share named its server: \(text)")
        #expect(!text.contains("%40smp"), "a share named its server: \(text)")
    }

    @Test("A full address is shared as the sealed code and opens back to itself")
    func fullAddressIsSealedAndRoundTrips() throws {
        let share = Share.make(fullLink: fullAddress, short: false, seal: pinned())
        #expect(share.sealed)
        #expect(share.fallback == fullAddress)
        #expect(share.original == fullAddress)
        expectNoServerNamed(share.display)
        #expect(try Codec.uri(fromLink: share.display) == fullAddress)
    }

    @Test("A short link is sealed too: its query names the server in plaintext")
    func shortAddressIsSealedAndRoundTrips() throws {
        let share = Share.make(fullLink: fullAddress, shortLink: shortAddress, short: true, seal: pinned())
        #expect(share.sealed, "a short link still names its SMP host in ?h=")
        #expect(share.fallback == shortTappable)
        #expect(share.original == shortTappable)
        expectNoServerNamed(share.display)
        #expect(try Codec.uri(fromLink: share.display) == shortTappable)
    }

    @Test("Which form is sealed follows the user's choice, and both are sealed")
    func bothFormsSealButCarryDifferentAddresses() throws {
        let full = Share.make(fullLink: fullAddress, shortLink: shortAddress, short: false, seal: pinned())
        let short = Share.make(fullLink: fullAddress, shortLink: shortAddress, short: true, seal: pinned())
        #expect(try Codec.uri(fromLink: full.display) == fullAddress)
        #expect(try Codec.uri(fromLink: short.display) == shortTappable)
        #expect(full.display != short.display)
    }

    @Test("An unsealable address falls back to its plain form rather than being lost")
    func unsealableShareFallsBack() {
        let oversized = "https://popopx.chat/i#" + String(repeating: "A", count: Codec.maxSealPlaintextBytes)
        let share = Share.make(fullLink: oversized, short: false, seal: pinned())
        #expect(!share.sealed)
        #expect(share.display == oversized)
        // A scheme the codec never mints behaves the same way.
        let relay = "smp://8yH7w55jipblnSA3Fk5l2T3BHFXTzZF@smp7.popopx.im/A1b2C3d4"
        let relayShare = Share.make(fullLink: relay, short: false, seal: pinned())
        #expect(!relayShare.sealed)
        #expect(relayShare.display == relay)
    }

    @Test("The tappable rewrite touches only the core's own scheme")
    func tappableRewritesOnlyTheCoreScheme() {
        #expect(Share.tappable("popopx:/a#k") == "https://popopx.chat/a#k")
        #expect(Share.tappable("popopx://popopx.chat/a#k") == "https://popopx.chat//popopx.chat/a#k")
        #expect(Share.tappable("https://popopx.chat/a#k") == "https://popopx.chat/a#k")
        #expect(Share.tappable("smp://h/a#k") == "smp://h/a#k")
    }

    @Test("The shared-link helper seals plain addresses and never re-seals a code")
    func sharedLinkPassesSealedThrough() throws {
        let sealed = Share.make(fullLink: fullAddress, short: false, seal: pinned()).display
        #expect(Share.sharedLink(forURI: sealed, seal: pinned()) == sealed)
        // A bare core scheme is rewritten before sealing, so the inner address is tappable.
        let fromShort = Share.sharedLink(forURI: shortAddress, seal: pinned())
        expectNoServerNamed(fromShort)
        #expect(try Codec.uri(fromLink: fromShort) == shortTappable)
        let fromFull = Share.sharedLink(forURI: fullAddress, seal: pinned())
        expectNoServerNamed(fromFull)
        #expect(try Codec.uri(fromLink: fromFull) == fullAddress)
        // Content the codec refuses is returned unchanged.
        #expect(Share.sharedLink(forURI: "smp://h/a#k", seal: pinned()) == "smp://h/a#k")
    }

    @Test("An empty link shares nothing and hides nothing")
    func emptyLinkStaysEmpty() {
        let share = Share.make(fullLink: "", short: true, seal: pinned())
        #expect(!share.sealed)
        #expect(share.display == "")
    }
}