//
//  PopopxAgentTaskWireTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The `popopx.agent.task.v1` contract from the receiver's side: what must parse, what must be
//  refused, and the exact bytes a second implementation has to reproduce. The pinned literals here
//  are mirrored byte-for-byte in the Kotlin `PopopxAgentTaskWireTest`, so an encoder that sorts a
//  key differently, escapes `/`, renders `percent` as a number instead of a string, or drops
//  `updated` fails on one side of the wire even when each side round-trips against itself.
//
//  The receipt tests pin an Ed25519 key and signature derived from the seed `00 01 … 1f`. Both
//  stacks (`CryptoKit` here, BouncyCastle in Kotlin) must produce these same 32/64 bytes.
//

import Foundation
import Testing

@testable import PopopxMeshKit

@Suite("PopopxAgentTaskWire")
struct PopopxAgentTaskWireTests {
    private static let marker = "::POPOPX_AGENT::"

    private static func approvalTask() -> PopopxAgentTask {
        PopopxAgentTask(
            taskId: "task-7f3a",
            kind: .approval,
            status: .awaitingApproval,
            title: "Run the nightly index rebuild",
            agent: "ops-agent",
            detail: "Rebuilds the search index from today's exports.",
            steps: [
                .init(label: "Fetch exports", state: .done),
                .init(label: "Rebuild index", state: .active),
                .init(label: "Verify row counts", state: .pending),
            ],
            permissions: ["filesystem.read:/exports", "network.egress:smp1.popopx.im"],
            retentionZero: true,
            updatedAt: "2026-11-28T09:15:00Z"
        )
    }

    private static let approvalBody = #"{"agent":"ops-agent","detail":"Rebuilds the search index from today's exports.","kind":"approval","permissions":["filesystem.read:/exports","network.egress:smp1.popopx.im"],"retention":"zero","schema":"popopx.agent.task.v1","status":"awaiting_approval","steps":[{"label":"Fetch exports","state":"done"},{"label":"Rebuild index","state":"active"},{"label":"Verify row counts","state":"pending"}],"task":"task-7f3a","title":"Run the nightly index rebuild","updated":"2026-11-28T09:15:00Z"}"#

    private static func choiceTask() -> PopopxAgentTask {
        PopopxAgentTask(
            taskId: "task-choice-1",
            kind: .choice,
            status: .running,
            title: "Pick a summary length",
            percent: 40,
            choices: [
                .init(id: "short", label: "Short"),
                .init(id: "long", label: "Long"),
            ],
            updatedAt: "2026-11-28T09:20:00Z"
        )
    }

    private static let choiceBody = #"{"choices":[{"id":"short","label":"Short"},{"id":"long","label":"Long"}],"kind":"choice","percent":"40","schema":"popopx.agent.task.v1","status":"running","task":"task-choice-1","title":"Pick a summary length","updated":"2026-11-28T09:20:00Z"}"#

    // MARK: Canonical bytes

    @Test func approvalCardBodyIsPinned() {
        let body = PopopxAgentTaskWire.canonicalBody(Self.approvalTask())
        #expect(String(decoding: body, as: UTF8.self) == Self.approvalBody)
    }

    @Test func choiceCardBodyIsPinned() {
        let body = PopopxAgentTaskWire.canonicalBody(Self.choiceTask())
        #expect(String(decoding: body, as: UTF8.self) == Self.choiceBody)
    }

    @Test func wireTextIsMarkerVersionAndBody() {
        let text = PopopxAgentTaskWire.wireText(for: Self.approvalTask())
        #expect(text == Self.marker + "v1::" + Self.approvalBody)
    }

    // MARK: Round trips

