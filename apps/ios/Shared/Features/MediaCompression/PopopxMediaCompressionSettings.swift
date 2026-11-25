//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
// POPOPX local media compression settings.
//
// Two switches drive the engine: the quality preset used for images, and the
// large-group data saver that force-compresses attachments and refuses a file
// that is still over the group threshold after compression. Both are local
// preferences only; nothing is negotiated with a server.

import Foundation
import SwiftUI

// MARK: - Preferences

@MainActor
@Observable
final class PopopxMediaCompressionSettings {
    static let shared = PopopxMediaCompressionSettings()

    private static let strictGroupKey = "popopx.media.strictGroupCompression"
    private static let presetKey = "popopx.media.imageQualityPreset"
    private static let engineKey = "popopx.media.engineEnabled"

    /// Master switch for the whole engine. Off means attachments are handed to
    /// the core exactly as picked.
    var isEngineEnabled: Bool {
        didSet {
            guard oldValue != isEngineEnabled else { return }
            PopopxMediaCompressionSettings.defaults.set(isEngineEnabled, forKey: Self.engineKey)
        }
    }

    /// Large-group flow control: force compression plus the post-compression
    /// size ceiling.
    var isStrictGroupCompressionEnabled: Bool {
        didSet {
            guard oldValue != isStrictGroupCompressionEnabled else { return }
            PopopxMediaCompressionSettings.defaults.set(isStrictGroupCompressionEnabled, forKey: Self.strictGroupKey)
        }
    }

    var imageQualityPreset: PopopxImageQualityPreset {
        didSet {
            guard oldValue != imageQualityPreset else { return }
            PopopxMediaCompressionSettings.defaults.set(imageQualityPreset.rawValue, forKey: Self.presetKey)
        }
    }

    /// A file that is still larger than this after compression is not sent in a
    /// large group. 5 MB matches the brief.
    static let maxCompressedSendByteCount: Int64 = 5_000_000

    /// Group membership at which a conversation counts as "large".
    static let largeGroupMemberThreshold = 50

    private static let defaults = UserDefaults.standard

    private init() {
        if PopopxMediaCompressionSettings.defaults.object(forKey: Self.engineKey) == nil {
            PopopxMediaCompressionSettings.defaults.set(true, forKey: Self.engineKey)
        }
        if PopopxMediaCompressionSettings.defaults.object(forKey: Self.strictGroupKey) == nil {
            PopopxMediaCompressionSettings.defaults.set(true, forKey: Self.strictGroupKey)
        }
        let stored = PopopxMediaCompressionSettings.defaults.string(forKey: Self.presetKey)
        let restored = PopopxImageQualityPreset(rawValue: stored ?? "") ?? .standardHD
        isEngineEnabled = PopopxMediaCompressionSettings.defaults.bool(forKey: Self.engineKey)
        isStrictGroupCompressionEnabled = PopopxMediaCompressionSettings.defaults.bool(forKey: Self.strictGroupKey)
        imageQualityPreset = restored
    }

    /// Whether the engine should treat this attachment count / group size
    /// combination as a large group.
    func appliesToGroup(memberCount: Int) -> Bool {
        isEngineEnabled && isStrictGroupCompressionEnabled && memberCount >= PopopxMediaCompressionSettings.largeGroupMemberThreshold
    }
}

// MARK: - Settings section

/// Mounted by `PopopxSettingsViews.swift`. The atoms come from
/// `PopopxControls.swift` unchanged, which is why every string is resolved to a
/// localized `String` before it is passed in.
struct PopopxMediaCompressionSettingsSection: View {
    @State private var settings = PopopxMediaCompressionSettings.shared
    @State private var engine = PopopxMediaEngine.shared

    var body: some View {
        PopopxSectionCard(
            PopopxMediaEngineCopy.settingsTitle(),
            footnote: PopopxMediaEngineCopy.settingsFootnote()
        ) {
            PopopxToggleRow(
                PopopxMediaEngineCopy.settingsTitle(),
                note: nil,
                isOn: $settings.isEngineEnabled
            )
            PopopxToggleRow(
                PopopxMediaEngineCopy.strictGroupToggle(),
                note: PopopxMediaEngineCopy.strictGroupNote(),
                isOn: $settings.isStrictGroupCompressionEnabled
            )
            .disabled(!settings.isEngineEnabled)

            presetRow

            if engine.savedBytesTotal > 0 {
                Text(PopopxMediaEngineCopy.savedTotal(engine.savedBytesTotal))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PopopxMediaEngineCopy.qualityRow())
                .font(.subheadline)
                .foregroundStyle(.primary)
            Picker(selection: $settings.imageQualityPreset) {
                ForEach(PopopxImageQualityPreset.allCases) { preset in
                    Text(preset.localizedLabel).tag(preset)
                }
            } label: {
                Text(PopopxMediaEngineCopy.qualityRow())
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!settings.isEngineEnabled)
        }
        .padding(.vertical, 4)
    }
}
