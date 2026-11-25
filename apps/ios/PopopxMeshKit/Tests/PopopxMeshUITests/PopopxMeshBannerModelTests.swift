//
//  PopopxMeshBannerModelTests.swift
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The banner's rules live in the view model, so they are asserted here rather than as pixels: which
//  banner wins when several could show, what each one says, and that an answer reaches module 3.
//

import Foundation
import Testing
@testable import PopopxMeshUI
import PopopxMeshKit

@MainActor
@Suite("PopopxMeshBannerModel")
struct PopopxMeshBannerModelTests {
    private struct Harness {
        let model: PopopxMeshBannerModel
        let pairing: PopopxMeshFakePairing
        let binding: PopopxMeshFakeBindingStore
        let routing: PopopxMeshFakeRouting
        let source: PopopxMeshStateSource
        let journal: PopopxMeshJournal
    }

    private func makeHarness(
        policy: MeshPairingPolicy = .manualConfirm,
        requests: [PopopxPairingRequest] = [],
        available: Bool = false,
        bound: Set<String> = []
    ) -> Harness {
        let journal = PopopxMeshJournal()
        let pairing = PopopxMeshFakePairing(journal: journal, requests: requests)
        let binding = PopopxMeshFakeBindingStore(policy: policy, journal: journal)
        let routing = PopopxMeshFakeRouting(available: available, bound: bound)
        let source = PopopxMeshStateSource(hub: PopopxMeshEventHub())
        let model = PopopxMeshBannerModel(pairing: pairing, binding: binding, routing: routing, source: source)
        return Harness(model: model, pairing: pairing, binding: binding, routing: routing, source: source, journal: journal)
    }

    @Test("A pending request raises the ask, and only the ask")
    func awaitingConfirmation() async throws {
        let request = PopopxMeshTestKeys.request(for: PopopxMeshTestKeys.peerA)
        let made = makeHarness(requests: [request])
        await made.model.refresh()

        let presentation = try #require(made.model.presentation)
        #expect(presentation.content.isAwaitingUser)
        #expect(presentation.actions == [.approve, .decline])
        #expect(presentation.peerMeshPublicKeyHex == PopopxMeshTestKeys.peerA)
        #expect(presentation.title.contains("pair"))
        // The invite link is never in the banner: module 3's queue holds it, and module 2 is the only
        // consumer. Saying so in the model is what keeps a future view from putting it on screen.
        #expect((presentation.detail ?? "").contains("popopx://") == false)
        #expect(made.model.requestAwaitingAnswer == request)
    }

    @Test("Two peers waiting are reported as one banner plus a count")
    func queuedPeersAreCounted() async throws {
        let older = PopopxMeshTestKeys.request(for: PopopxMeshTestKeys.peerA, link: "popopx://invite/a")
        let newer = PopopxMeshTestKeys.request(for: PopopxMeshTestKeys.peerB, link: "popopx://invite/b")
        let made = makeHarness(requests: [older, newer])
        await made.model.refresh()

        let presentation = try #require(made.model.presentation)
        guard case let .awaitingConfirmation(first, waiting) = presentation.content else {
            Issue.record("expected a confirmation ask, got \(presentation.content)")
            return
        }
        // The oldest question first, because that is the one whose sender is still waiting.
        #expect(first.peerMeshPublicKeyHex == PopopxMeshTestKeys.peerA)
        #expect(waiting == 2)
    }

    @Test("A question outranks a radio complaint")
    func requestBeatsRadio() async throws {
        let made = makeHarness(requests: [PopopxMeshTestKeys.request(for: PopopxMeshTestKeys.peerA)])
        made.model.start()
        defer { made.model.stop() }
        made.source.ingest(.bluetoothState(.poweredOff))
        try await popopxMeshWaitUntil("the radio state to land") { made.model.radioState == .poweredOff }
        await made.model.refresh()

        // Mixing them would mean dismissing two banners to reach the one that needs an answer.
        #expect(made.model.presentation?.content.isAwaitingUser == true)
        #expect(made.model.policy == .manualConfirm)
    }

    @Test("Nothing to ask and the radio down: the radio banner shows, and it can only be dismissed")
    func radioBanner() async throws {
        let made = makeHarness()
        made.source.ingest(.bluetoothState(.poweredOff))
        // The mirror pushes; the model does not poll its own radio state, so no `start()` needed:
        // ingest is synchronous on the main actor and the pump is what forwards it.
        made.model.start()
        defer { made.model.stop() }
        try await popopxMeshWaitUntil("the radio state to land") { made.model.radioState == .poweredOff }
        await made.model.refresh()

        let presentation = try #require(made.model.presentation)
        #expect(presentation.content == .radioUnavailable(.poweredOff))
        #expect(presentation.actions == [.dismiss])
        #expect(presentation.title == "Bluetooth is off")
    }

    @Test("Silent pairing is announced once, then stops announcing")
    func autoPairedNote() async throws {
        let made = makeHarness(policy: .autoSilent)
        // The banner's gate is the policy module 1 holds, and that policy is read, not assumed: a mounted
        // banner loads it on `start()`'s first tick. `refresh()` is the same read made now, so the note
        // below is judged against the store's `.autoSilent` rather than against the model's initial
        // `.manualConfirm`.
        await made.model.refresh()
        #expect(made.model.policy == .autoSilent)
        made.model.noteAutoPaired(peerMeshPublicKeyHex: PopopxMeshTestKeys.peerA)

        let presentation = try #require(made.model.presentation)
        #expect(presentation.content == .autoPaired(peerMeshPublicKeyHex: PopopxMeshTestKeys.peerA))
        #expect(presentation.actions == [.dismiss])
        #expect(presentation.title == "Paired automatically")

        made.model.dismiss()
        #expect(made.model.presentation == nil)
    }

