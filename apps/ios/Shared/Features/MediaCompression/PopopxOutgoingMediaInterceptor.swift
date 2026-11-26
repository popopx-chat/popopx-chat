//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
// POPOPX outgoing media interceptor.
//
// Sits between the composer and the core handoff. The host gives it the URL it
// is about to attach plus the size of the target conversation, and gets back the
// URL to attach instead — compressed where compression helped, untouched where
// it did not, and flagged where the large-group ceiling refuses the file.
//
// The engine never blocks a send on a failure: if compression throws, the
// original file is returned so the user's message still goes out.

import Foundation
import PopopxMeshKit
import SwiftUI
import UIKit

// MARK: - Values

struct PopopxOutgoingAttachment: Sendable, Equatable {
    let url: URL
    let displayName: String
    let kind: PopopxAttachmentKind
    let originalBytes: Int64
    let finalBytes: Int64
    let compressed: Bool
    /// Kept with a URL even when refused, so the caller can report on it; a blocked attachment must
    /// never be handed to the core.
    let blocked: Bool
    /// Whether the engine was consulted at all. `kind` cannot carry this meaning: with the engine off
    /// the pipeline reports `.passthrough`, which is the same value `identify` gives an unrecognised
    /// file, and those two deserve different labels — one is a switched-off feature, the other a
    /// document that was never going to be re-encoded.
    let engineRan: Bool

    var savedBytes: Int64 { compressed ? max(0, originalBytes - finalBytes) : 0 }

    /// A file the pipeline did not touch: either the engine is off, or nothing was produced.
    static func passthrough(_ url: URL, kind: PopopxAttachmentKind, bytes: Int64, blocked: Bool, engineRan: Bool) -> PopopxOutgoingAttachment {
        PopopxOutgoingAttachment(
            url: url,
            displayName: url.lastPathComponent,
            kind: kind,
            originalBytes: bytes,
            finalBytes: bytes,
            compressed: false,
            blocked: blocked,
            engineRan: engineRan
        )
    }
}

struct PopopxOutgoingBatch: Sendable {
    var attachments: [PopopxOutgoingAttachment] = []

    var allowed: [PopopxOutgoingAttachment] { attachments.filter { !$0.blocked } }
    var blocked: [PopopxOutgoingAttachment] { attachments.filter(\.blocked) }
    var savedBytes: Int64 { attachments.reduce(0) { $0 + $1.savedBytes } }
    var isEmpty: Bool { attachments.isEmpty }
}

// MARK: - What may be claimed about an attachment

extension PopopxOutgoingAttachment {
    /// The label the compose preview is allowed to show. The rule that chooses it lives in
    /// `PopopxMeshKit`'s `PopopxMediaStatusResolver`, which is the part of this pipeline that a unit
    /// test can reach; this hands it the four facts the engine already reports.
    var popopxStatus: PopopxMediaStatus {
        PopopxMediaStatusResolver.resolve(
            kind: popopxResolverKind,
            engineRan: engineRan,
            compressed: compressed,
            blocked: blocked
        )
    }

    private var popopxResolverKind: PopopxMediaStatusResolver.Kind {
        switch kind {
        case .image: .image
        case .animatedImage: .animatedImage
        case .video: .video
        case .pdf: .pdf
        case .document: .document
        case .passthrough: .unknown
        }
    }
}

/// The outcome pill under a compose preview. Same visual weight as the incoming file's unpacked badge,
/// and the same rule: it names what the pipeline actually did, never what the settings imply.
struct PopopxMediaStatusBadge: View {
    let status: PopopxMediaStatus

    var body: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
            Text(PopopxMediaEngineCopy.key(status.labelKey))
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, PopopxMetrics.spaceXS)
        .padding(.vertical, 2)
        .background(fill.opacity(0.12), in: Capsule())
        .accessibilityIdentifier("popopx.media.statusBadge")
    }

    private var symbol: String {
        switch status {
        case .metadataRemoved: "location.slash"
        case .reencoded: "arrow.2.squarepath"
        case .compressed: "shippingbox"
        case .sentUnchanged: "doc"
        case .blocked: "exclamationmark.triangle"
        }
    }

    private var ink: Color {
        switch status {
        case .blocked: PopopxPalette.dangerInk
        case .sentUnchanged: PopopxPalette.labelSecondary
        default: PopopxPalette.meshInk
        }
    }

    private var fill: Color {
        switch status {
        case .blocked: PopopxPalette.danger
        case .sentUnchanged: Color.secondary
        default: PopopxPalette.mesh
        }
    }
}

