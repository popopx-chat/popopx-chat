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
                modeRow(mode)
                    .padding(.vertical, PopopxMetrics.spaceXS)
            }
        }
        .popopxAnimation(PopopxSpring.snappy, value: notificationMode, reduceMotion: reduceMotion)
    }

    /// 推送模式三档：整行是一个按钮，选中态同时给四重信号（高亮底、加粗描边、
    /// 「已选」微标、双层实心圆点），未选中态只留 0.5pt 发丝描边，让三档读起来是控件而不是文案。
    /// 没有复用 `PopopxRadioRow`：那个原子的行尾只放圆点，插不进状态微标，
    /// 而共享控件 `PopopxControls.swift` 不在本轮改动范围内。
    private func modeRow(_ mode: NotificationsMode) -> some View {
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
            .padding(.vertical, PopopxMetrics.spaceS)
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

    /// 双层单选标记：外环始终存在，选中时再填一颗实心内点。
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

    private var relayCard: some View {
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
                relayReadyRow
            }
        }
    }

    /// 只有 1 个（或 0 个）可用运营商时，"1 / 1" 的多选切换只会让人以为必须去选一个；
    /// 这里改成状态展示，整行仍通向同一个详情弹层，入口没有丢。
    private var relayReadyRow: some View {
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
            .padding(.vertical, PopopxMetrics.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
    }

    /// 唯一运营商的域名；一个都没配时返回 nil，卡片只留标题，不编造主机名。
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