    @Test func approvalCardRoundTrips() throws {
        let parsed = try #require(
            PopopxAgentTaskWire.parseVisibleCard(in: PopopxAgentTaskWire.wireText(for: Self.approvalTask()))
        )
        #expect(parsed == Self.approvalTask())
        #expect(parsed.retentionZero)
        #expect(parsed.percent == nil)
        #expect(parsed.choices.isEmpty)
    }

    @Test func choiceCardRoundTrips() throws {
        let parsed = try #require(
            PopopxAgentTaskWire.parseVisibleCard(in: PopopxAgentTaskWire.wireText(for: Self.choiceTask()))
        )
        #expect(parsed == Self.choiceTask())
        #expect(parsed.percent == 40)
        #expect(!parsed.retentionZero)
    }

    @Test func resultCardRoundTrips() throws {
        let task = PopopxAgentTask(
            taskId: "task-res-2", kind: .result, status: .completed,
            title: "Weekly summary ready", result: "42 messages, 3 open threads.",
            updatedAt: "2026-11-28T11:00:00Z"
        )
        let parsed = try #require(PopopxAgentTaskWire.parseVisibleCard(in: PopopxAgentTaskWire.wireText(for: task)))
        #expect(parsed == task)
        #expect(!parsed.isActive)
    }

    @Test func escapesRoundTripAndStayLowercaseHex() throws {
        let task = PopopxAgentTask(
            taskId: "task-esc", kind: .progress, status: .running,
            title: "quote \" back \\ newline \n tab \t ctl \u{01} unicode é 中",
            detail: "slash / stays raw"
        )
        let body = String(decoding: PopopxAgentTaskWire.canonicalBody(task), as: UTF8.self)
        #expect(body.contains(#"ctl \u0001"#))
        #expect(body.contains("slash / stays raw"))
        #expect(!body.contains(#"\/"#))
        let parsed = try #require(PopopxAgentTaskWire.parseVisibleCard(in: PopopxAgentTaskWire.wireText(for: task)))
        #expect(parsed == task)
    }

    @Test func humanSentenceBeforeMarkerIsTolerated() throws {
        let wire = PopopxAgentTaskWire.wireText(for: Self.choiceTask())
        let parsed = try #require(PopopxAgentTaskWire.parseVisibleCard(in: "Here is the question you asked.\n\(wire)\ntrailing"))
        #expect(parsed == Self.choiceTask())
    }

    @Test func plainTextIsNotACard() {
        #expect(!PopopxAgentTaskWire.isAgentTaskCard("just a sentence"))
        #expect(!PopopxAgentTaskWire.isAgentTaskCard(""))
        #expect(PopopxAgentTaskWire.isAgentTaskCard(Self.marker + "v1::" + Self.choiceBody))
    }

    // MARK: Refusals

    private static func refuses(_ body: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(
            PopopxAgentTaskWire.parseVisibleCard(in: marker + "v1::" + body) == nil,
            sourceLocation: sourceLocation
        )
    }

    @Test func refusesUnknownSchemaKindStatus() {
        Self.refuses(Self.choiceBody.replacingOccurrences(
            of: "\"schema\":\"popopx.agent.task.v1\"", with: "\"schema\":\"popopx.agent.task.v2\""))
        Self.refuses(Self.choiceBody.replacingOccurrences(
            of: "\"kind\":\"choice\"", with: "\"kind\":\"survey\""))
        Self.refuses(Self.choiceBody.replacingOccurrences(
            of: "\"status\":\"running\"", with: "\"status\":\"paused\""))
        Self.refuses(Self.choiceBody.replacingOccurrences(
            of: "\"task\":\"task-choice-1\"", with: "\"task\":\"bad id\""))
        #expect(PopopxAgentTaskWire.parseVisibleCard(
            in: Self.marker + "v2::" + Self.choiceBody) == nil)
    }

    @Test func refusesPercentOutOfRangeOrNonDigits() {
        for bad in ["101", "12x", "-1", "0004", ""] {
            Self.refuses(Self.choiceBody.replacingOccurrences(
                of: "\"percent\":\"40\"", with: "\"percent\":\"\(bad)\""))
        }
    }

    @Test func refusesOversizedCollections() {
        let steps = (0...PopopxAgentTaskWire.maximumSteps).map { "{\"label\":\"s\($0)\",\"state\":\"done\"}" }.joined(separator: ",")
        Self.refuses(Self.choiceBody.replacingOccurrences(
            of: "\"kind\":\"choice\"", with: "\"steps\":[\(steps)],\"kind\":\"choice\""))
        let permissions = (0...PopopxAgentTaskWire.maximumPermissions).map { "\"p\($0)\"" }.joined(separator: ",")
        Self.refuses(Self.choiceBody.replacingOccurrences(
            of: "\"kind\":\"choice\"", with: "\"permissions\":[\(permissions)],\"kind\":\"choice\""))
        let choices = (0...PopopxAgentTaskWire.maximumChoices).map { "{\"id\":\"c\($0)\",\"label\":\"C\($0)\"}" }.joined(separator: ",")
        Self.refuses(Self.choiceBody.replacingOccurrences(
            of: #""choices":[{"id":"short","label":"Short"},{"id":"long","label":"Long"}]"#,
            with: "\"choices\":[\(choices)]"))
    }

    @Test func refusesDuplicateChoiceIdsAndEmptyFields() {
        Self.refuses(Self.choiceBody.replacingOccurrences(
            of: "\"id\":\"long\"", with: "\"id\":\"short\""))
        Self.refuses(Self.choiceBody.replacingOccurrences(
            of: "\"title\":\"Pick a summary length\"", with: "\"title\":\"\""))
        Self.refuses(Self.choiceBody.replacingOccurrences(
            of: "\"status\":\"running\"", with: "\"status\":\"running\",\"agent\":\"\""))
        Self.refuses(Self.choiceBody.replacingOccurrences(
            of: "\"status\":\"running\"", with: "\"status\":\"running\",\"detail\":\"\""))
    }

    @Test func refusesOversizedField() {
        let pad = String(repeating: "a", count: 500)
        Self.refuses(Self.choiceBody.replacingOccurrences(
            of: "\"title\":\"Pick a summary length\"", with: "\"title\":\"\(pad)\""))
    }

    @Test func refusesOversizedLineEvenWhenBodyWouldParse() {
        // Trailing whitespace is legal JSON, so only the 8 192-character line ceiling can refuse
        // this. If the ceiling ever stops being enforced, this parses and the expectation flips.
        let body = Self.choiceBody + String(repeating: " ", count: 9_000)
        #expect((Self.marker + "v1::" + body).count > 8_192)
        Self.refuses(body)
    }

    @Test func refusesNonObjectBody() {
        Self.refuses("[]")
        Self.refuses("\"text\"")
        Self.refuses("")
    }

    // MARK: Status transitions (what the home screen reads)

    @Test func activeStatusesAreRunningAndAwaitingApproval() {
        #expect(PopopxAgentTask.Status.running.isActive)
        #expect(PopopxAgentTask.Status.awaitingApproval.isActive)
        #expect(!PopopxAgentTask.Status.completed.isActive)
        #expect(!PopopxAgentTask.Status.failed.isActive)
        #expect(!PopopxAgentTask.Status.cancelled.isActive)
    }

    @Test func statusTransitionSequenceParsesEachStep() throws {
        var task = Self.choiceTask()
        #expect(task.isActive)
        for (status, active) in [
            (PopopxAgentTask.Status.awaitingApproval, true),
            (.completed, false),
        ] {
            task.status = status
            task.updatedAt = "2026-11-28T12:00:00Z"
            let parsed = try #require(PopopxAgentTaskWire.parseVisibleCard(in: PopopxAgentTaskWire.wireText(for: task)))
            #expect(parsed.status == status)
            #expect(parsed.isActive == active)
            #expect(parsed.taskId == "task-choice-1")
        }
    }
}

