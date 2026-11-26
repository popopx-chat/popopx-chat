//
//  PopopxMediaStatusTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Task 3 of the pre-submission pass: the compose preview may only say what the engine did.
//
//  These cases are the truth table read straight off the pipeline: `PopopxMediaEngineCore.perform`
//  reports a kind, whether it ran, and whether it produced a different file, and the app's own upload
//  path re-encodes still images whatever the engine decided. Two properties are load-bearing and worth
//  more than the individual rows: the `.ppxlz` container path never claims metadata was cleared (it
//  only ever runs LZFSE over the bytes), and a refusal is never dressed as a processing result.
//

import Foundation
import PopopxMeshKit
import Testing

private typealias Resolver = PopopxMediaStatusResolver
private typealias Kind = PopopxMediaStatusResolver.Kind

@Suite("PopopxMediaStatusResolver")
struct PopopxMediaStatusTests {

    private func status(_ kind: Kind, ran: Bool, produced: Bool, blocked: Bool = false) -> PopopxMediaStatus {
        Resolver.resolve(kind: kind, engineRan: ran, compressed: produced, blocked: blocked)
    }

    @Test("An attachment the engine rewrote has had its metadata dropped")
    func rewrittenFileIsStripped() {
        #expect(status(.image, ran: true, produced: true) == .metadataRemoved)
        #expect(status(.video, ran: true, produced: true) == .metadataRemoved)
        #expect(status(.pdf, ran: true, produced: true) == .metadataRemoved)
    }

    @Test("The container path says compressed and never says stripped")
    func containerIsOnlyShrunk() {
        let packed = status(.document, ran: true, produced: true)
        #expect(packed == .compressed)
        #expect(!packed.impliesMetadataCleared)
    }

    @Test("A bigger product still counts as rewritten")
    func growthDoesNotChangeTheClaim() {
        // The engine no longer discards a larger output, so the label is driven by "a different file was
        // produced", not by the byte delta — which is what makes the claim true in both directions.
        #expect(status(.image, ran: true, produced: true) == .metadataRemoved)
    }

    @Test("A still image the engine left alone is still re-encoded by the app")
    func hostImageEncodeIsNamed() {
        #expect(status(.image, ran: true, produced: false) == .reencoded)
        #expect(status(.image, ran: false, produced: false) == .reencoded)
        #expect(status(.image, ran: false, produced: false).impliesMetadataCleared)
    }

    @Test("Anything else that was not produced is sent as it arrived")
    func untouchedFilesAreHonest() {
        #expect(status(.video, ran: true, produced: false) == .sentUnchanged)
        #expect(status(.pdf, ran: true, produced: false) == .sentUnchanged)
        #expect(status(.document, ran: true, produced: false) == .sentUnchanged)
        #expect(status(.animatedImage, ran: true, produced: false) == .sentUnchanged)
        #expect(status(.unknown, ran: false, produced: false) == .sentUnchanged)
        for kind in [Kind.video, .pdf, .document, .animatedImage, .unknown] {
            #expect(!status(kind, ran: true, produced: false).impliesMetadataCleared)
        }
    }

    @Test("A refusal outranks every other claim")
    func blockedWins() {
        for kind in Kind.allCases {
            #expect(status(kind, ran: true, produced: true, blocked: true) == .blocked)
            #expect(status(kind, ran: false, produced: false, blocked: true) == .blocked)
        }
    }

    @Test("Animated content is never claimed to be processed")
    func animatedImageIsNeverStripped() {
        // The engine's own classifier excludes it; a produced flag here would be a pipeline bug, and the
        // label must not become the place that bug gets promoted into a privacy claim.
        #expect(status(.animatedImage, ran: true, produced: true) == .sentUnchanged)
        #expect(!status(.animatedImage, ran: true, produced: true).impliesMetadataCleared)
    }

    @Test("The label keys are the app's catalog strings, exactly")
    func labelKeysAreTheEnglishSentence() {
        let keys = PopopxMediaStatus.allCases.map(\.labelKey)
        #expect(Set(keys).count == PopopxMediaStatus.allCases.count)
        #expect(keys.contains("Metadata removed"))
        #expect(keys.contains("Re-encoded before sending"))
        #expect(keys.contains("Compressed"))
        #expect(keys.contains("Sent unchanged"))
        #expect(keys.contains("Blocked: over the large-group limit"))
    }
}
