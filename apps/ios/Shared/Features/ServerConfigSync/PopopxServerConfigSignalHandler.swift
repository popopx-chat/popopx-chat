//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
// POPOPX signed server cluster configuration — apply, prove, roll back.
//
// This is the only place in the app that changes the SMP server table because something a peer sent. It
// is deliberately the most conservative code path in the feature: an update is applied only when it can
// be undone, and it is kept only when it can be shown to work.
//
// The order is the design, and every step exists because of what happens if it is skipped:
//
//   1. verify the signature over the received bytes         — otherwise anyone could move this device
//   2. apply any revocation the frame declares, then refuse a generation at or below that key's floor
//                                                           — otherwise a redelivered message re-applies
//                                                            a superseded cluster
//   3. read the live table, merge, and have the core validate the result
//                                                           — the update merges, it never replaces, and
//                                                            the core is the authority on what it accepts
//   4. write the rollback snapshot to disk                  — if this fails, stop: an applied
//                                                            configuration with no way back is the one
//                                                            state this module must not produce
//   5. raise the floor, then replace the table              — the floor moves with the snapshot already on
//                                                            disk, so a crash cannot re-live it
//   6. watch the result, then keep it or restore            — a cluster that turns out to be dead is
//                                                            reverted before the user notices
//
// Nothing here reaches the user. No alert, no banner, and no row is left in the timeline: the frame is
// deleted internally once handled, and the only thing this module ever sends is itself a suppressed
// control frame.
//
// A frame may arrive in a group or a broadcast channel, and the asymmetry there is the point. The
// operator's first delivery layer is a group broadcast of the whole signed envelope, so refusing frames
// outside a one-to-one chat would refuse the primary channel — and safety does not depend on the chat, it
// depends on the signature over the body, which a group member cannot forge and cannot edit one byte of
// without the frame being refused. What must never happen on a group frame is the *uplink*: the receipt
// names this device to whoever receives it, and a group member other than the operator can both trigger
// one and read it as proof of who is running which cluster. So a receipt leaves this process only when
// the frame arrived in a direct chat.
//
// The one thing this module cannot report is a refusal. The receipt grammar carries a generation and,
// optionally, the hash of the body that was installed; there is no field for "rejected, because". That
// absence is why refusals stay silent here: reporting a refused generation with its number and no body
// hash is indistinguishable, on the operator's side, from a device that received and kept it.

import Foundation
import os
import POPOPXChat
import UIKit

/// What this device already knows, as data rather than as a call into the store.
///
/// A file-scope type on purpose: `decide` is `nonisolated` and reads these members, and a type nested in the
/// handler would put that under question; here nothing about it can inherit the handler's isolation.
struct PopopxServerConfigDecisionState: Sendable {
    /// Per signing key, the highest generation this device has acted on.
    let floors: [String: Int]
    /// Generations applied and then rolled back, spelled `kid|seq`. The breaker suppresses exactly those and
    /// nothing newer, so a corrected generation from the same key still lands.
    let broken: [String]

    init(floors: [String: Int] = [:], broken: [String] = []) {
        self.floors = floors
        self.broken = broken
    }

    /// The persisted state, read once so that the decision itself stays free of storage.
    static func current() -> PopopxServerConfigDecisionState {
        var floors: [String: Int] = [:]
        for floor in PopopxServerConfigStore.floors {
            floors[floor.kid] = floor.seq
        }
        return PopopxServerConfigDecisionState(
            floors: floors,
            broken: PopopxServerConfigStore.brokenEntries
        )
    }

    /// A key the device has never heard of starts at zero, which is what admits its first generation.
    func floor(for kid: String) -> Int {
        floors[kid] ?? 0
    }

    func isBroken(kid: String, seq: Int) -> Bool {
        broken.contains("\(kid)|\(seq)")
    }
}

@MainActor
final class PopopxServerConfigSignalHandler {
    static let shared = PopopxServerConfigSignalHandler()

    private let log = Logger(subsystem: "com.popopxchat.popopx", category: "server-config")

    /// The one probe window this process owns. Starting a second cancels the first: two windows judging
    /// the same table could roll back a configuration the later one proved good.
    private var probeTask: Task<Void, Never>?

    /// Keeps a second frame from being applied while the first is still in flight, which would otherwise
    /// snapshot a table that is already mid-change.
    private var applying = false

    /// Probe offsets: three seconds after the replacement, then ten — the brief's ten seconds, and
    /// roughly the point by which an unreachable host has failed to connect and a healthy one has
    /// finished. The counters read are `ServerSessions` (`AppAPITypes.swift:2543-2554`).
    private static let firstProbeNanoseconds: UInt64 = 3_000_000_000
    private static let secondProbeNanoseconds: UInt64 = 7_000_000_000

    /// The persisted state a decision is made against, injected so the arithmetic can be exercised without
    /// a store, a chat, or a device — including states a real device would take a key rotation to reach.
    typealias State = PopopxServerConfigDecisionState

    /// What the device does with a line that looked like a configuration frame.
    enum Decision: Sendable {
        /// Failed a check. The reason is logged, never sent to the sender or shown in the interface.
        case refused(PopopxServerConfigRejection)
        /// Verified, but not actionable: a generation the device will not act on, or one whose roster has
        /// just been rolled back. Still carries the frame, because the revocation floor it contains must be
        /// honoured and a receipt may still be owed.
        case stale(PopopxServerConfigFrame)
        /// Verified, unexpired, newer than the floor for its key, and ready to be installed.
        case frame(PopopxServerConfigFrame)
    }

