//
//  PopopxAgentTaskWire.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Reader and writer for `popopx.agent.task.v1`, the structured task card an agent (or a bound Mac
//  Node acting as one) puts at the front of a message: a progress report, an approval request with a
//  permission list, a multiple-choice question, or a result summary.
//
//  Shape: a marker line, exactly like `::POPOPX_UPD::v1`, so a producer can write a human sentence
//  before it and a receiver that has never seen the kind still shows readable text:
//
//      ::POPOPX_AGENT::v1::{"agent":"…","kind":"approval",…}
//
//  The JSON follows the same canonical form `PopopxNodeFeedWire` measured against Foundation:
//  sorted keys, no whitespace, `/` unescaped, control characters as lowercase `\u00xx`, no Unicode
//  normalization. A task body carries no signature of its own (it is display data); the signed
//  object is the user's answer — `PopopxAgentReceiptWire` below.
//
//  Refusals are values, not defaults: a card with an unknown kind/status, an oversized field, a task
//  id that is not `[A-Za-z0-9._-]{1,64}`, a percent outside 0…100, or more than 12 steps / 12
//  permissions / 8 choices is not half-drawn. The message falls back to plain text, which is what a
//  producer expects of a receiver that does not understand its frame.
//

import CryptoKit
import Foundation

// MARK: - Task

public struct PopopxAgentTask: Equatable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case progress
        case approval
        case choice
        case result
    }

    public enum Status: String, CaseIterable, Sendable {
        case running
        case awaitingApproval = "awaiting_approval"
        case completed
        case failed
        case cancelled

        /// The two states the home screen treats as "there is something alive in this chat".
        public var isActive: Bool { self == .running || self == .awaitingApproval }
    }

    public struct Step: Equatable, Hashable, Sendable {
        public enum State: String, CaseIterable, Sendable {
            case pending
            case active
            case done
            case failed
        }

        public var label: String
        public var state: State

        public init(label: String, state: State) {
            self.label = label
            self.state = state
        }
    }

    public struct Choice: Equatable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public var taskId: String
    public var kind: Kind
    public var status: Status
    public var title: String
    public var agent: String?
    public var detail: String?
    /// 0…100, present on a progress card that can state a number.
    public var percent: Int?
    public var steps: [Step]
    public var permissions: [String]
    /// `retention == "zero"` on the wire. Drives the `Zero retention` tag; never assumed.
    public var retentionZero: Bool
    public var choices: [Choice]
    public var result: String?
    /// The producer's own clock, carried unvalidated (display data, never ordering).
    public var updatedAt: String?

    public init(
        taskId: String,
        kind: Kind,
        status: Status,
        title: String,
        agent: String? = nil,
        detail: String? = nil,
        percent: Int? = nil,
        steps: [Step] = [],
        permissions: [String] = [],
        retentionZero: Bool = false,
        choices: [Choice] = [],
        result: String? = nil,
        updatedAt: String? = nil
    ) {
        self.taskId = taskId
        self.kind = kind
        self.status = status
        self.title = title
        self.agent = agent
        self.detail = detail
        self.percent = percent
        self.steps = steps
        self.permissions = permissions
        self.retentionZero = retentionZero
        self.choices = choices
        self.result = result
        self.updatedAt = updatedAt
    }

    public var isActive: Bool { status.isActive }
}

// MARK: - Task wire

public enum PopopxAgentTaskWire {
    public static let marker = "::POPOPX_AGENT::"
    public static let schemaVersion = "v1"
    public static let schemaIdentifier = "popopx.agent.task.v1"

    /// A card is one line. The node update reader refuses above 2 048; a task card carries a step
    /// list and permissions, so its ceiling is four times that and still far below a hostile message.
    static let maximumLineCharacters = 8_192
    public static let maximumSteps = 12
    public static let maximumPermissions = 12
    public static let maximumChoices = 8
    static let maximumTitleCharacters = 200
    static let maximumDetailCharacters = 500
    static let maximumLabelCharacters = 120
    static let maximumAgentCharacters = 64
    static let maximumResultCharacters = 500
    static let maximumTaskIdCharacters = 64
    static let maximumUpdatedAtCharacters = 40

    // MARK: Entry points

