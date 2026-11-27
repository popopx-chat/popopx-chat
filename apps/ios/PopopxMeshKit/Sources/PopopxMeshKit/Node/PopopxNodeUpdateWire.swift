//
//  PopopxNodeUpdateWire.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Reader for the `::POPOPX_UPD::v1` upgrade notice a bound Mac Node sends when a verified new
//  release is pending. Loose about the display fields, strict about the two commands.
//
//  Producer side, quoted rather than guessed (`PopopxMacNode` main = e40f5e3):
//   - marker, version, field order            Updates/UpdateModels.swift:484-516
//   - the ceiling and what is dropped under   Models/MacNodeModels.swift:52 (`maxSignalPayloadCharacters`)
//     it                                      + UpdateModels.swift:511-515 (drops `d`/`s`/`n`, never a command)
//   - command text                            UpdateCenter.swift:354-361 with Models/MacNodeModels.swift:40
//   - receipt provenance                      UpdateCenter.swift:219-228 — the HMAC is minted node-side,
//                                             so the phone can only echo it, never construct one
//   - the line the phone actually receives    Core/MacNodePopopxBridge.swift:2482-2486 (`cardText`, then
//                                             "\n\n" + the body) with Models/MacNodeModels.swift:1626-1631
//   - the body the summary comes from         PopopxMacNodeApp.swift:863-870 (`· `-prefixed, at most 8)
//   - the artifact name this pairs with       Models/MacNodeModels.swift:3174 (`feed.json`, see
//                                             `PopopxNodeFeedWire` for the signed payload beside it)
//
//  Two consequences shape the code below:
//
//  1. The marker is **inside** a line, not the whole of it: `cardText` is
//     `✅ POPOPX 更新 / Update · ::POPOPX_UPD::v1|v=…`. `PopopxSysMarker.isSignalText`, which compares
//     a whole string, therefore never hides it, and an in-line search is the only parse that works —
//     the same choice `PopopxEcoMarker.parseVisibleCard` makes on Android.
//  2. The commands are the payload. A missing `d`/`s`/`n` is a supported shape, not an error, but a
//     command that does not carry the node's own `updates::approve::` / `updates::snooze::` prefix is
//     refused: without that check, anyone able to send one message could make the phone echo an
//     arbitrary string into the node's command channel.
//

import Foundation

public enum PopopxNodeUpdateWire {
    public static let marker = "::POPOPX_UPD::"
    public static let schemaVersion = "v1"

    /// `NodeWire.commandPrefix` plus the service and verb, spelled out because the receiver checks
    /// both and then echoes the whole command back byte-for-byte.
    public static let approveCommandPrefix = "::popopx_sys::NODE_CMD::updates::approve::"
    public static let snoozeCommandPrefix = "::popopx_sys::NODE_CMD::updates::snooze::"

    /// The producer keeps its own line under 1024 and trims display fields to do it. Twice that is
    /// certainly not the producer's output, so it is refused rather than parsed.
    static let maximumLineCharacters = 2_048

    /// `PopopxMacNodeApp.swift:865`: the node puts at most eight `· ` lines on the card.
    public static let maximumSummaryLines = 8

    /// One parsed notice. A nil display field means the producer dropped it under the size ceiling.
    public struct Notice: Equatable, Hashable, Sendable {
        public var version: String
        public var build: String?
        public var releasedAt: String?
        /// Twelve hex characters of the package digest — the short form, not the digest.
        public var shortSha: String?
        /// What the producer says how many summary lines exist, which can out-number what survives
        /// the body truncation. Carried, not reconciled.
        public var summaryCount: String?
        public var approveCommand: String
        public var snoozeCommand: String
        /// The `· ` lines from the same message, prefix stripped, in the node's order.
        public var summaryLines: [String]