    private init() {}

    // MARK: - Receive path

    /// The conversation a frame arrived in, and where a receipt for it would have to go.
    ///
    /// `chatType` decides whether a receipt may be sent at all; `chatId` is an `apiId` within that
    /// namespace, which is why the pair is always carried together.
    struct Source: Sendable {
        let chatType: PopopxServerConfigSourceChat
        let chatId: Int64

        /// A receipt can only be addressed to the operator, and the operator's side of this product is a
        /// one-to-one chat. Everything else — a group, a broadcast channel, a sender this device does not
        /// have in its contact list — receives nothing.
        var maySendReceipt: Bool {
            chatType == .direct
        }
    }

    /// Handles one text message, if and only if it is a configuration frame.
    ///
    /// Mounted beside the other silent routers in the receive path (`POPOPXAPI.swift:2779-2803`). The
    /// first line is all the work a normal message costs: a prefix test, no decoding.
    func observeIncoming(chatType: ChatType, chatId: Int64, itemId: Int64, text: String) async {
        guard PopopxServerConfigWire.isControlText(text) else { return }
        let source = Source(chatType: chatType == .direct ? .direct : .group, chatId: chatId)
        switch Self.decide(
            text: text,
            now: Int(Date().timeIntervalSince1970),
            state: State.current()
        ) {
        case let .refused(reason):
            // No receipt for a refusal, for the two independent reasons at the top of this file: the
            // grammar cannot express one, and naming the check that caught a forgery hands the attacker an
            // oracle. The frame is still deleted below, so a refused line cannot accumulate.
            log.error("server config: frame refused, \(reason.rawValue, privacy: .public)")
        case let .stale(frame):
            // A generation the device will not act on can still carry the instruction that voids the one it
            // holds, so the revocation is applied here too rather than only on the path that installs.
            applyRevocation(frame: frame)
            log.info("server config: generation \(frame.payload.seq, privacy: .public) superseded")
            if Self.owesReceipt(policy: frame.payload.policy, source: source) {
                await sendReceipt(PopopxServerConfigPendingAck(
                    kid: frame.payload.keyId,
                    seq: frame.payload.seq,
                    // No body hash: the device did not install this configuration, and the hash is the
                    // half of a receipt that claims it did.
                    bodyHash: nil,
                    chatType: source.chatType,
                    chatId: source.chatId
                ))
            }
        case let .frame(frame):
            applyRevocation(frame: frame)
            if applying || UIApplication.shared.applicationState != .active {
                // Not now: keep the received line and apply when the device can watch the result. The
                // staged frame is re-verified and re-decided on promotion, so this is a delay and not a
                // concession.
                if PopopxServerConfigStore.stage(PopopxServerConfigStagedFrame(
                    segment: text,
                    chatType: source.chatType,
                    chatId: source.chatId
                )) {
                    log.info("server config: frame staged for a session that can watch the result")
                } else {
                    log.error("server config: frame could not be staged, dropped")
                }
            } else {
                await apply(frame: frame, source: source)
            }
        }
        await deleteRow(chatId: chatId, itemId: itemId)
    }

    // MARK: - Decision

    /// Verification, revocation and floor, decided apart from every side effect.
    ///
    /// The floor the comparison uses is not simply the stored one: a frame's own `pol.ms` voids every
    /// generation below it, which is how the operator keeps a device that already moved forward from
    /// sliding back to an older cluster. Reading the frame first and the store second is what makes that
    /// possible without a second pass.
    nonisolated static func decide(text: String, now: Int, state: State) -> Decision {
        switch PopopxServerConfigWire.decodeConfigFrame(text, now: now) {
        case let .failure(reason):
            return .refused(reason)
        case let .success(frame):
            return classify(frame: frame, state: state)
        }
    }

    /// The same decision over a frame that has already verified, split out because the app cannot sign: no
    /// test target can reach `decide` past the signature, so the arithmetic below would otherwise be
    /// provable only on a device holding the production key.
    ///
    /// The floor is `max(stored, ms - 1)`: a revocation may only raise the baseline this key has already left
    /// behind, never lower it. The `min` reading made a withdrawal of generation 9 deliverable to a device
    /// that had moved to 12, and with the shipped `min_seq: 1` it drove every comparison to zero, so any
    /// still-unexpired older generation could be replayed back onto the device by whoever holds the signing
    /// key. The corrected cluster a withdrawal is followed by always carries a higher generation, so nothing
    /// the operator has to be able to do depends on that downward move.
    nonisolated static func classify(frame: PopopxServerConfigFrame, state: State) -> Decision {
        let payload = frame.payload
        let effectiveFloor = max(state.floor(for: payload.keyId), max(payload.policy.minSeq - 1, 0))
        guard payload.seq > effectiveFloor, !state.isBroken(kid: payload.keyId, seq: payload.seq) else {
            return .stale(frame)
        }
        return .frame(frame)
    }

    /// Whether this frame obliges the device to send a receipt, in the conversation it arrived in.
    ///
    /// Both halves are required and both belong to this single question rather than to each of the four
    /// places a receipt is owed: the operator asked for acknowledgements, and the frame came from a
    /// one-to-one with the config bot. A group or a broadcast channel never qualifies — that is item 2 of
    /// the brief stated once instead of four times, where four chances to drift is four ways for an
    /// acknowledgements storm to come back.
    nonisolated static func owesReceipt(
        policy: PopopxServerConfigPolicy,
        source: Source
    ) -> Bool {
        policy.ack && source.maySendReceipt
    }