    /// Parses the first `::POPOPX_AGENT::v1` marker in a received message. nil means "not a card
    /// this build can draw" — no marker, an unknown version, an oversized line, or any field that
    /// fails `validate`. The caller then shows ordinary text.
    public static func parseVisibleCard(in text: String) -> PopopxAgentTask? {
        guard let line = markerLine(in: text), line.count <= maximumLineCharacters else { return nil }
        let afterMarker = line.dropFirst(marker.count)
        let versionPrefix = schemaVersion + "::"
        guard afterMarker.hasPrefix(versionPrefix) else { return nil }
        let body = afterMarker.dropFirst(versionPrefix.count)
        guard !body.isEmpty, let data = body.data(using: .utf8) else { return nil }
        return parseBody(data)
    }

    public static func isAgentTaskCard(_ text: String) -> Bool { parseVisibleCard(in: text) != nil }

    /// The one-line message a producer sends. The body is the canonical JSON this file parses.
    public static func wireText(for task: PopopxAgentTask) -> String {
        marker + schemaVersion + "::" + String(decoding: canonicalBody(task), as: UTF8.self)
    }

    // MARK: Canonical body

    /// Keys in the order Foundation's `.sortedKeys` emits them. Optional fields are omitted, so a
    /// producer that drops a display field does not change any other field's bytes.
    static let taskKeys = [
        "agent", "choices", "detail", "kind", "percent", "permissions", "result",
        "retention", "schema", "status", "steps", "task", "title", "updated",
    ]

    public static func canonicalBody(_ task: PopopxAgentTask) -> Data {
        var out = Data()
        out.append(ascii("{"))
        var first = true
        func key(_ name: String) {
            if !first { out.append(ascii(",")) }
            first = false
            out.append(jsonLiteral(name))
            out.append(ascii(":"))
        }
        // The array is walked in protocol order, not `taskKeys` order, because `choices`/`steps`
        // are arrays rather than strings; the key names still follow `taskKeys`.
        if let agent = task.agent, !agent.isEmpty {
            key("agent"); appendJSONString(agent, to: &out)
        }
        if !task.choices.isEmpty {
            key("choices")
            out.append(ascii("["))
            for (index, choice) in task.choices.enumerated() {
                if index > 0 { out.append(ascii(",")) }
                out.append(ascii("{"))
                out.append(jsonLiteral("id")); out.append(ascii(":"))
                appendJSONString(choice.id, to: &out)
                out.append(ascii(","))
                out.append(jsonLiteral("label")); out.append(ascii(":"))
                appendJSONString(choice.label, to: &out)
                out.append(ascii("}"))
            }
            out.append(ascii("]"))
        }
        if let detail = task.detail, !detail.isEmpty {
            key("detail"); appendJSONString(detail, to: &out)
        }
        key("kind"); appendJSONString(task.kind.rawValue, to: &out)
        if let percent = task.percent {
            key("percent"); appendJSONString(String(percent), to: &out)
        }
        if !task.permissions.isEmpty {
            key("permissions")
            appendJSONArray(task.permissions, to: &out)
        }
        if let result = task.result, !result.isEmpty {
            key("result"); appendJSONString(result, to: &out)
        }
        if task.retentionZero {
            key("retention"); appendJSONString("zero", to: &out)
        }
        key("schema"); appendJSONString(schemaIdentifier, to: &out)
        key("status"); appendJSONString(task.status.rawValue, to: &out)
        if !task.steps.isEmpty {
            key("steps")
            out.append(ascii("["))
            for (index, step) in task.steps.enumerated() {
                if index > 0 { out.append(ascii(",")) }
                out.append(ascii("{"))
                out.append(jsonLiteral("label")); out.append(ascii(":"))
                appendJSONString(step.label, to: &out)
                out.append(ascii(","))
                out.append(jsonLiteral("state")); out.append(ascii(":"))
                appendJSONString(step.state.rawValue, to: &out)
                out.append(ascii("}"))
            }
            out.append(ascii("]"))
        }
        key("task"); appendJSONString(task.taskId, to: &out)
        key("title"); appendJSONString(task.title, to: &out)
        if let updated = task.updatedAt, !updated.isEmpty {
            key("updated"); appendJSONString(updated, to: &out)
        }
        out.append(ascii("}"))
        return out
    }

    // MARK: Parsing

    private static func parseBody(_ data: Data) -> PopopxAgentTask? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = object as? [String: Any]
        else { return nil }
        guard let schema = root["schema"] as? String, schema == schemaIdentifier else { return nil }
        guard let taskId = root["task"] as? String, isTaskId(taskId) else { return nil }
        guard let kindText = root["kind"] as? String, let kind = PopopxAgentTask.Kind(rawValue: kindText),
              let statusText = root["status"] as? String, let status = PopopxAgentTask.Status(rawValue: statusText),
              let title = root["title"] as? String, isText(title, 1, maximumTitleCharacters)
        else { return nil }

