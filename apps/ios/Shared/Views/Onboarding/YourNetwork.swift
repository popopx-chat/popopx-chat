//
//  YourNetwork.swift
//  POPOPX (iOS)
//
//  Created by Evgeny on 22/04/2026.
//  Copyright © 2026 SimpleX Chat. All rights reserved.
//  Modifications Copyright © 2026 POPOPX Chat.
//

import SwiftUI
import POPOPXChat

// Spec: spec/client/navigation.md#YourNetworkView
// Onboarding screen 3: the two master switches for online push mode and the Cabin offline grid.
// Notification mode no longer jumps to a second-level page, the three tiers are chosen in place; relay operators still go through the original `ChooseServerOperators` sheet.
struct YourNetworkView: View {
    @Environment(\.colorScheme) var colorScheme: ColorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject private var meshRuntime = PopopxMeshRuntime.shared

    @State private var serverOperators: [ServerOperator] = []
    @State private var selectedOperatorIds = Set<Int64>()
    @State private var notificationMode: NotificationsMode = .instant
    @State private var showOperators = false
    @State private var nextStepNavLinkActive = false
    @State private var justOpened = true

    /// The same approach as screen 1: "Continue / Back" pinned above the bottom safe area, and the spacing between cards tightened one tier by screen height,
    /// so on 393×852 the three cards and both buttons are all visible at once with no scrolling. The basis is still GeometryReader's available height.
    var body: some View {
        GeometryReader { g in
            let compact = g.size.height < 900
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? PopopxMetrics.spaceS : PopopxMetrics.spaceL) {
                    PopopxOnboardingHeader(
                        step: 2,
                        steps: 3,
                        stage: PopopxOnboardingCopy.stageRouting,
                        title: PopopxOnboardingCopy.modesTitle
                    )
                    .padding(.horizontal, PopopxMetrics.gutter)

                    modesCard(compact: compact)

                    meshCard

                    relayCard(compact: compact)
                }
                .padding(.top, PopopxMetrics.spaceS)
                .padding(.bottom, PopopxMetrics.spaceM)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: PopopxMetrics.spaceS) {
            actions
        }
        .background(PopopxPalette.base, ignoresSafeAreaEdges: .all)
        .navigationDestination(isPresented: $nextStepNavLinkActive) {
            OnboardingConditionsView(selectedOperatorIds: selectedOperatorIds)
                .navigationBarBackButtonHidden(true)
                .modifier(ThemedBackground())
        }
        .onAppear {
            if justOpened {
                serverOperators = ChatModel.shared.conditions.serverOperators
                selectedOperatorIds = Set(serverOperators.filter { $0.enabled }.map { $0.operatorId })
                justOpened = false
            }
        }
        .sheet(isPresented: $showOperators) {
            ChooseServerOperators(serverOperators: serverOperators, selectedOperatorIds: $selectedOperatorIds)
                .modifier(ThemedBackground())
                .presentationDetents([.medium, .large])
        }
        .frame(maxHeight: .infinity)
        .navigationBarHidden(true)
    }

    // MARK: - Cards

    private func modesCard(compact: Bool) -> some View {
        PopopxSectionCard(
            PopopxOnboardingCopy.onlineChannel,
            footnote: PopopxOnboardingCopy.pushFootnote
        ) {
            ForEach(NotificationsMode.values, id: \.rawValue) { mode in
                modeRow(mode, compact: compact)
                    .padding(.vertical, compact ? PopopxMetrics.space2XS : PopopxMetrics.spaceXS)
            }
        }
        .popopxAnimation(PopopxSpring.snappy, value: notificationMode, reduceMotion: reduceMotion)
    }

    /// The three push-mode tiers: the whole row is one button, and the selected state gives four signals at once (highlighted background, bolded stroke,
    /// a "selected" micro-badge, a two-layer solid dot), while the unselected state keeps only a 0.5pt hairline stroke, so the three tiers read as controls rather than copy.
    /// `PopopxRadioRow` is not reused: that atomic row only puts a dot at the end of the line and cannot take a state micro-badge,
    /// and the shared control `PopopxControls.swift` is not within this round's scope of changes.
    private func modeRow(_ mode: NotificationsMode, compact: Bool) -> some View {
        let selected = notificationMode == mode
        return Button {
            guard !selected else { return }
            PopopxHaptics.selection()
            withAnimation(PopopxSpring.snappy) {
                notificationMode = mode
            }
        } label: {
            HStack(alignment: .center, spacing: PopopxMetrics.spaceS) {
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(modeLabel(mode))
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(selected ? PopopxPalette.brand : PopopxPalette.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(modeNote(mode))
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
                if selected {
                    PopopxOnboardingChip(PopopxOnboardingCopy.modeSelected)
                }
                radioMark(selected)
            }
            .padding(.horizontal, PopopxMetrics.spaceXS)
            .padding(.vertical, compact ? PopopxMetrics.space2XS : PopopxMetrics.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? PopopxPalette.brand.opacity(0.08) : Color.clear,
                in: .rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
                    .strokeBorder(
                        selected ? PopopxPalette.brand : PopopxPalette.hairlineInner,
                        lineWidth: selected ? PopopxMetrics.stroke : PopopxMetrics.hairline
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The two-layer single-choice marker: the outer ring is always there, and when selected a solid inner dot is filled in.
    private func radioMark(_ selected: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(
                    selected ? PopopxPalette.brand : PopopxPalette.labelHint,
                    lineWidth: PopopxMetrics.stroke
                )
            if selected {
                Circle()
                    .fill(PopopxPalette.brand)
                    .padding(PopopxMetrics.spaceXS)
            }
        }
        .frame(width: PopopxMetrics.spaceM, height: PopopxMetrics.spaceM)
        .accessibilityHidden(true)
    }

    private var meshCard: some View {
        PopopxSectionCard(footnote: PopopxOnboardingCopy.bluetoothPermissionNote) {
            PopopxToggleRow(
                PopopxOnboardingCopy.offlineMesh,
                note: PopopxOnboardingCopy.offlineMeshNote,
                systemImage: "dot.radiowaves.left.and.right",
                tint: .mesh,
                isOn: meshFuseBinding
            )
        }
    }

    private func relayCard(compact: Bool) -> some View {
        PopopxSectionCard(
            footnote: serverOperators.count > 1 ? nil : PopopxOnboardingCopy.operatorsNote
        ) {
            if serverOperators.count > 1 {
                PopopxPickerRow(
                    PopopxOnboardingCopy.relayNodes,
                    value: "\(selectedOperatorIds.count) / \(serverOperators.count)",
                    systemImage: "network",
                    tint: .neutral
                ) {
                    showOperators = true
                }
                PopopxOnboardingHairline()
                operatorLogos
            } else {
                relayReadyRow(compact: compact)
            }
        }
    }

    /// When there is only 1 (or 0) available operator, a "1 / 1" multi-select toggle only makes people think they have to pick one;
    /// this becomes a state display instead, and the whole row still leads to the same detail sheet, so the entry point is not lost.
    private func relayReadyRow(compact: Bool) -> some View {
        Button {
            showOperators = true
        } label: {
            HStack(alignment: .center, spacing: PopopxMetrics.spaceS) {
                PopopxOnboardingIconBadge(
                    systemName: "point.3.connected.trianglepath.dotted",
                    tint: .brand
                )
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(PopopxOnboardingCopy.relayReadyTitle)
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if let host = relayHost {
                        Text(host)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
                PopopxOnboardingChip(PopopxOnboardingCopy.relayAutoRouting)
            }
            .padding(.vertical, compact ? PopopxMetrics.spaceXS : PopopxMetrics.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
    }

    /// The domain of the only operator; when none is configured it returns nil and the card keeps only its title, inventing no host name.
    private var relayHost: String? {
        serverOperators.first?.serverDomains.first
    }

    private var operatorLogos: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            ForEach(serverOperators.reversed()) { op in
                Image(op.logo(colorScheme))
                    .resizable()
                    .scaledToFit()
                    .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                    .clipShape(.rect(cornerRadius: PopopxMetrics.radiusChip))
                    .grayscale(selectedOperatorIds.contains(op.operatorId) ? 0.0 : 1.0)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PopopxMetrics.space2XS)
    }

    // MARK: - Bottom actions

    /// The bottom fixed bar: the same set as screen 1 (opaque background + a hairline at the top). The horizontal padding moved from the call site to here,
    /// because once pinned there is no outer VStack left to supply its gutter.
    private var actions: some View {
        VStack(alignment: .center, spacing: PopopxMetrics.spaceS) {
            PopopxButton(PopopxOnboardingCopy.continueButton, systemImage: "arrow.right") {
                applyNotificationMode()
                onboardingStageDefault.set(.step4_NetworkCommitments)
                nextStepNavLinkActive = true
            }
            PopopxButton(PopopxOnboardingCopy.back, systemImage: "chevron.left", role: .ghost) {
                dismiss()
            }
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.top, PopopxMetrics.spaceXS)
        .padding(.bottom, PopopxMetrics.spaceXS)
        .background(PopopxPalette.base)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PopopxPalette.separator)
                .frame(height: PopopxMetrics.hairline)
        }
    }

    // MARK: - Copy and bindings

    /// The three tier titles reuse the keys already provided by `NotificationsMode.label` (AppAPITypes.swift:1701), complete across 16 languages.
    private func modeLabel(_ mode: NotificationsMode) -> String {
        switch mode {
        case .instant: PopopxOnboardingCopy.modeInstant
        case .periodic: PopopxOnboardingCopy.modePeriodic
        case .off: PopopxOnboardingCopy.modeNoPush
        }
    }

    private func modeNote(_ mode: NotificationsMode) -> String {
        switch mode {
        case .instant: PopopxOnboardingCopy.instantNote
        case .periodic: PopopxOnboardingCopy.periodicNote
        case .off: PopopxOnboardingCopy.noPushNote
        }
    }

    /// The fuse flips only through `requestFuse(_:)`: that is the only path that starts and stops all Cabin components together,
    /// and it writes the same `chat.popopx.mesh.enabled` as the settings page, the cabin page and the privacy page.
    private var meshFuseBinding: Binding<Bool> {
        Binding(
            get: { meshRuntime.isFuseOn },
            set: { meshRuntime.requestFuse($0) }
        )
    }

    private func applyNotificationMode() {
        let m = ChatModel.shared
        if let token = m.deviceToken {
            switch notificationMode {
            case .off:
                m.tokenStatus = .new
                m.notificationMode = .off
            default:
                Task {
                    do {
                        let status = try await apiRegisterToken(token: token, notificationMode: notificationMode)
                        await MainActor.run {
                            m.tokenStatus = status
                            m.notificationMode = notificationMode
                        }
                    } catch let error {
                        await MainActor.run {
                            showErrorAlert(error, NSLocalizedString("Error enabling notifications", comment: ""))
                        }
                    }
                }
            }
        }
    }
}