        public init(
            version: String, build: String? = nil, releasedAt: String? = nil, shortSha: String? = nil,
            summaryCount: String? = nil, approveCommand: String, snoozeCommand: String,
            summaryLines: [String] = []
        ) {
            self.version = version
            self.build = build
            self.releasedAt = releasedAt
            self.shortSha = shortSha
            self.summaryCount = summaryCount
            self.approveCommand = approveCommand
            self.snoozeCommand = snoozeCommand
            self.summaryLines = summaryLines
        }

        public var hasSummary: Bool { !summaryLines.isEmpty }
    }

    // MARK: Entry points

    /// Parses the first `::POPOPX_UPD::v1` marker in a received message. nil means "not a card this
    /// build can answer" — no marker, an unknown version, an oversized line, a missing command, or a
    /// command that is not an update command. The caller then shows ordinary text, which is what the
    /// producer expects of a receiver that has never seen this kind.
    public static func parseVisibleCard(in text: String) -> Notice? {
        guard let line = markerLine(in: text), line.count <= maximumLineCharacters else { return nil }
        let afterMarker = line.dropFirst(marker.count)
        let segments = afterMarker.split(separator: "|", omittingEmptySubsequences: false)
        guard let head = segments.first, String(head) == schemaVersion else { return nil }

        // Spelled as separators rather than as segments, because a command value is JSON and a naive
        // split on "|" would cut it in half while still looking like a successful parse.
        let approveSeparator = "|approve="
        let snoozeSeparator = "|snooze="
        guard let approveRange = line.range(of: approveSeparator),
              let snoozeRange = line.range(of: snoozeSeparator, range: approveRange.upperBound..<line.endIndex)
        else { return nil }
        let approve = String(line[approveRange.upperBound..<snoozeRange.lowerBound])
        let snooze = String(line[snoozeRange.upperBound...])
        guard approve.hasPrefix(approveCommandPrefix), snooze.hasPrefix(snoozeCommandPrefix) else {
            return nil
        }

        var version = ""
        var build: String?
        var releasedAt: String?
        var shortSha: String?
        var summaryCount: String?
        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let key = segment[segment.startIndex..<equals]
            let value = segment[segment.index(after: equals)...]
            switch key {
            case "v": version = String(value)
            case "b": build = value.isEmpty ? nil : String(value)
            case "d": releasedAt = value.isEmpty ? nil : String(value)
            case "s": shortSha = value.isEmpty ? nil : String(value)
            case "n": summaryCount = value.isEmpty ? nil : String(value)
            default: break
            }
        }
        // The card is titled with the version; without it there is nothing to confirm.
        guard !version.isEmpty else { return nil }

        return Notice(
            version: version, build: build, releasedAt: releasedAt, shortSha: shortSha,
            summaryCount: summaryCount, approveCommand: approve, snoozeCommand: snooze,
            summaryLines: summaryLines(in: text, afterLineEndingAt: line.endIndex)
        )
    }

    public static func isUpdateCard(_ text: String) -> Bool { parseVisibleCard(in: text) != nil }

    /// The `· ` lines the node puts below the card. Split out so the caller can refresh the summary
    /// of a stored notice without re-verifying the commands.
    public static func summaryLines(in text: String) -> [String] {
        guard let line = markerLine(in: text) else { return [] }
        return summaryLines(in: text, afterLineEndingAt: line.endIndex)
    }

    // MARK: Pieces

    /// The run from the marker to the end of its line.
    static func markerLine(in text: String) -> Substring? {
        guard let start = text.range(of: marker) else { return nil }
        let newline = text[start.lowerBound...].firstIndex(where: { $0.isNewline })
        return text[start.lowerBound..<(newline ?? text.endIndex)]
    }

    private static func summaryLines(in text: String, afterLineEndingAt position: String.Index) -> [String] {
        var lines: [String] = []
        for raw in text[position...].split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(bullet) else { continue }
            let summary = String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            // "（无更新说明 / no summary）" has no bullet, so it never reaches here.
            guard !summary.isEmpty else { continue }
            lines.append(summary)
            if lines.count == maximumSummaryLines { break }
        }
        return lines
    }

    static let bullet = "·"
}