    /// Persists the revocation a frame declares, so the next frame from this key is measured against it
    /// even if this process never sees another one.
    ///
    /// Called for every verified frame, including the stale ones: the generation the device will not act on
    /// is frequently the one carrying the withdrawal of the generation it does hold. Scoped to the key that
    /// verified, because a ratchet written for one rotation must not silently void another key's history.
    private func applyRevocation(frame: PopopxServerConfigFrame) {
        let payload = frame.payload
        guard payload.policy.minSeq > PopopxServerConfigStore.floor(for: payload.keyId) else { return }
        if PopopxServerConfigStore.revoke(kid: payload.keyId, below: payload.policy.minSeq) {
            log.info("server config: generations below \(payload.policy.minSeq, privacy: .public) revoked for \(payload.keyId, privacy: .public)")
        }
    }

    // MARK: - Apply

    private func apply(frame: PopopxServerConfigFrame, source: Source) async {
        applying = true
        defer { applying = false }

        let payload = frame.payload
        let kid = payload.keyId
        let seq = payload.seq
        guard ChatModel.shared.currentUser != nil else {
            log.error("server config: no signed-in user, nothing applied")
            return
        }

        // Every SMP entry becomes one row. The addresses come from the app's own address type rather than
        // a second formatter here: `ServerAddress.uri` is the spelling every server row already uses
        // (`APITypes.swift:226-236`), and a private version of it would be a new wire format.
        var uris: [String] = []
        for entry in payload.smpServers {
            guard let uri = Self.serverURI(for: entry) else {
                // One unusable entry fails the whole frame. Installing four of five servers and reporting
                // the generation as applied would leave the device believing it holds a cluster that the
                // operator never finished describing.
                log.error("server config: a server entry could not be turned into an address")
                return
            }
            if !uris.contains(uri) { uris.append(uri) }
        }
        guard !uris.isEmpty else {
            log.error("server config: the frame names no usable server")
            return
        }

        guard let current = try? await getUserServers() else {
            log.error("server config: the server table could not be read")
            return
        }
        let owned = PopopxServerConfigStore.introducedURIs
        guard let merge = Self.mergedServers(current, adding: uris, replacingOwned: owned) else {
            log.error("server config: no server group could hold this cluster")
            return
        }
        if merge.servers == current {
            // The exact cluster is already installed — usually a rotation, where a new key re-signs the
            // servers the previous one introduced. Raising the floor without touching the table is the
            // honest answer, and ownership is carried over unchanged so the rows that are already there
            // stay removable. There is nothing to prove, so the window opens already closed.
            PopopxServerConfigStore.markAccepted(kid: kid, seq: seq, introducedURIs: owned)
            PopopxServerConfigStore.markVerified()
            log.info("server config: generation \(seq, privacy: .public) was already installed")
            if Self.owesReceipt(policy: payload.policy, source: source) {
                await sendReceipt(PopopxServerConfigPendingAck(
                    kid: kid,
                    seq: seq,
                    bodyHash: frame.bodyHash,
                    chatType: source.chatType,
                    chatId: source.chatId
                ))
            }
            return
        }

        if let validation = try? await validateServers(userServers: merge.servers), !validation.0.isEmpty {
            // Errors only. The warnings this app can raise for a server table (no chat relays, no name
            // servers) are not caused by adding an SMP row, and refusing on one would blame the operator's
            // cluster for the device's own configuration.
            log.error("server config: the core refused the merged table, \(validation.0.count, privacy: .public) validation errors")
            return
        }

        guard PopopxServerConfigStore.writeRollback(PopopxServerConfigSnapshot(
            kid: kid,
            seq: seq,
            introducedURIs: owned,
            servers: current
        )) else {
            log.error("server config: no rollback slot could be written, refusing to apply")
            return
        }
        let newlyOwned = Self.ownedURIs(after: merge, requested: uris, previouslyOwned: owned)
        PopopxServerConfigStore.markAccepted(kid: kid, seq: seq, introducedURIs: newlyOwned)
        do {
            try await setUserServers(userServers: merge.servers)
        } catch {
            // The replacement never landed, so the live table is still the one in the snapshot: no restore
            // call is needed, only a burned generation. A core that rejects this table will reject it every
            // time it is offered.
            PopopxServerConfigStore.markRolledBack(kid: kid, seq: seq)
            PopopxServerConfigStore.clearRollback()
            log.error("server config: the core rejected the replacement")
            return
        }
        // Re-read so the core's ids for the new rows are known to the device. Skipping this is what breaks
        // deleting a newly added server later, which the manual save flow calls out in as many words
        // (`NetworkAndServers.swift:495-497`).
        _ = try? await getUserServers()
        do {
            try await resetAgentServersStats()
        } catch {
            log.error("server config: session stats not reset, the window will rely on the direct test")
        }
        if Self.owesReceipt(policy: payload.policy, source: source) {
            // Durable, not in-memory: the verdict at the end of the window is exactly the thing a
            // backgrounded process interrupts, and the rollback is the outcome the operator most needs to
            // hear about.
            PopopxServerConfigStore.pendingAck = PopopxServerConfigPendingAck(
                kid: kid,
                seq: seq,
                bodyHash: frame.bodyHash,
                chatType: source.chatType,
                chatId: source.chatId
            )
        }
        log.info("server config: generation \(seq, privacy: .public) applied, probing \(uris.count, privacy: .public) servers")
        beginProbeWindow(uris: uris)
    }

