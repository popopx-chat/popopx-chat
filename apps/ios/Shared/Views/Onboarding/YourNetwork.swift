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
// 引导第 3 屏：在线推送模式与厢语离线网格的两条总闸。
// 通知模式不再跳二级页，三档就地单选；中继运营商仍走原来的 `ChooseServerOperators` 弹层。
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

    var body: some View {
        GeometryReader { g in
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    PopopxOnboardingHeader(
                        step: 2,
                        steps: 3,
                        stage: PopopxOnboardingCopy.stageRouting,
                        title: PopopxOnboardingCopy.modesTitle
                    )
                    .padding(.horizontal, PopopxMetrics.gutter)

                    modesCard

                    meshCard

                    relayCard

                    actions
                        .padding(.horizontal, PopopxMetrics.gutter)
                }
                .padding(.top, PopopxMetrics.spaceM)
                .padding(.bottom, PopopxMetrics.space2XL)
                .frame(maxWidth: .infinity, minHeight: g.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(PopopxPalette.base, ignoresSafeAreaEdges: .all)
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

    // MARK: - 卡片

    private var modesCard: some View {
        PopopxSectionCard(
            PopopxOnboardingCopy.onlineChannel,
            footnote: PopopxOnboardingCopy.pushFootnote
        ) {
            ForEach(NotificationsMode.values, id: \.rawValue) { mode in
                PopopxRadioRow(
                    modeLabel(mode),
                    note: modeNote(mode),
                    selected: notificationMode == mode
                ) {
                    PopopxHaptics.selection()
                    withAnimation(PopopxSpring.snappy) {
                        notificationMode = mode
                    }
                }
                if mode != .off {
                    PopopxOnboardingHairline()
                }
            }
        }
        .popopxAnimation(PopopxSpring.snappy, value: notificationMode, reduceMotion: reduceMotion)
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

    private var relayCard: some View {
        PopopxSectionCard {
            PopopxPickerRow(
                PopopxOnboardingCopy.relayNodes,
                value: "\(selectedOperatorIds.count) / \(serverOperators.count)",
                systemImage: "network",
                tint: .neutral
            ) {
                showOperators = true
            }
            if !serverOperators.isEmpty {
                PopopxOnboardingHairline()
                operatorLogos
            }
        }
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

    // MARK: - 底部操作

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
        .navigationDestination(isPresented: $nextStepNavLinkActive) {
            OnboardingConditionsView(selectedOperatorIds: selectedOperatorIds)
                .navigationBarBackButtonHidden(true)
                .modifier(ThemedBackground())
        }
    }

    // MARK: - 文案与绑定

    /// 三档标题复用 `NotificationsMode.label`（AppAPITypes.swift:1701）已有的 Key，16 个语种齐全。
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

    /// 熔断只经由 `requestFuse(_:)` 翻转：那是唯一会带着全部厢语组件一起启停的路径，
    /// 与设置页、舱页、隐私页写的是同一个 `chat.popopx.mesh.enabled`。
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