        let agent = optionalText(root["agent"], 1, maximumAgentCharacters)
        let detail = optionalText(root["detail"], 1, maximumDetailCharacters)
        let result = optionalText(root["result"], 1, maximumResultCharacters)
        let updatedAt = optionalText(root["updated"], 1, maximumUpdatedAtCharacters)
        if root["agent"] != nil, agent == nil { return nil }
        if root["detail"] != nil, detail == nil { return nil }
        if root["result"] != nil, result == nil { return nil }
        if root["updated"] != nil, updatedAt == nil { return nil }

        var percent: Int?
        if let raw = root["percent"] {
            guard let text = raw as? String, text.count <= 3, text.allSatisfy(\.isNumber),
                  let value = Int(text), (0...100).contains(value)
            else { return nil }
            percent = value
        }

        var steps: [PopopxAgentTask.Step] = []
        if let raw = root["steps"] {
            guard let list = raw as? [Any], list.count <= maximumSteps else { return nil }
            for entry in list {
                guard let object = entry as? [String: Any],
                      let label = object["label"] as? String, isText(label, 1, maximumLabelCharacters),
                      let stateText = object["state"] as? String,
                      let state = PopopxAgentTask.Step.State(rawValue: stateText)
                else { return nil }
                steps.append(PopopxAgentTask.Step(label: label, state: state))
            }
        }

        var permissions: [String] = []
        if let raw = root["permissions"] {
            guard let list = raw as? [Any], list.count <= maximumPermissions else { return nil }
            for entry in list {
                guard let text = entry as? String, isText(text, 1, maximumLabelCharacters) else { return nil }
                permissions.append(text)
            }
        }

        var choices: [PopopxAgentTask.Choice] = []
        if let raw = root["choices"] {
            guard let list = raw as? [Any], list.count <= maximumChoices else { return nil }
            var seen = Set<String>()
            for entry in list {
                guard let object = entry as? [String: Any],
                      let id = object["id"] as? String, isTaskId(id), seen.insert(id).inserted,
                      let label = object["label"] as? String, isText(label, 1, maximumLabelCharacters)
                else { return nil }
                choices.append(PopopxAgentTask.Choice(id: id, label: label))
            }
        }

        var retentionZero = false
        if let raw = root["retention"] {
            guard let text = raw as? String else { return nil }
            retentionZero = text == "zero"
        }

        return PopopxAgentTask(
            taskId: taskId, kind: kind, status: status, title: title, agent: agent, detail: detail,
            percent: percent, steps: steps, permissions: permissions, retentionZero: retentionZero,
            choices: choices, result: result, updatedAt: updatedAt
        )
    }

    static func isTaskId(_ text: String) -> Bool {
        guard (1...maximumTaskIdCharacters).contains(text.count) else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isText(_ text: String, _ lower: Int, _ upper: Int) -> Bool {
        (lower...upper).contains(text.count)
    }

    /// A present-but-empty optional string is not a display field the producer meant to send; it is
    /// refused here so the card cannot show an empty row where it expected a sentence.
    private static func optionalText(_ value: Any?, _ lower: Int, _ upper: Int) -> String? {
        guard let text = value as? String, isText(text, lower, upper) else { return nil }
        return text
    }

    // MARK: Pieces

    /// The run from the marker to the end of its line. Same in-line search as the update card: the
    /// producer may prefix a human sentence, and `PopopxSysMarker.isSignalText` compares whole strings.
    static func markerLine(in text: String) -> Substring? {
        guard let start = text.range(of: marker) else { return nil }
        let newline = text[start.lowerBound...].firstIndex(where: { $0.isNewline })
        return text[start.lowerBound..<(newline ?? text.endIndex)]
    }

    // MARK: Escaping (measured against Foundation; same table as PopopxNodeFeedWire)

    private static func ascii(_ text: String) -> Data { Data(text.utf8) }

    private static func appendJSONArray(_ values: [String], to out: inout Data) {
        out.append(ascii("["))
        for (index, value) in values.enumerated() {
            if index > 0 { out.append(ascii(",")) }
            appendJSONString(value, to: &out)
        }
        out.append(ascii("]"))
    }

    private static func jsonLiteral(_ key: String) -> Data {
        var out = Data([0x22])
        appendEscaped(key, to: &out)
        out.append(0x22)
        return out
    }

    private static func appendJSONString(_ text: String, to out: inout Data) {
        out.append(0x22)
        appendEscaped(text, to: &out)
        out.append(0x22)
    }

    private static func appendEscaped(_ text: String, to out: inout Data) {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x08: out.append(contentsOf: [0x5C, 0x62])
            case 0x0C: out.append(contentsOf: [0x5C, 0x66])
            case 0x09: out.append(contentsOf: [0x5C, 0x74])
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
            case 0x0D: out.append(contentsOf: [0x5C, 0x72])
            case let code where code < 0x20:
                out.append(contentsOf: Array("\\u00\(hexDigit(code >> 4))\(hexDigit(code & 0x0F))".utf8))
            default:
                out.append(contentsOf: Array(String(scalar).utf8))
            }
        }
    }

    private static func hexDigit(_ nibble: UInt32) -> Character {
        nibble < 10 ? Character(UnicodeScalar(UInt8(0x30 + UInt8(nibble))))
            : Character(UnicodeScalar(UInt8(0x61 + UInt8(nibble - 10))))
    }
}

