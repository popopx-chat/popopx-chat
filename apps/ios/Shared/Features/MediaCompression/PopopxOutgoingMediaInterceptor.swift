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
    let blocked: Bool

    var savedBytes: Int64 { compressed ? max(0, originalBytes - finalBytes) : 0 }

    /// A blocked attachment keeps its URL so the caller can still report on it,
    /// but the caller must not hand it to the core.
    static func passthrough(_ url: URL, kind: PopopxAttachmentKind, bytes: Int64, blocked: Bool) -> PopopxOutgoingAttachment {
        PopopxOutgoingAttachment(
            url: url,
            displayName: url.lastPathComponent,
            kind: kind,
            originalBytes: bytes,
            finalBytes: bytes,
            compressed: false,
            blocked: blocked
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
            return .passthrough(url, kind: .passthrough, bytes: bytes, blocked: false)
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
            blocked: blocked
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