    @Test("An auto-pair note is not shown while the policy is manual")
    func autoPairedNeedsThePolicy() async throws {
        let made = makeHarness(policy: .manualConfirm)
        await made.model.refresh()
        #expect(made.model.policy == .manualConfirm)
        made.model.noteAutoPaired(peerMeshPublicKeyHex: PopopxMeshTestKeys.peerA)
        // Nothing was asked and nothing completed, so the banner stays out of the way.
        #expect(made.model.presentation == nil)
    }

    @Test("A blocked send says what the user can do about it")
    func blockedOutbound() async throws {
        // Bound contact with a public route: the message still goes.
        let routed = makeHarness(
            available: true,
            bound: [PopopxMeshTestKeys.peerA]
        )
        await routed.model.noteOutboundBlocked(peerMeshPublicKeyHex: PopopxMeshTestKeys.peerA)
        let routedCopy = try #require(routed.model.presentation)
        #expect(routedCopy.content == .peerOutOfRange(
            peerMeshPublicKeyHex: PopopxMeshTestKeys.peerA,
            hasPublicRoute: true
        ))
        #expect(routedCopy.detail?.contains("public network") == true)

        // Unbound peer, no route: the public card was never exchanged, which is the case the red line cares about.
        let stranded = makeHarness()
        await stranded.model.noteOutboundBlocked(peerMeshPublicKeyHex: PopopxMeshTestKeys.peerB)
        let strandedCopy = try #require(stranded.model.presentation)
        #expect(strandedCopy.detail?.contains("public-network card") == true)
        #expect(strandedCopy.actions == [.dismiss])
    }

    @Test("Approving hands module 3 the request it queued, not a copy of the text")
    func approveForwardsTheRequest() async throws {
        let request = PopopxMeshTestKeys.request(for: PopopxMeshTestKeys.peerA)
        let made = makeHarness(requests: [request])
        await made.model.refresh()
        await made.model.approve()

        let answered = await made.pairing.answered
        #expect(answered.approved == [PopopxMeshTestKeys.peerA])
        // The queue emptied, so the next refresh has nothing to ask and the banner goes away.
        #expect(made.model.presentation == nil)
        #expect(made.journal.all.contains(where: { $0.hasPrefix("approve:") }))
    }

    @Test("Declining is enough on its own: module 3 records the refusal")
    func declineForwardsTheRequest() async throws {
        let request = PopopxMeshTestKeys.request(for: PopopxMeshTestKeys.peerB)
        let made = makeHarness(requests: [request])
        await made.model.refresh()
        await made.model.decline()

        let answered = await made.pairing.answered
        #expect(answered.declined == [PopopxMeshTestKeys.peerB])
        #expect(made.model.presentation == nil)
    }

    @Test("An answer when nothing is being asked does nothing")
    func answersWithoutAQuestion() async throws {
        let made = makeHarness()
        await made.model.refresh()
        await made.model.approve()
        await made.model.decline()
        let answered = await made.pairing.answered
        #expect(answered.approved.isEmpty)
        #expect(answered.declined.isEmpty)
    }

    @Test("The policy the banner reads is the policy the store holds")
    func policyIsNotCopied() async throws {
        let made = makeHarness(policy: .manualConfirm)
        await made.model.refresh()
        #expect(made.model.policy == .manualConfirm)

        await made.binding.setPairingPolicy(.autoSilent)
        await made.model.refresh()
        #expect(made.model.policy == .autoSilent)
    }

    @Test("Stopping the banner leaves nothing on screen")
    func stopClears() async throws {
        let made = makeHarness(requests: [PopopxMeshTestKeys.request(for: PopopxMeshTestKeys.peerA)])
        made.model.start()
        await made.model.refresh()
        #expect(made.model.presentation != nil)
        made.model.stop()
        #expect(made.model.presentation == nil)
        // A mounted-then-unmounted banner must not keep a consumer on the mirror, which is what the
        // fuse's `isFullyIdle` looks for.
        try await popopxMeshWaitUntil("the mirror consumer to be released") { made.source.consumerCount == 0 }
    }

    @Test("A key is shortened the same way module 3's logs quote it")
    func keyShortening() {
        #expect(PopopxMeshBannerModel.shorten(PopopxMeshTestKeys.peerA) == "\(String(repeating: "a", count: 16))…")
        #expect(PopopxMeshBannerModel.shorten("abc") == "abc")
    }

    @Test("Each radio state has its own words")
    func radioWords() {
        #expect(PopopxMeshBannerModel.radioTitle(.poweredOff) == "Bluetooth is off")
        #expect(PopopxMeshBannerModel.radioTitle(.unauthorized).contains("not granted"))
        #expect(PopopxMeshBannerModel.radioTitle(.unsupported).contains("no Bluetooth"))
        #expect(PopopxMeshBannerModel.radioTitle(.poweredOn) == "Bluetooth unavailable")
    }
}