// MARK: - Receipt

/// The user's answer, signed on this device. `decision` says what was chosen; `choice` is empty
/// unless `decision == .choose`. The signature covers the canonical six-key body, so a receiver
/// verifies the same bytes this file builds — never the envelope it arrived in.
public enum PopopxAgentReceiptWire {
    public static let marker = "::POPOPX_AGENT_RCPT::"
    public static let schemaVersion = "v1"
    public static let schemaIdentifier = "popopx.agent.receipt.v1"
    static let maximumLineCharacters = 4_096

    public enum Decision: String, CaseIterable, Sendable {
        case approve
        case deny
        case choose
    }

    public struct Receipt: Equatable, Sendable {
        public var taskId: String
        public var decision: Decision
        /// Empty for approve/deny; a choice id for choose.
        public var choiceId: String
        /// ISO 8601 UTC, second precision (`2026-11-28T10:00:00Z`).
        public var at: String
        /// Unpadded base64url of the 32-byte Ed25519 public key.
        public var publicKey: String
        /// Unpadded base64url of the 64-byte signature.
        public var signature: String

        public init(taskId: String, decision: Decision, choiceId: String = "", at: String,
                    publicKey: String, signature: String) {
            self.taskId = taskId
            self.decision = decision
            self.choiceId = choiceId
            self.at = at
            self.publicKey = publicKey
            self.signature = signature
        }
    }

    /// Sorted-key order; `sig` is excluded from the signed body and appended to the envelope.
    static let bodyKeys = ["at", "choice", "decision", "key", "schema", "task"]
    static let envelopeKeys = ["at", "choice", "decision", "key", "schema", "sig", "task"]

    public static func canonicalBody(
        taskId: String, decision: Decision, choiceId: String, at: String, publicKey: String
    ) -> Data {
        var out = Data()
        out.append(ascii("{"))
        for (index, key) in bodyKeys.enumerated() {
            if index > 0 { out.append(ascii(",")) }
            out.append(jsonLiteral(key))
            out.append(ascii(":"))
            switch key {
            case "at": appendJSONString(at, to: &out)
            case "choice": appendJSONString(choiceId, to: &out)
            case "decision": appendJSONString(decision.rawValue, to: &out)
            case "key": appendJSONString(publicKey, to: &out)
            case "schema": appendJSONString(schemaIdentifier, to: &out)
            case "task": appendJSONString(taskId, to: &out)
            default: break
            }
        }
        out.append(ascii("}"))
        return out
    }

    /// Signs the canonical body with a 32-byte Ed25519 seed.
    public static func make(
        taskId: String, decision: Decision, choiceId: String = "", at: String, seed: Data
    ) -> Receipt? {
        guard seed.count == 32, PopopxAgentTaskWire.isTaskId(taskId),
              decision != .choose || PopopxAgentTaskWire.isTaskId(choiceId),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        else { return nil }
        let publicKey = key.publicKey.rawRepresentation.base64URL
        let body = canonicalBody(
            taskId: taskId, decision: decision, choiceId: choiceId, at: at, publicKey: publicKey
        )
        guard let signature = try? key.signature(for: body) else { return nil }
        return Receipt(
            taskId: taskId, decision: decision, choiceId: choiceId, at: at,
            publicKey: publicKey, signature: signature.base64URL
        )
    }

