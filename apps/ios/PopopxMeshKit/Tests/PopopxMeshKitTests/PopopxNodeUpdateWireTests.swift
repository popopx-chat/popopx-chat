//
//  PopopxNodeUpdateWireTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The `::POPOPX_UPD::v1` card reader. Display fields are optional because the producer drops them
//  under its own size ceiling; the two commands are not optional and are not re-encoded, because the
//  phone's only job with a receipt it cannot mint is to hand it back exactly as it arrived.
//

import Foundation
import Testing

@testable import PopopxMeshKit

private typealias Wire = PopopxNodeUpdateWire

/// `MacNodePopopxBridge.swift:2482` sends `cardText`, and `MacNodeModels.swift:1626-1631` builds that
/// as a prefixed line, so a receiver that compared whole strings never sees the marker.
private let leadIn = "✅ POPOPX 更新 / Update · "
private let approve = Wire.approveCommandPrefix + #"{"v":"1.3.0","rcp":"9f2c1a7b4e8d3c6a1b0f5e2d"}"#
private let snooze = Wire.snoozeCommandPrefix + #"{"v":"1.3.0","rcp":"4a1b0f5e2d9f2c1a7b4e8d3c"}"#
private let markerLine = "\(leadIn)\(Wire.marker)\(Wire.schemaVersion)"
    + "|v=1.3.0|b=1300|d=2026-11-26|s=a1b2c3d4e5f6|n=3|approve=\(approve)|snooze=\(snooze)"
private let card = markerLine
    + "\n\n1.3.0 is available on your Mac.\n· Fixes a mesh relay timeout\n· Adds a Discover feed\n· Smaller IPA"

@Suite("PopopxNodeUpdateWire")
struct PopopxNodeUpdateWireTests {

    // MARK: The happy path