@Suite("PopopxAgentReceiptWire")
struct PopopxAgentReceiptWireTests {
    /// Seed `00 01 … 1f`. The public key is pinned because it is a pure function of the seed; the
    /// signature is *not* pinned — CryptoKit signs hedged (two calls over identical bytes differ),
    /// so cross-stack agreement is verified, not compared. The Kotlin side pins its deterministic
    /// signature and this suite verifies a foreign receipt carrying it.
    private static let seed = Data((0..<32).map { UInt8($0) })
    private static let pinnedPublicKey = "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg"

    private static let approveBody = #"{"at":"2026-11-28T10:00:00Z","choice":"","decision":"approve","key":"A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg","schema":"popopx.agent.receipt.v1","task":"task-7f3a"}"#

    @Test func approveReceiptIsPinned() throws {
        let receipt = try #require(PopopxAgentReceiptWire.make(
            taskId: "task-7f3a", decision: .approve, at: "2026-11-28T10:00:00Z", seed: Self.seed
        ))
        #expect(receipt.publicKey == Self.pinnedPublicKey)
        #expect(Data(base64URL: receipt.signature)?.count == 64)
        let body = PopopxAgentReceiptWire.canonicalBody(
            taskId: receipt.taskId, decision: receipt.decision, choiceId: receipt.choiceId,
            at: receipt.at, publicKey: receipt.publicKey
        )
        #expect(String(decoding: body, as: UTF8.self) == Self.approveBody)
        #expect(PopopxAgentReceiptWire.verify(receipt))
    }

    /// The signature the Kotlin twin's BouncyCastle signer produced over `approveBody` with the pinned
    /// seed (deterministic there, so it is a fixed literal). CryptoKit must accept it: that is the
    /// cross-stack half a self-consistent make→verify pair can never prove.
    private static let kotlinSignature = "cxab4MNLYp_7US5depjBkeACBXy_JWclgGPQA4pjU3-Vrb79AFr_cKK5xqgbUcsdN_Y2F9pDp6bsrkrqO8yLCw"

    @Test func foreignSignedReceiptVerifies() {
        let receipt = PopopxAgentReceiptWire.Receipt(
            taskId: "task-7f3a", decision: .approve, choiceId: "",
            at: "2026-11-28T10:00:00Z", publicKey: Self.pinnedPublicKey,
            signature: Self.kotlinSignature
        )
        #expect(PopopxAgentReceiptWire.verify(receipt))
        #expect(PopopxAgentReceiptWire.parseReceipt(in: PopopxAgentReceiptWire.wireText(for: receipt)) == receipt)
    }

    @Test func receiptRoundTripsThroughWire() throws {
        let made = try #require(PopopxAgentReceiptWire.make(
            taskId: "task-7f3a", decision: .deny, at: "2026-11-28T10:05:00Z", seed: Self.seed
        ))
        let text = PopopxAgentReceiptWire.wireText(for: made)
        #expect(PopopxAgentReceiptWire.isReceiptText(text))
        let parsed = try #require(PopopxAgentReceiptWire.parseReceipt(in: "\n  " + text + "  \n"))
        #expect(parsed == made)
        #expect(PopopxAgentReceiptWire.verify(parsed))
    }

    @Test func chooseReceiptCarriesChoiceId() throws {
        let made = try #require(PopopxAgentReceiptWire.make(
            taskId: "task-choice-1", decision: .choose, choiceId: "short",
            at: "2026-11-28T10:10:00Z", seed: Self.seed
        ))
        let parsed = try #require(PopopxAgentReceiptWire.parseReceipt(in: PopopxAgentReceiptWire.wireText(for: made)))
        #expect(parsed.choiceId == "short")
        #expect(PopopxAgentReceiptWire.verify(parsed))
        #expect(PopopxAgentReceiptWire.make(taskId: "task-choice-1", decision: .choose, at: "x", seed: Self.seed) == nil)
        #expect(PopopxAgentReceiptWire.make(taskId: "bad id", decision: .approve, at: "x", seed: Self.seed) == nil)
    }

    @Test func tamperedReceiptFailsVerification() throws {
        let made = try #require(PopopxAgentReceiptWire.make(
            taskId: "task-7f3a", decision: .approve, at: "2026-11-28T10:00:00Z", seed: Self.seed
        ))
        var flipped = made
        flipped.decision = .deny
        #expect(!PopopxAgentReceiptWire.verify(flipped))
        var movedAt = made
        movedAt.at = "2026-11-28T10:00:01Z"
        #expect(!PopopxAgentReceiptWire.verify(movedAt))
        var otherTask = made
        otherTask.taskId = "task-7f3b"
        #expect(!PopopxAgentReceiptWire.verify(otherTask))
        let damagedSig = PopopxAgentReceiptWire.Receipt(
            taskId: made.taskId, decision: made.decision, at: made.at,
            publicKey: made.publicKey, signature: Self.pinnedPublicKey
        )
        #expect(!PopopxAgentReceiptWire.verify(damagedSig))
    }

    @Test func parseRefusesInconsistentDecision() {
        let chooseWithoutChoice = Self.approveBody
            .replacingOccurrences(of: "\"decision\":\"approve\"", with: "\"decision\":\"choose\"")
        #expect(PopopxAgentReceiptWire.parseReceipt(
            in: "::POPOPX_AGENT_RCPT::v1::" + chooseWithoutChoice) == nil)
        let approveWithChoice = Self.approveBody
            .replacingOccurrences(of: "\"choice\":\"\"", with: "\"choice\":\"short\"")
        #expect(PopopxAgentReceiptWire.parseReceipt(
            in: "::POPOPX_AGENT_RCPT::v1::" + approveWithChoice) == nil)
    }

    @Test func isReceiptTextIsWholeStringOnly() {
        #expect(!PopopxAgentReceiptWire.isReceiptText("hello ::POPOPX_AGENT_RCPT::v1::{}"))
        #expect(!PopopxAgentReceiptWire.isReceiptText("::POPOPX_AGENT::v1::{}"))
        #expect(!PopopxAgentReceiptWire.isReceiptText(""))
        #expect(PopopxAgentReceiptWire.isReceiptText("  \n::POPOPX_AGENT_RCPT::v1::{}"))
    }

    @Test func taskCardIsNotAReceipt() {
        let card = PopopxAgentTaskWire.wireText(for: PopopxAgentTask(
            taskId: "t", kind: .result, status: .completed, title: "Done"))
        #expect(!PopopxAgentReceiptWire.isReceiptText(card))
        #expect(PopopxAgentTaskWire.isAgentTaskCard(card))
    }
}