// MARK: - Interceptor


@MainActor
@Observable
final class PopopxOutgoingMediaInterceptor {
    static let shared = PopopxOutgoingMediaInterceptor()

    private(set) var activeTaskCount = 0
    private(set) var processedCount = 0
    private(set) var lastSavedBytes: Int64 = 0

    /// Drives the processing capsule. Counted rather than flagged because two
    /// attachments can be prepared before either finishes.
    var isProcessing: Bool { activeTaskCount > 0 }

    /// Text shown by the capsule while attachments are being prepared.
    var statusText: String { PopopxMediaEngineCopy.processingStatus() }

    /// Message shown when the large-group ceiling refuses a file. The caller
    /// presents it with the chat's existing alert surface.
    var blockedMessage: String { PopopxMediaEngineCopy.oversizedBlocked() }

    private init() {}

    func prepare(_ urls: [URL], groupMemberCount: Int = 0) async -> PopopxOutgoingBatch {
        var batch = PopopxOutgoingBatch()
        for url in urls {
            batch.attachments.append(await prepareOne(url, groupMemberCount: groupMemberCount))
        }
        return batch
    }

    /// The single interception point: engine first, then the large-group
    /// ceiling. Whatever this returns is what the caller attaches.
    func prepareOne(_ url: URL, groupMemberCount: Int = 0) async -> PopopxOutgoingAttachment {
        activeTaskCount += 1
        defer { activeTaskCount -= 1 }
        let settings = PopopxMediaCompressionSettings.shared
        let bytes = PopopxMediaEngineCore.fileSize(of: url)
        guard settings.isEngineEnabled else {
            // Classified even though nothing is processed, because the compose badge still has to be
            // true: a still image goes through the app's own image encode at upload time whether or not
            // this engine is on, and a video or a document does not.
            return .passthrough(url, kind: await PopopxMediaEngineCore.identify(url), bytes: bytes, blocked: false, engineRan: false)
        }
        let result = await PopopxMediaEngine.shared.process(url: url, preset: settings.imageQualityPreset)
        let blocked = settings.appliesToGroup(memberCount: groupMemberCount)
            && result.finalBytes > settings.sizeCeiling
        processedCount += 1
        lastSavedBytes = result.savedBytes
        if result.savedBytes > 0 {
            PopopxHaptics.notice(.success)
        }
        if blocked {
            PopopxHaptics.notice(.warning)
        }
        return PopopxOutgoingAttachment(
            url: result.url,
            displayName: result.url.lastPathComponent,
            kind: result.kind,
            originalBytes: result.originalBytes,
            finalBytes: result.finalBytes,
            compressed: result.compressed,
            blocked: blocked,
            engineRan: true
        )
    }

    func reset() {
        activeTaskCount = 0
        processedCount = 0
        lastSavedBytes = 0
    }
}

// MARK: - Size ceiling

extension PopopxMediaCompressionSettings {
    /// Exposed as an accessor so callers never duplicate the constant.
    var sizeCeiling: Int64 { PopopxMediaCompressionSettings.maxCompressedSendByteCount }
}

// MARK: - Capsule

/// The lightweight processing pill placed above the input bar.
struct PopopxMediaProcessingCapsule: View {
    let text: String

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            ProgressView()
                .controlSize(.small)
                .tint(PopopxPalette.meshInk)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, PopopxMetrics.spaceS)
        .padding(.vertical, PopopxMetrics.spaceXS)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(PopopxPalette.meshInk.opacity(0.28), lineWidth: PopopxMetrics.hairline)
        )
        .accessibilityIdentifier("popopx.media.processingCapsule")
    }
}