    @Test("A card inside a sentence parses, which is what the bridge actually sends")
    func parsesInLine() throws {
        let notice = try #require(Wire.parseVisibleCard(in: card))
        #expect(notice.version == "1.3.0")
        #expect(notice.build == "1300")
        #expect(notice.releasedAt == "2026-11-26")
        #expect(notice.shortSha == "a1b2c3d4e5f6")
        #expect(notice.summaryCount == "3")
        #expect(notice.summaryLines == [
            "Fixes a mesh relay timeout", "Adds a Discover feed", "Smaller IPA",
        ])
        #expect(notice.hasSummary)
        // The whole-string form of a signal check, which is what `PopopxSysMarker.isSignalText` does,
        // cannot see this message at all — recorded here because it is why suppression is separate.
        #expect(card.hasPrefix("✅"))
        #expect(!card.hasPrefix(Wire.marker))
    }

    @Test("Both commands come back byte for byte, JSON and all")
    func commandsAreEchoedVerbatim() throws {
        let notice = try #require(Wire.parseVisibleCard(in: card))
        #expect(notice.approveCommand == approve)
        #expect(notice.snoozeCommand == snooze)
        #expect(notice.approveCommand.hasPrefix(Wire.approveCommandPrefix))
        #expect(notice.snoozeCommand.hasPrefix(Wire.snoozeCommandPrefix))
        // Nothing re-serialized: the braces and quotes of the receipt are still in the string.
        #expect(notice.approveCommand.contains(#""rcp":"#))
    }

    // MARK: The shapes the producer chooses

    @Test("Dropped display fields are a supported shape, not a damaged card")
    func displayFieldsAreOptional() throws {
        let trimmed = "\(leadIn)\(Wire.marker)v1|v=1.3.0|approve=\(approve)|snooze=\(snooze)"
        let notice = try #require(Wire.parseVisibleCard(in: trimmed))
        #expect(notice.version == "1.3.0")
        #expect(notice.build == nil)
        #expect(notice.releasedAt == nil)
        #expect(notice.shortSha == nil)
        #expect(notice.summaryCount == nil)
        #expect(notice.summaryLines.isEmpty)
        #expect(!notice.hasSummary)
        #expect(notice.approveCommand == approve)
    }

    @Test("An empty display value reads as absent rather than as an empty label")
    func emptyValuesAreAbsent() throws {
        let notice = try #require(Wire.parseVisibleCard(
            in: "\(leadIn)\(Wire.marker)v1|v=1.3.0|b=|d=|s=|n=|approve=\(approve)|snooze=\(snooze)"
        ))
        #expect(notice.build == nil)
        #expect(notice.releasedAt == nil)
        #expect(notice.shortSha == nil)
        #expect(notice.summaryCount == nil)
    }

    @Test("A future field the producer adds is ignored, not fatal")
    func unknownKeysAreIgnored() throws {
        let notice = try #require(Wire.parseVisibleCard(
            in: "\(leadIn)\(Wire.marker)v1|z=whatever|v=1.3.0|q|x=|approve=\(approve)|snooze=\(snooze)"
        ))
        #expect(notice.version == "1.3.0")
    }

    @Test("A command may contain the field separator, because commands are never truncated")
    func pipeInsideACommandSurvives() throws {
        let wide = Wire.approveCommandPrefix + #"{"v":"1.3.0","rcp":"a|b"}"#
        let notice = try #require(Wire.parseVisibleCard(
            in: "\(leadIn)\(Wire.marker)v1|v=1.3.0|approve=\(wide)|snooze=\(snooze)"
        ))
        #expect(notice.approveCommand == wide)
        #expect(notice.approveCommand.contains("|"))
        #expect(notice.snoozeCommand == snooze)
    }

    // MARK: Refusals

    @Test("Anything this build cannot answer reads as ordinary text")
    func refusals() {
        let cases: [(String, String)] = [
            ("no marker at all", "A message about 1.3.0 on your Mac"),
            ("marker with no version segment", leadIn + Wire.marker + "|v=1.3.0|approve=\(approve)|snooze=\(snooze)"),
            ("a different version", markerLine.replacingOccurrences(of: "UPD::v1", with: "UPD::v2")),
            ("a longer version prefix read as v1", markerLine.replacingOccurrences(of: "UPD::v1|", with: "UPD::v10|")),
            ("missing approve", markerLine.replacingOccurrences(of: "|approve=\(approve)", with: "")),
            ("missing snooze", markerLine.replacingOccurrences(of: "|snooze=\(snooze)", with: "")),
            ("no version field", markerLine.replacingOccurrences(of: "|v=1.3.0", with: "")),
            ("empty version", markerLine.replacingOccurrences(of: "|v=1.3.0", with: "|v=")),
            ("approve is not an update command", markerLine.replacingOccurrences(of: approve, with: "::popopx_sys::NODE_CMD::mesh::reset::{}")),
            ("snooze is not an update command", markerLine.replacingOccurrences(of: snooze, with: "rm -rf /")),
            ("commands in the other order", markerLine.replacingOccurrences(of: "|approve=\(approve)|snooze=\(snooze)", with: "|snooze=\(snooze)|approve=\(approve)")),
        ]
        for (name, text) in cases {
            #expect(Wire.parseVisibleCard(in: text) == nil, "\(name) parsed")
            #expect(!Wire.isUpdateCard(text), "\(name) reported as a card")
        }
    }

    @Test("The marker is read wherever it sits, because only the commands are trusted or checked")
    func markerPositionIsNotTheGate() throws {
        // Deliberately tolerant: a producer that later wraps the line in markdown or brackets still
        // renders instead of silently losing the card. Nothing here believes the marker — the two
        // command prefixes are what is checked, and the receipt inside them is verified node-side.
        let wrapped = "```" + Wire.marker + "v1|v=1.3.0|approve=\(approve)|snooze=\(snooze)```"
        let notice = try #require(Wire.parseVisibleCard(in: wrapped))
        #expect(notice.version == "1.3.0")
        #expect(notice.approveCommand == approve)
    }

    @Test("An oversized marker line is not the producer's output")
    func oversizedLineIsRefused() {
        let padded = "\(leadIn)\(Wire.marker)v1|v=\(String(repeating: "a", count: Wire.maximumLineCharacters))"
            + "|approve=\(approve)|snooze=\(snooze)"
        #expect(Wire.parseVisibleCard(in: padded) == nil)
        // Just under the ceiling still parses, so the refusal is the size and not the padding.
        #expect(Wire.parseVisibleCard(in: markerLine) != nil)
    }

    // MARK: The summary body

    @Test("Only the `· ` lines below the marker become the summary, and only eight of them")
    func summaryLines() throws {
        let bullet = "· "
        let many = (1...12).map { "\(bullet)line \($0)" }.joined(separator: "\n")
        let notice = try #require(Wire.parseVisibleCard(in: markerLine + "\n\n" + many))
        #expect(notice.summaryLines.count == Wire.maximumSummaryLines)
        #expect(notice.summaryLines.first == "line 1")
        #expect(notice.summaryLines.last == "line 8")

        // A bullet above the marker line belongs to the previous message, not to this card.
        let before = "· earlier note\n" + markerLine + "\n" + bullet + "after"
        #expect(try #require(Wire.parseVisibleCard(in: before)).summaryLines == ["after"])

        // The node writes "（无更新说明 / no summary）" when there is nothing to say: prose stays prose.
        let prose = markerLine + "\n\n（无更新说明 / no summary）\nUpdated just now."
        #expect(try #require(Wire.parseVisibleCard(in: prose)).summaryLines.isEmpty)

        // Trailing whitespace and an empty bullet are dropped rather than rendered as a blank row.
        let ragged = markerLine + "\n\n" + bullet + "  spaced  \n" + bullet + "\n"
        #expect(try #require(Wire.parseVisibleCard(in: ragged)).summaryLines == ["spaced"])
    }

    @Test("summaryLines answers the body alone, and nothing without a marker")
    func summaryLinesStandalone() {
        #expect(Wire.summaryLines(in: card).count == 3)
        #expect(Wire.summaryLines(in: "no marker here\n· but a bullet").isEmpty)
    }

    @Test("A card is a card on the second read, and idempotently so")
    func repeatedReadsAgree() throws {
        // The mount asks this per message and per list row; anything state-dependent would flicker.
        let first = try #require(Wire.parseVisibleCard(in: card))
        #expect(Wire.parseVisibleCard(in: card) == first)
        #expect(Wire.isUpdateCard(card))
    }
}
