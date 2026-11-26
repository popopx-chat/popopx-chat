//
//  PopopxMediaStatus.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  What the compose preview is allowed to claim about an attachment.
//
//  It lives here, in the SwiftPM package rather than the app target, for one reason: this is the only
//  code in the media pipeline that can be unit-tested, because the package has a test target and the
//  app's source list is frozen in `project.pbxproj`. The mapping below is the entire honesty surface of
//  the feature — "did we strip metadata, did we merely shrink it, or did we send the file exactly as it
//  arrived" — so it is worth having a test for, and the app side contributes nothing but the four
//  primitives the engine already reports.
//
//  The invariant the tests protect: no combination of those primitives may produce a claim the engine
//  did not actually perform.

import Foundation

/// The single truth about one outgoing attachment, after the pipeline has finished with it.
public enum PopopxMediaStatus: String, CaseIterable, Sendable, Equatable {
    case metadataRemoved
    case reencoded
    case compressed
    case sentUnchanged
    case blocked

    /// The English sentence doubles as the localization key, as everywhere in this feature. The app
    /// resolves it through `PopopxMediaEngineCopy`, whose entries are these exact strings.
    public var labelKey: String {
        switch self {
        case .metadataRemoved: return "Metadata removed"
        case .reencoded: return "Re-encoded before sending"
        case .compressed: return "Compressed"
        case .sentUnchanged: return "Sent unchanged"
        case .blocked: return "Blocked: over the large-group limit"
        }
    }

    /// Whether the label may be read as "the engine cleaned this file". Only the two cases where the
    /// bytes that leave the device were rewritten by code that discards metadata dictionaries.
    public var impliesMetadataCleared: Bool {
        self == .metadataRemoved || self == .reencoded
    }
}

public enum PopopxMediaStatusResolver {

    /// Mirrors the app's `PopopxAttachmentKind` by name, deliberately not by type: the package must not
    /// know about ImageIO. `.unknown` is a file the classifier could not place.
    public enum Kind: String, CaseIterable, Sendable, Equatable {
        case image
        case animatedImage
        case video
        case pdf
        case document
        case unknown
    }

    /// `engineRan` says the engine was consulted; `compressed` says it produced a different file. The
    /// pair matters because a produced file is not the only way the bytes change: a still image the
    /// engine gave up on still goes through the app's own ImageIO encode at upload time, while a video,
    /// a PDF or a document that the engine gave up on is sent byte for byte as it was picked.
    public static func resolve(kind: Kind, engineRan: Bool, compressed: Bool, blocked: Bool) -> PopopxMediaStatus {
        if blocked { return .blocked }
        if engineRan, compressed {
            switch kind {
            case .image, .video, .pdf:
                return .metadataRemoved
            case .document:
                return .compressed
            case .animatedImage, .unknown:
                return .sentUnchanged
            }
        }
        return kind == .image ? .reencoded : .sentUnchanged
    }
}