    /// The address for one entry, or nil when neither spelling of its key is an address this core accepts.
    ///
    /// Both spellings are tried because the two halves of this product disagree, unverifiably from here,
    /// about padding. The signature covers an unpadded fingerprint, and the roster the operator publishes
    /// is written padded; the shipped factory presets in this repository are padded too
    /// (`src/Popopx/Chat/Operators/Presets.hs:54-64`), which is the only direct evidence available about
    /// what the core parses. The padded form is offered first on that evidence, and a device that has to
    /// fall back says so in the log rather than silently installing a different string from the one the
    /// operator published.
    private static func serverURI(for entry: PopopxServerEntry) -> String? {
        for key in [padded(entry.key), entry.key] {
            let address = ServerAddress(
                serverProtocol: .smp,
                hostnames: entry.hostnames,
                port: "",
                keyHash: key,
                basicAuth: ""
            )
            guard address.valid, parseServerAddress(address.uri) != nil else { continue }
            return address.uri
        }
        return nil
    }

    /// base64url of 32 bytes is 43 characters and one `=` completes it. Anything else is passed through:
    /// the decoder does not require padding, and inventing a different amount would be worse than none.
    private static func padded(_ key: String) -> String {
        key.count == 43 ? key + "=" : key
    }

    /// Which URIs this mechanism may delete on a later update.
    ///
    /// A row that was already in the table and was not ours stays not-ours: a user who added the same
    /// server by hand keeps it, and the signed frame must not acquire the right to remove it. Rows the
    /// merge actually inserted, and rows this mechanism introduced earlier and the new roster still names,
    /// are the two kinds it owns.
    nonisolated static func ownedURIs(
        after merge: (servers: [UserOperatorServers], introduced: [String]),
        requested uris: [String],
        previouslyOwned owned: [String]
    ) -> [String] {
        uris.filter { uri in
            merge.introduced.contains(uri) || owned.contains(uri)
        }
    }

    /// Merges a cluster into the table without touching anything the mechanism did not introduce.
    ///
    /// Nil means "there is no correct place for one of these rows", which the caller must treat as a
    /// refusal — returning the input unchanged would be mistaken for "nothing to do".
    ///
    /// Removal is bounded by the owned-URI list, never by `preset` and never by protocol: the user's own
    /// servers, the shipped defaults, XFTP rows and chat relays are copied through untouched. `preset` is
    /// the core's own flag and is true for the installation's default servers, so claiming by it would let
    /// a signed frame delete rows the app itself put there. A row the new roster still names survives the
    /// sweep, which is what keeps a rotation from deleting and re-adding the same server — and, with it,
    /// from throwing away the core's test result for that row. Placement follows the manual add flow
    /// (`NewServerView.swift:102-135`): the operator whose domain the hostname suffixes, or the
    /// nil-operator group when it matches nobody.
    nonisolated static func mergedServers(
        _ current: [UserOperatorServers],
        adding uris: [String],
        replacingOwned owned: [String]
    ) -> (servers: [UserOperatorServers], introduced: [String])? {
        var merged = current.map { group -> UserOperatorServers in
            var mutable = group
            mutable.smpServers = group.smpServers.filter { row in
                !owned.contains(row.server) || uris.contains(row.server)
            }
            return mutable
        }
        var introduced: [String] = []
        for uri in uris {
            let alreadyPresent = merged.contains { group in
                group.smpServers.contains { row in row.server == uri }
            }
            if alreadyPresent { continue }
            let row = UserServer(server: uri, preset: false, tested: nil, enabled: true, deleted: false)
            guard let (serverProtocol, matchingOperator) = serverProtocolAndOperator(row, current) else { return nil }
            guard serverProtocol == .smp else { return nil }
            guard let index = merged.firstIndex(where: { $0.operator?.operatorId == matchingOperator?.operatorId }) else {
                return nil
            }
            merged[index].smpServers.append(row)
            introduced.append(uri)
        }
        return (merged, introduced)
    }

    // MARK: - Probe window