    public static func verify(_ receipt: Receipt) -> Bool {
        guard PopopxAgentTaskWire.isTaskId(receipt.taskId),
              receipt.decision != .choose || PopopxAgentTaskWire.isTaskId(receipt.choiceId),
              let key = Data(base64URL: receipt.publicKey), key.count == 32,
              let signature = Data(base64URL: receipt.signature), signature.count == 64,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key)
        else { return false }
        let body = canonicalBody(
            taskId: receipt.taskId, decision: receipt.decision, choiceId: receipt.choiceId,
            at: receipt.at, publicKey: receipt.publicKey
        )
        return publicKey.isValidSignature(signature, for: body)
    }

    public static func wireText(for receipt: Receipt) -> String {
        var out = Data()
        out.append(ascii("{"))
        for (index, key) in envelopeKeys.enumerated() {
            if index > 0 { out.append(ascii(",")) }
            out.append(jsonLiteral(key))
            out.append(ascii(":"))
            switch key {
            case "at": appendJSONString(receipt.at, to: &out)
            case "choice": appendJSONString(receipt.choiceId, to: &out)
            case "decision": appendJSONString(receipt.decision.rawValue, to: &out)
            case "key": appendJSONString(receipt.publicKey, to: &out)
            case "schema": appendJSONString(schemaIdentifier, to: &out)
            case "sig": appendJSONString(receipt.signature, to: &out)
            case "task": appendJSONString(receipt.taskId, to: &out)
            default: break
            }
        }
        out.append(ascii("}"))
        return marker + schemaVersion + "::" + String(decoding: out, as: UTF8.self)
    }

    /// A whole-string test: receipts are machine frames and must never be drawn, previewed or read
    /// aloud. `PopopxSysMarker.isSignalText` composes this with the other suppression terms.
    public static func isReceiptText(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(marker)
    }

    public static func parseReceipt(in text: String) -> Receipt? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(marker), trimmed.count <= maximumLineCharacters else { return nil }
        let afterMarker = trimmed.dropFirst(marker.count)
        let versionPrefix = schemaVersion + "::"
        guard afterMarker.hasPrefix(versionPrefix),
              let data = String(afterMarker.dropFirst(versionPrefix.count)).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = object as? [String: Any],
              let schema = root["schema"] as? String, schema == schemaIdentifier,
              let taskId = root["task"] as? String, PopopxAgentTaskWire.isTaskId(taskId),
              let decisionText = root["decision"] as? String,
              let decision = Decision(rawValue: decisionText),
              let choiceId = root["choice"] as? String,
              let at = root["at"] as? String, (1...40).contains(at.count),
              let publicKey = root["key"] as? String,
              let signature = root["sig"] as? String
        else { return nil }
        if decision == .choose, !PopopxAgentTaskWire.isTaskId(choiceId) { return nil }
        if decision != .choose, !choiceId.isEmpty { return nil }
        let receipt = Receipt(
            taskId: taskId, decision: decision, choiceId: choiceId, at: at,
            publicKey: publicKey, signature: signature
        )
        return receipt
    }

    // MARK: Escaping (same table as the task body)

    private static func ascii(_ text: String) -> Data { Data(text.utf8) }

    private static func jsonLiteral(_ key: String) -> Data {
        var out = Data([0x22]); appendEscaped(key, to: &out); out.append(0x22); return out
    }

    private static func appendJSONString(_ text: String, to out: inout Data) {
        out.append(0x22); appendEscaped(text, to: &out); out.append(0x22)
    }

    private static func appendEscaped(_ text: String, to out: inout Data) {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x08: out.append(contentsOf: [0x5C, 0x62])
            case 0x0C: out.append(contentsOf: [0x5C, 0x66])
            case 0x09: out.append(contentsOf: [0x5C, 0x74])
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
            case 0x0D: out.append(contentsOf: [0x5C, 0x72])
            case let code where code < 0x20:
                out.append(contentsOf: Array("\\u00\(hexDigit(code >> 4))\(hexDigit(code & 0x0F))".utf8))
            default:
                out.append(contentsOf: Array(String(scalar).utf8))
            }
        }
    }

    private static func hexDigit(_ nibble: UInt32) -> Character {
        nibble < 10 ? Character(UnicodeScalar(UInt8(0x30 + UInt8(nibble))))
            : Character(UnicodeScalar(UInt8(0x61 + UInt8(nibble - 10))))
    }
}
