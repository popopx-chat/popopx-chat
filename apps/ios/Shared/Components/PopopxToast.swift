//
//  PopopxToast.swift
//  POPOPX (iOS)
//
//  The receipt leg of popopx's triple feedback: one frosted capsule at the top of
//  the screen, queued, interruptible by an upward swipe.
//

import SwiftUI
import UIKit

/// Which channel a receipt speaks for. One kind per capsule: a single control never
/// carries both indigo and teal (Docs/popopx-brand-spec.md §1.1).
enum PopopxToastKind: Hashable {
    /// Offline mesh transport did something (relayed, bound, queued).
    case mesh
    /// Online SMP transport did something.
    case encrypted
    /// A destructive path was taken (or refused).
    case danger
    /// A plain confirmation with no transport meaning.
    case success

    var symbolName: String {
        switch self {
        case .mesh: "antenna.radiowaves.left.and.right"
        case .encrypted: "lock.shield.fill"
        case .danger: "exclamationmark.triangle.fill"
        case .success: "checkmark"
        }
    }

    /// Drawn on the capsule's material, so each kind uses its *ink* variant, which
    /// is what actually clears 4.5:1 on a card or `cardHigh` surface.
    var tint: Color {
        switch self {
        case .mesh: PopopxPalette.meshInk
        case .encrypted: PopopxPalette.brand
        case .danger: PopopxPalette.dangerInk
        case .success: PopopxPalette.successInk
        }
    }
}

struct PopopxToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var kind: PopopxToastKind = .success
    var duration: Duration = .seconds(2.4)
}

@MainActor
@Observable
final class PopopxToastModel {
    private(set) var presented: PopopxToastMessage?

    private var queued: [PopopxToastMessage] = []
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, kind: PopopxToastKind = .success) {
        show(PopopxToastMessage(text: text, kind: kind))
    }

    func show(_ message: PopopxToastMessage) {
        if presented == nil {
            present(message)
        } else {
            queued.append(message)
        }
    }

    /// Upward swipe: drop the current capsule *and* the backlog. A receipt the user
    /// has dismissed deliberately must not reappear for the next action.
    func interrupt() {
        dismissTask?.cancel()
        dismissTask = nil
        queued.removeAll()
        presented = nil
    }

    var pendingCount: Int { queued.count }

    private func present(_ message: PopopxToastMessage) {
        presented = message
        UIAccessibility.post(notification: .announcement, argument: message.text)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: message.duration)
            guard let self, !Task.isCancelled else { return }
            self.advance()
        }
    }

    private func advance() {
        dismissTask = nil
        presented = nil
        guard let next = queued.first else { return }
        queued.removeFirst()
        // Wait out the exit transition, or the next capsule inherits this one's slide.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard let self, !Task.isCancelled, self.presented == nil else { return }
            self.present(next)
        }
    }
}

struct PopopxToastCapsule: View {
    let message: PopopxToastMessage

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Image(systemName: message.kind.symbolName)
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(message.kind.tint)
            Text(message.text)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .padding(.horizontal, PopopxMetrics.spaceS)
        .background(PopopxMaterial.bar, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
    }
}

/// Mount with `.popopxToast(model)` once, above everything else in a screen, so a
/// sheet or a pushed page cannot cover the receipt.
extension View {
    func popopxToast(_ model: PopopxToastModel) -> some View {
        overlay(alignment: .top) {
            PopopxToastLayer(model: model)
                .padding(.top, PopopxMetrics.spaceXS)
                .padding(.horizontal, PopopxMetrics.gutter)
        }
    }
}

private struct PopopxToastLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var model: PopopxToastModel

    var body: some View {
        Group {
            if let message = model.presented {
                PopopxToastCapsule(message: message)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            )
                    )
                    .gesture(interruptSwipe)
            }
        }
        .popopxAnimation(PopopxSpring.fluid, value: model.presented, reduceMotion: reduceMotion)
        .popopxCardElevation(colorScheme: colorScheme)
    }

    private var interruptSwipe: some Gesture {
        DragGesture(minimumDistance: PopopxMetrics.spaceXS)
            .onEnded { value in
                if value.translation.height < -PopopxMetrics.spaceM
                    || value.predictedEndTranslation.height < -PopopxMetrics.spaceL {
                    model.interrupt()
                }
            }
    }
}