    private func beginProbeWindow(uris: [String]) {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.firstProbeNanoseconds)
            guard !Task.isCancelled else { return }
            // Early success is decisive and worth taking; early failure proves nothing yet, so the first
            // look can only end the window positively.
            if await self.clusterVerdict(uris: uris) == .reachable {
                await self.finishVerified()
                return
            }
            try? await Task.sleep(nanoseconds: Self.secondProbeNanoseconds)
            guard !Task.isCancelled else { return }
            guard UIApplication.shared.applicationState == .active else {
                // Backgrounded inside the window: decide nothing. iOS leaves about thirty seconds, which is
                // not enough to distinguish a slow network from a dead one, and `settlePendingWindow`
                // finishes the job on the next foreground.
                self.log.info("server config: probe window left open, application is not active")
                return
            }
            switch await self.clusterVerdict(uris: uris) {
            case .reachable:
                await self.finishVerified()
            case .unreachable:
                await restore()
            case .inconclusive:
                self.log.info("server config: probe inconclusive, the window stays open")
            }
        }
    }

    /// One look at the introduced cluster as a whole.
    ///
    /// A cluster is a set of servers reached through several names, and the device is healthy when it is
    /// connected to any of them, so one positive answer ends the window. Ending it negatively takes every
    /// answer being negative: a roster with one dead address and five unknown ones is not evidence that
    /// the cluster does not work, and rolling back on that would let a single broken machine retire a
    /// whole generation.
    private func clusterVerdict(uris: [String]) async -> PopopxServerConfigProbeVerdict {
        var verdicts: [PopopxServerConfigProbeVerdict] = []
        for uri in uris {
            let verdict = await probeVerdict(uri: uri)
            if verdict == .reachable { return .reachable }
            verdicts.append(verdict)
        }
        guard !verdicts.isEmpty, verdicts.allSatisfy({ $0 == .unreachable }) else { return .inconclusive }
        return .unreachable
    }

    /// One look at one address: session counters first, a direct test when they are silent.
    private func probeVerdict(uri: String) async -> PopopxServerConfigProbeVerdict {
        // The summary call is a synchronous core round-trip. The servers sheet reads it from a one second
        // timer on the main actor (`Shared/Views/ChatList/ServersSummaryView.swift:67-73`), so a handful of
        // reads per applied update is inside a pattern the app already accepts. A detached hop would need
        // `PresentedServersSummary` to be `Sendable`, which these generated Codable types are not, and
        // inventing a conformance to satisfy the compiler is not the same as proving one. The counters
        // cover every server the device has, so in practice the first pass answers for the whole cluster.
        if let summary = try? getAgentServersSummary() {
            let verdict = Self.judge(summary: summary, uri: uri)
            if verdict != .inconclusive { return verdict }
        }
        guard let result = try? await testProtoServer(server: uri) else {
            // A thrown error means the test itself did not run, which the manual test flow also treats as
            // "no verdict" rather than "failed" (`ProtocolServerView.swift:226-231`).
            return .inconclusive
        }
        switch result {
        case .success: return .reachable
        case let .failure(failure):
            // Any recorded failure is decisive here, including `.AUTH` and a certificate mismatch: all of
            // them mean this device cannot use this address, which is what a rollback is for.
            log.error("server config: direct test failed at \(String(describing: failure.testStep), privacy: .public)")
            return .unreachable
        }
    }

    /// Reads the session counters for the introduced cluster.
    ///
    /// Matching is derived from the URI being installed rather than from any brand rule, and the tolerance
    /// is only about shape: `SMPServerSummary.smpServer` is written by the core, and its exact spelling is
    /// not defined anywhere in this repository's Swift sources, so the URI itself is tried first and its
    /// hostnames second. What must never happen is a rollback decided by a row that was not found — an
    /// idle device has sessions for nothing.
    nonisolated static func judge(summary: PresentedServersSummary, uri: String) -> PopopxServerConfigProbeVerdict {
        judge(rows: summary.currentUserSMP.currentlyUsedSMPServers
              + summary.currentUserSMP.previouslyUsedSMPServers
              + summary.currentUserSMP.onlyProxiedSMPServers,
              uri: uri)
    }

    /// The same decision over the rows themselves.
    ///
    /// Split out because a `PresentedServersSummary` cannot be built by anything that is not the agent:
    /// `AgentSMPServerStatsData` has 33 required integers and no defaults. The rule about which rows count
    /// is the part worth testing, and it belongs to the rows, not to the wrapper around them.
    nonisolated static func judge(rows: [SMPServerSummary], uri: String) -> PopopxServerConfigProbeVerdict {
        let hostnames = uri.components(separatedBy: "@").last?
            .components(separatedBy: ",")
            .filter { !$0.isEmpty }
            .map { $0.lowercased() } ?? []
        // The URI itself, then a row whose host is exactly one of the names once any port the core appended
        // is removed. A `contains` test would let a foreign row that merely embeds one of these names
        // answer for the cluster, and in the reachable direction that is the one mistake this window cannot
        // afford: it would close positively on a configuration that never worked. A missed row answers
        // inconclusive and leaves the window open, which is the safe side of the same ambiguity.
        let mine = rows.filter { row in
            let server = row.smpServer.lowercased()
            if server == uri.lowercased() { return true }
            return hostnames.contains(server.components(separatedBy: ":").first ?? "")
        }
        guard let sessions = mine.compactMap({ $0.sessions }).first else { return .inconclusive }
        if sessions.ssConnected > 0 { return .reachable }
        if sessions.ssErrors > 0 { return .unreachable }
        return .inconclusive
    }

    private func finishVerified() async {
        PopopxServerConfigStore.markVerified()
        PopopxServerConfigStore.clearRollback()
        log.info("server config: configuration verified")
        await settleReceipt()
    }

    /// Returns the table to the snapshot taken before the update.
    ///
    /// The generation to burn comes from the snapshot rather than from the caller, because by the time a
    /// window ends the process may have restarted and the only trustworthy record of what was applied is
    /// the record that made the rollback possible.
    private func restore() async {
        guard let snapshot = PopopxServerConfigStore.readRollback() else {
            log.error("server config: the probe failed with no snapshot held, the table is left as it is")
            return
        }
        probeTask?.cancel()
        do {
            try await setUserServers(userServers: snapshot.servers)
        } catch {
            // The old table did not go back, so the device is still running the cluster that failed to prove
            // itself. Nothing is burned and nothing is cleared: the window stays pending, and the next launch
            // runs this restore again. A rollback recorded as done while the live table says otherwise is the
            // one outcome worse than not attempting it, because it is the record the operator reads.
            log.error("server config: the previous table could not be restored, the snapshot is kept")
            return
        }
        _ = try? await getUserServers()
        // Ownership goes back with the table: the rows the failed update added are gone, and the rows it
        // would have removed are present again and still ours.
        PopopxServerConfigStore.setIntroducedURIs(snapshot.introducedURIs)
        PopopxServerConfigStore.markRolledBack(kid: snapshot.kid, seq: snapshot.seq)
        PopopxServerConfigStore.clearRollback()
        log.error("server config: generation \(snapshot.seq, privacy: .public) rolled back after a failed probe")
        await settleReceipt()
    }

    // MARK: - Launch promotion

    /// Settles a window the previous process never finished, then applies anything that was staged.
    ///
    /// Called from the tab bar's appearance, not from `init`: both halves need a signed-in user, and the
    /// staged half needs the chat list loaded before it can deliver the promised receipt.
    func promoteStagedIfNeeded() async {
        guard ChatModel.shared.currentUser != nil else { return }
        await settlePendingWindow()
        guard let staged = PopopxServerConfigStore.takeStaged() else { return }
        let source = Source(chatType: staged.chatType, chatId: staged.chatId)
        let now = Int(Date().timeIntervalSince1970)
        switch Self.decide(text: staged.segment, now: now, state: State.current()) {
        case let .refused(reason):
            // Staged bytes that no longer verify are discarded, not retried: the only honest reading is
            // that they were never valid. An expiry that passed while the frame waited lands here too,
            // which is why the staged record keeps the received line instead of the decoded payload.
            log.error("server config: staged frame refused, \(reason.rawValue, privacy: .public)")
        case let .stale(frame):
            applyRevocation(frame: frame)
            if Self.owesReceipt(policy: frame.payload.policy, source: source) {
                await sendReceipt(PopopxServerConfigPendingAck(
                    kid: frame.payload.keyId,
                    seq: frame.payload.seq,
                    bodyHash: nil,
                    chatType: source.chatType,
                    chatId: source.chatId
                ))
            }
        case let .frame(frame):
            applyRevocation(frame: frame)
            // The operator's own patience limit, applied to the only path that can exceed it. A frame held
            // past its install window is dropped rather than installed: a generation the operator has
            // moved on from is exactly what a delayed install would put back.
            let waited = TimeInterval(now) - staged.receivedAt.timeIntervalSince1970
            guard waited <= TimeInterval(frame.payload.policy.installWindowSeconds) else {
                log.error("server config: staged frame outlived its install window")
                return
            }
            log.info("server config: promoting a staged frame")
            await apply(frame: frame, source: source)
        }
    }

    /// Closes a window that was interrupted, and drops a snapshot that no update owns.
    private func settlePendingWindow() async {
        guard PopopxServerConfigStore.verdict == .pending,
              !PopopxServerConfigStore.introducedURIs.isEmpty else {
            // A snapshot with no pending update describes a table that was never left behind — usually a
            // process killed between writing the snapshot and raising the floor. Holding it would let a
            // later failure restore the wrong moment.
            if PopopxServerConfigStore.verdict != .pending,
               PopopxServerConfigStore.existingRollbackSequence() != nil {
                PopopxServerConfigStore.clearRollback()
            }
            await settleReceipt()
            return
        }
        switch await clusterVerdict(uris: PopopxServerConfigStore.introducedURIs) {
        case .reachable:
            await finishVerified()
        case .unreachable:
            await restore()
        case .inconclusive:
            // Still no evidence: leave the window open rather than keep a configuration that was never
            // proven. A relaunch into a working network settles it; one into a broken network rolls it
            // back. The snapshot, not this function, is what makes either outcome possible.
            log.info("server config: the pending window is still unresolved")
        }
    }

    /// Sends the receipt the store is holding, if any, and only once.
    ///
    /// Reached from both ends of the probe window and from a launch that interrupted one, which is the
    /// only way a verdict reached in a process that then died still produces a receipt. `claimAck` is what
    /// makes the three call sites safe to leave in place.
    private func settleReceipt() async {
        guard let pending = PopopxServerConfigStore.pendingAck else { return }
        guard pending.seq == PopopxServerConfigStore.floor(for: pending.kid) else {
            // The receipt belongs to a generation the device has moved past. Dropping it rather than
            // sending it late keeps an operator's count of acknowledged devices honest.
            PopopxServerConfigStore.pendingAck = nil
            return
        }
        PopopxServerConfigStore.pendingAck = nil
        await sendReceipt(pending)
    }

    // MARK: - Receipt

    /// Sends one receipt, at most once per generation per conversation.
    ///
    /// The claim is taken before the send and released if it fails, making the receipt at-most-once with a
    /// retry path rather than at-least-once: two receipts for one generation would be counted by an
    /// operator as two devices. The direct-chat test lives here as well as at the call sites, so that a
    /// future caller cannot reintroduce the uplink this feature promises never to send into a group.
    private func sendReceipt(_ ack: PopopxServerConfigPendingAck) async {
        guard ack.chatType == .direct else {
            log.info("server config: receipt suppressed, the frame did not arrive in a direct chat")
            return
        }
        guard PopopxServerConfigStore.claimAck(for: ack) else { return }
        guard let text = PopopxServerConfigWire.ackFrame(seq: ack.seq, bodyHash: ack.bodyHash) else {
            PopopxServerConfigStore.releaseAckClaim(for: ack)
            return
        }
        guard let chat = ChatModel.shared.getContactChat(ack.chatId) else {
            log.error("server config: the receipt has no chat to go into")
            PopopxServerConfigStore.releaseAckClaim(for: ack)
            return
        }
        let items = await apiSendMessages(
            type: chat.chatInfo.chatType,
            id: chat.chatInfo.apiId,
            scope: chat.chatInfo.groupChatScope(),
            sendAsGroup: chat.chatInfo.sendAsGroup,
            live: false,
            ttl: nil,
            sign: false,
            composedMessages: [ComposedMessage(msgContent: .text(text))]
        )
        guard let items, !items.isEmpty else {
            // `apiSendMessages` does not throw: it returns nothing when the message did not go out, and an
            // empty result is the failure (`POPOPXAPI.swift:588`, same reading as the signaling router's
            // send at `PopopxSilentSignalingRouter.swift:680-683`).
            log.error("server config: the receipt was not delivered")
            PopopxServerConfigStore.releaseAckClaim(for: ack)
            return
        }
        for item in items {
            ChatModel.shared.addChatItem(chat.chatInfo, item)
        }
    }

    // MARK: - Row deletion

    /// Removes this device's row for a handled frame.
    ///
    /// `.cidmInternal`, for the reason the signaling router records for the same choice
    /// (`PopopxSilentSignalingRouter.swift:690-693`): a broadcast deletion would tell the sender that a
    /// configuration frame arrived, which is a fact this feature does not disclose. The model is updated as
    /// well, because suppression only stops a row from rendering — it does not remove one already in the
    /// timeline.
    ///
    /// This duplicates the router's `deleteSignal` and `send` instead of calling them because both are
    /// `private` there; borrowing twenty lines would mean opening another feature's internals.
    private func deleteRow(chatId: Int64, itemId: Int64) async {
        let model = ChatModel.shared
        guard let chat = model.chats.first(where: { $0.chatInfo.apiId == chatId }) else { return }
        guard let deletions = try? await apiDeleteChatItems(
            type: chat.chatInfo.chatType,
            id: chat.chatInfo.apiId,
            scope: chat.chatInfo.groupChatScope(),
            itemIds: [itemId],
            mode: .cidmInternal
        ) else {
            log.error("server config: the row could not be deleted, it stays suppressed but present")
            return
        }
        for deletion in deletions {
            if let toItem = deletion.toChatItem {
                _ = model.upsertChatItem(toItem.chatInfo, toItem.chatItem)
            } else {
                model.removeChatItem(deletion.deletedChatItem.chatInfo, deletion.deletedChatItem.chatItem)
            }
            model.updateChatInfo(deletion.deletedChatItem.chatInfo)
        }
    }

    // MARK: - Official subscriptions

    /// Join the two conversations the signed configuration travels over: once per profile, and with
    /// nothing presented to the user.
    ///
    /// The channel is where `SERVER_CFG_V1` arrives; the service account is where the receipt for an
    /// applied generation goes, which is the reason `Source.maySendReceipt` insists on a one-to-one chat.
    /// Both are ordinary conversations as far as the core is concerned, so they are joined with the same
    /// plan the link-opening flow uses: the plan is the only call that turns a short link into the link the
    /// core connects with, and the only one that answers "this connection already exists" *before* a
    /// second one is made.
    ///
    /// The marker is written before the first request goes out, not after the last one succeeds. A profile
    /// that joined the channel and then lost the process must not rejoin it on the next launch, and a user
    /// who later leaves either conversation must never be put back into it. What that costs is a
    /// subscription that failed at its only attempt: a device whose server was unreachable on its first
    /// launch stays unsubscribed until a frame arrives some other way. The trade is the one the feature
    /// asks for, and the failure is logged rather than hidden so it is at least diagnosable.
    func seedOfficialSubscriptions() async {
        guard let userId = ChatModel.shared.currentUser?.userId else { return }
        guard !PopopxServerConfigStore.officialSubscriptionSeeded(userId: userId) else { return }
        PopopxServerConfigStore.markOfficialSubscriptionSeeded(userId: userId)
        await joinOfficial(PopopxOfficialConfigLinks.officialConfigChannelURI)
        await joinOfficial(PopopxOfficialConfigLinks.officialConfigBotURI)
    }

    /// One address, planned and joined without a dialog, a sheet, or a change to the open chat.
    ///
    /// The `api*` wrappers are unusable here, and the reason is the requirement rather than taste:
    /// `apiConnect` loads a chat and raises an alert when the contact is already there
    /// (`POPOPXAPI.swift:1100-1105`), the plan and both prepared-connection calls raise one on any error
    /// (`:1084`, `:1108`, `:1269`, `:1276`), and `chatApiSendCmdWithRetry` raises a retry prompt whenever
    /// no progress box is passed to it (`:145-158`). So those three steps are issued directly with
    /// `chatSendCmd`, which throws instead of speaking. `apiPrepareContact` and `apiPrepareGroup` are
    /// called as they are: they already only throw (`:1240`, `:1247`), and rewriting them would duplicate
    /// a wire request for no gain.
    ///
    /// A plan that answers anything other than "join this" is left alone. The cases that report an
    /// existing connection return quietly; the cases with no silent recipe - link data the server did not
    /// give, a group whose relay list needs a decision - are logged and skipped rather than guessed at,
    /// because a half-made conversation in the chat list is worse than a missing one.
    private func joinOfficial(_ uri: String) async {
        guard let userId = ChatModel.shared.currentUser?.userId else { return }
        do {
            let planned: ChatResponse1 = try await chatSendCmd(
                .apiConnectPlan(userId: userId, connLink: uri, resolveMode: .unknown, linkOwnerSig: nil)
            )
            guard case let .connectionPlan(_, connLink, _, _, plan) = planned else { throw planned.unexpected }
            switch plan {
            case let .contactAddress(cap):
                switch cap {
                case .known, .ownLink, .connectingConfirmReconnect, .connectingProhibit, .contactViaAddress:
                    log.debug("server config: the official service account is already connected")
                case .ok(let sLinkData, _):
                    guard let data = sLinkData else {
                        log.error("server config: the official service account planned without link data")
                        return
                    }
                    let chat = try await apiPrepareContact(connLink: connLink, contactShortLinkData: data)
                    let started: ChatResponse1 = try await chatSendCmd(
                        .apiConnectPreparedContact(contactId: chat.chatInfo.apiId, incognito: false, msg: nil)
                    )
                    guard case .startedConnectionToContact = started else { throw started.unexpected }
                    await silenceOfficialChat(type: .direct, id: chat.chatInfo.apiId)
                }
            case let .groupLink(glp):
                switch glp {
                case .known, .ownLink, .connectingConfirmReconnect, .connectingProhibit:
                    log.debug("server config: the official channel is already joined")
                case .noRelays, .updateRequired:
                    log.error("server config: the official channel needs a relay decision this path does not make")
                case .ok(let sLinkInfo, let sLinkData, _):
                    guard let data = sLinkData else {
                        log.error("server config: the official channel planned without link data")
                        return
                    }
                    let chat = try await apiPrepareGroup(connLink: connLink, directLink: sLinkInfo?.direct ?? true, groupShortLinkData: data)
                    let started: ChatResponse1 = try await chatSendCmd(
                        .apiConnectPreparedGroup(groupId: chat.chatInfo.apiId, incognito: false, msg: nil)
                    )
                    guard case .startedConnectionToGroup = started else { throw started.unexpected }
                    await silenceOfficialChat(type: .group, id: chat.chatInfo.apiId)
                }
            case .invitationLink, .error:
                log.error("server config: an official address did not plan as a channel or a service account")
            }
        } catch {
            log.error("server config: the official subscription failed: \(error.localizedDescription)")
        }
    }

    /// Stop a conversation this device joined by itself from making noise.
    ///
    /// The frames need nothing here: a configuration line is already suppressed at every site that would
    /// otherwise show it (`PopopxSysMarker.isSignalText`, read by `NtfManager.swift:258`,
    /// `ChatPreviewView.swift:305` and the message bubble), and a handled row is deleted instead of being
    /// left to accumulate. This is for the traffic that marker cannot see - anything the operator sends
    /// that is not a frame, and the local row of the receipt this device sends back.
    private func silenceOfficialChat(type: ChatType, id: Int64) async {
        do {
            try await apiSetChatSettings(type: type, id: id, chatSettings: ChatSettings(enableNtfs: .none, sendRcpts: nil, favorite: false))
            // Persist the typed ref so UI layers can filter it out.
            if let userId = ChatModel.shared.currentUser?.userId,
               let ref = PopopxSystemChatRef(chatType: type, apiId: id) {
                PopopxServerConfigStore.addSystemConfigChatRef(ref, for: userId)
            }
        } catch {
            log.error("server config: an official chat could not be silenced: \(error.localizedDescription)")
        }
    }
}

