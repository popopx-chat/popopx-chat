//
//  PopopxHaptics.swift
//  POPOPX (iOS)
//
//  The haptic leg of popopx's triple feedback (press scale + haptic + receipt
//  capsule). Docs/popopx-brand-spec.md §5.
//

import UIKit

/// Impact named for what the user did to the interface rather than for the
/// intensity numbers behind it, so a call site reads as intent.
enum PopopxHapticImpact: Hashable {
    case soft, light, medium, heavy, rigid

    var style: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .soft: .soft
        case .light: .light
        case .medium: .medium
        case .heavy: .heavy
        case .rigid: .rigid
        }
    }
}

enum PopopxHapticNotice: Hashable {
    case success, warning, error

    var type: UINotificationFeedbackGenerator.FeedbackType {
        switch self {
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
    }
}

@MainActor
enum PopopxHaptics {
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private static let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let noticeGenerator = UINotificationFeedbackGenerator()
    private static let selectionGenerator = UISelectionFeedbackGenerator()

    static func impact(_ impact: PopopxHapticImpact) {
        let generator = generator(for: impact)
        generator.impactOccurred()
        generator.prepare()
    }

    static func notice(_ notice: PopopxHapticNotice) {
        noticeGenerator.notificationOccurred(notice.type)
        noticeGenerator.prepare()
    }

    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    // Generators are built once and re-armed after every fire. Allocating one per
    // tap is what makes the haptic arrive a frame after the visual, and Phase 3's
    // 15 cm proximity hit has to land on the same frame as the radar.
    private static func generator(for impact: PopopxHapticImpact) -> UIImpactFeedbackGenerator {
        switch impact {
        case .soft: softGenerator
        case .light: lightGenerator
        case .medium: mediumGenerator
        case .heavy: heavyGenerator
        case .rigid: rigidGenerator
        }
    }
}