/// The two official addresses, written exactly as they are deployed.
///
/// Both strings are wire values, so neither is assembled at runtime. The fragment selects the
/// conversation and the `?c=` query carries the SMP server key hash: `serverQueryP` in
/// `Popopx.Messaging.Agent.Protocol` builds the server from that hash, so a dropped query leaves the
/// address without the key it has to be dialled with, and `URL` would not preserve the ordering anyway -
/// under RFC 3986 the `?c=` sits inside the fragment, which is why the plan is handed the literal and not
/// a `URL` read back from it.
///
/// The two hashes are the ones this fork presets for `smp2.popopx.im` and `smp6.popopx.im` in
/// `src/Popopx/Chat/Operators/Presets.hs`, and the link hosts are in that same list, so an install that
/// has never touched a server other than its own presets can still resolve both addresses.
enum PopopxOfficialConfigLinks {
    /// Read-only configuration channel; the server pins the member role to `observer`.
    static let officialConfigChannelURI = "https://smp2.popopx.im/g#AbX7ZWizYxULjL-QpOGJLJm7C33BcXIsLc61IVOa8zM?c=4bJjC-wqSpviWwuDnkhSKTD4V8mYxpLqj4aiCUSfGfA"
    /// One-to-one service account: silent delivery, and where a receipt for an applied generation goes.
    static let officialConfigBotURI = "https://smp6.popopx.im/a#ZwDniscH42Q2di4Ti-2MJns_ow7OasGL1BwoDoVBnis?c=2bIUdRa7VJeB2tx9W3gwaOJ2Sv72fH8Pc_uM9l9r4hM"

    /// How long the app waits after the tab bar appears before joining anything. The tab bar is the first
    /// point at which a profile is certainly loaded, and the core is still finishing its own start-up work
    /// inside that window; a request issued there is one that can fail with no dialog left to explain it.
    static let seedingDelayNanoseconds: UInt64 = 2_500_000_000
}

/// What one probe look concluded about the introduced cluster.
enum PopopxServerConfigProbeVerdict: Equatable, Sendable {
    case reachable
    case unreachable
    /// Silence, not failure. Never a reason to roll back.
    case inconclusive
}
