//
//  ChooseServerOperators.swift
//  POPOPX (iOS)
//
//  Created by spaced4ndy on 31.10.2024.
//  Copyright © 2024 SimpleX Chat. All rights reserved.
//  Modifications Copyright © 2026 POPOPX Chat.
//
// Spec: spec/client/navigation.md

import SwiftUI
import LocalAuthentication
import POPOPXChat

// The privacy statement POPOPX shows in its consent flows. Single place to edit; the site serves it.
let popopxPrivacyURL = URL(string: "https://popopx.chat/privacy")!
let conditionsURL = popopxPrivacyURL

struct OnboardingButtonStyle: ButtonStyle {
    @EnvironmentObject var theme: AppTheme
    var isDisabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .padding()
            .frame(maxWidth: .infinity)
            .background(
                isDisabled
                ? (
                    theme.colors.isLight
                    ? .gray.opacity(0.17)
                    : .gray.opacity(0.27)
                )
                : theme.colors.primary
            )
            .foregroundColor(
                isDisabled
                ? (
                    theme.colors.isLight
                    ? .gray.opacity(0.4)
                    : .white.opacity(0.2)
                )
                : .white
            )
            .cornerRadius(16)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

// Spec: spec/client/navigation.md#OnboardingConditionsView
// 引导第 4 屏：三条安全承诺 + 启动防护 + 两份内置法律文书。
// 「同意并进入」的链路顺序不可调换：先落服务端条件接受，再做生物识别证明，
// 最后幂等发放先锋徽章并等两条 Toast 走完，才拆掉引导栈。
struct OnboardingConditionsView: View {
    @EnvironmentObject var m: ChatModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(DEFAULT_PERFORM_LA) private var prefPerformLA = false

    var selectedOperatorIds: Set<Int64>

    @State private var relayCommitted = false
    @State private var routingCommitted = false
    @State private var wipeCommitted = false
    @State private var agreed = false
    @State private var biometricOn = false
    @State private var biometricAvailable = false
    @State private var document: PopopxLegalDocumentSheet.Document? = nil
    @State private var toast = PopopxToastModel()

    private static let toastHold: Duration = .seconds(1.3)
    private static let toastPair: Duration = .seconds(2.6)

    var body: some View {
        GeometryReader { g in
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    PopopxOnboardingHeader(
                        step: 3,
                        steps: 3,
                        stage: PopopxOnboardingCopy.stageCommitments,
                        title: PopopxOnboardingCopy.commitmentsTitle
                    )
                    .padding(.horizontal, PopopxMetrics.gutter)

                    commitmentsCard

                    launchCard

                    legalCard

                    VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                        enterButton
                        gateHint
                    }
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
            var error: NSError? = nil
            biometricAvailable = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        }
        .sheet(item: $document) { doc in
            PopopxLegalDocumentSheet(document: doc)
                .presentationDetents([.medium, .large])
        }
        .popopxToast(toast)
        .frame(maxHeight: .infinity)
        .navigationBarHidden(true)
    }

    // MARK: - 卡片

    private var commitmentsCard: some View {
        PopopxSectionCard(PopopxOnboardingCopy.commitmentsCard) {
            PopopxCheckbox(PopopxOnboardingCopy.commitmentRelay, isOn: tick($relayCommitted))
                .popopxAnimation(PopopxSpring.snappy, value: relayCommitted, reduceMotion: reduceMotion)
            PopopxOnboardingHairline()
            PopopxCheckbox(PopopxOnboardingCopy.commitmentRouting, isOn: tick($routingCommitted))
                .popopxAnimation(PopopxSpring.snappy, value: routingCommitted, reduceMotion: reduceMotion)
            PopopxOnboardingHairline()
            PopopxCheckbox(PopopxOnboardingCopy.commitmentWipe, isOn: tick($wipeCommitted))
                .popopxAnimation(PopopxSpring.snappy, value: wipeCommitted, reduceMotion: reduceMotion)
        }
    }

    private var launchCard: some View {
        PopopxSectionCard(PopopxOnboardingCopy.launchProtection) {
            PopopxToggleRow(
                PopopxOnboardingCopy.biometricRow,
                note: biometricAvailable
                    ? PopopxOnboardingCopy.biometricNote
                    : PopopxOnboardingCopy.biometricUnavailable,
                systemImage: "faceid",
                tint: .brand,
                isOn: $biometricOn
            )
            .disabled(!biometricAvailable)
        }
    }

    private var legalCard: some View {
        PopopxSectionCard(
            PopopxOnboardingCopy.legalCard,
            footnote: PopopxOnboardingCopy.legalReadableOffline
        ) {
            PopopxPickerRow(
                PopopxOnboardingCopy.privacyPolicy,
                systemImage: "hand.raised.fill",
                tint: .brand
            ) {
                document = .privacy
            }
            PopopxOnboardingHairline()
            PopopxPickerRow(
                PopopxOnboardingCopy.termsOfUse,
                systemImage: "doc.text.fill",
                tint: .mesh
            ) {
                document = .terms
            }
            PopopxOnboardingHairline()
            PopopxCheckbox(PopopxOnboardingCopy.legalAgreement, isOn: tick($agreed))
                .popopxAnimation(PopopxSpring.snappy, value: agreed, reduceMotion: reduceMotion)
        }
    }

    // MARK: - 闸门

    private var commitmentsMet: Bool { relayCommitted && routingCommitted && wipeCommitted }

    private var canEnter: Bool { commitmentsMet && agreed && !selectedOperatorIds.isEmpty }

    /// 勾选回执：`PopopxCheckbox` 本身不带触觉（0.97 微缩只在 `PopopxButton` 的按压态里），
    /// 所以在写入这一侧补一次 selection 轻震，动画由调用点的 `popopxAnimation` 负责。
    private func tick(_ source: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue },
            set: { newValue in
                if source.wrappedValue != newValue {
                    PopopxHaptics.selection()
                }
                source.wrappedValue = newValue
            }
        )
    }

    @ViewBuilder private var gateHint: some View {
        if !commitmentsMet {
            Text(PopopxOnboardingCopy.commitmentsRequired)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !agreed {
            Text(PopopxOnboardingCopy.legalRequired)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var enterButton: some View {
        PopopxButton(PopopxOnboardingCopy.agreeAndEnter, systemImage: "lock.shield.fill") {
            await finishOnboarding()
        }
        .disabled(!canEnter)
        .popopxAnimation(PopopxSpring.snappy, value: canEnter, reduceMotion: reduceMotion)
    }

    // MARK: - 完成链

    @MainActor private func finishOnboarding() async {
        do {
            let conditionsId = m.conditions.currentConditions.conditionsId
            let r = try await acceptConditions(conditionsId: conditionsId, operatorIds: Array(selectedOperatorIds))
            m.conditions = r
            if let enabledOps = enabledOperators(r.serverOperators) {
                m.conditions = try await setServerOperators(operators: enabledOps)
            }
        } catch let error {
            showAlert(
                NSLocalizedString("Error accepting conditions", comment: "alert title"),
                message: responseError(error)
            )
            return
        }

        if biometricOn {
            await enableLaunchLock()
        }

        // 幂等：`PopopxBadgeManager` 先落 `.trialGuard` 再落徽章，重复调用只会返回 nil，
        // 因此第四屏这条链不会烧掉第二次 72 小时（裁定 2）。
        _ = await PopopxBadgeManager.shared.issuePioneerTrialIfNeeded()

        toast.show(PopopxToastMessage(text: PopopxOnboardingCopy.readyToast, kind: .encrypted, duration: Self.toastHold))
        toast.show(PopopxToastMessage(text: PopopxOnboardingCopy.badgeToast, kind: .mesh, duration: Self.toastHold))
        try? await Task.sleep(for: Self.toastPair)
        PopopxHaptics.impact(.heavy)
        completeOnboarding()
    }

    /// 与 `ContentView.initialEnableLA()`（ContentView.swift:416）同一套契约：
    /// 模式回到 `.system` → 系统生物识别证明 → 成功才落 `prefPerformLA` 与 app group 镜像。
    /// 失败或不可用一律写回 false，绝不留"开关是开的但没证明过"。
    @MainActor private func enableLaunchLock() async {
        privacyLocalAuthModeDefault.set(.system)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            authenticate(reason: NSLocalizedString("Enable POPOPX Lock", comment: "authentication reason")) { laResult in
                switch laResult {
                case .success:
                    m.contentViewAccessAuthenticated = true
                    prefPerformLA = true
                    appLocalAuthEnabledGroupDefault.set(true)
                case .failed:
                    prefPerformLA = false
                    appLocalAuthEnabledGroupDefault.set(false)
                case .unavailable:
                    prefPerformLA = false
                    appLocalAuthEnabledGroupDefault.set(false)
                }
                continuation.resume()
            }
        }
    }

    private func completeOnboarding() {
        let m = ChatModel.shared
        onboardingStageDefault.set(.onboardingComplete)
        // defer the stage swap off the finish button's call stack so the deep onboarding nav stack
        // isn't torn down from inside its own event handling (UIKit crash on completion); the inner
        // async guarantees this even if dismissAllSheets runs its completion synchronously.
        dismissAllSheets(animated: false) {
            DispatchQueue.main.async {
                m.onboardingStage = .onboardingComplete
            }
        }
    }

    private func enabledOperators(_ operators: [ServerOperator]) -> [ServerOperator]? {
        var ops = operators
        if !ops.isEmpty {
            for i in 0..<ops.count {
                var op = ops[i]
                op.enabled = selectedOperatorIds.contains(op.operatorId)
                ops[i] = op
            }
            let haveSMPStorage = ops.contains(where: { $0.enabled && $0.smpRoles.storage })
            let haveSMPProxy = ops.contains(where: { $0.enabled && $0.smpRoles.proxy })
            let haveXFTPStorage = ops.contains(where: { $0.enabled && $0.xftpRoles.storage })
            let haveXFTPProxy = ops.contains(where: { $0.enabled && $0.xftpRoles.proxy })
            if haveSMPStorage && haveSMPProxy && haveXFTPStorage && haveXFTPProxy {
                return ops
            } else if let firstEnabledIndex = ops.firstIndex(where: { $0.enabled }) {
                var op = ops[firstEnabledIndex]
                if !haveSMPStorage { op.smpRoles.storage = true }
                if !haveSMPProxy { op.smpRoles.proxy = true }
                if !haveXFTPStorage { op.xftpRoles.storage = true }
                if !haveXFTPProxy { op.xftpRoles.proxy = true }
                ops[firstEnabledIndex] = op
                return ops
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
}

private enum ChooseServerOperatorsSheet: Identifiable {
    case showInfo

    var id: String {
        switch self {
        case .showInfo: return "showInfo"
        }
    }
}

struct ChooseServerOperators: View {
    @Environment(\.dismiss) var dismiss: DismissAction
    @Environment(\.colorScheme) var colorScheme: ColorScheme
    @EnvironmentObject var theme: AppTheme
    var serverOperators: [ServerOperator]
    @Binding var selectedOperatorIds: Set<Int64>
    @State private var sheetItem: ChooseServerOperatorsSheet? = nil

    var body: some View {
        GeometryReader { g in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Server operators")
                        .font(.largeTitle)
                        .bold()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 25)

                    infoText()
                        .frame(maxWidth: .infinity, alignment: .center)

                    Spacer()
                    
                    ForEach(serverOperators) { srvOperator in
                        operatorCheckView(srvOperator)
                    }
                    VStack {
                        Text("You can configure servers via settings.")
                    }
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 16)
                    
                    Spacer()

                    VStack(spacing: 8) {
                        setOperatorsButton()
                        onboardingButtonPlaceholder()
                    }
                }
                .frame(minHeight: g.size.height)
            }
            .sheet(item: $sheetItem) { item in
                switch item {
                case .showInfo:
                    ChooseServerOperatorsInfoView()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(25)
        .interactiveDismissDisabled(selectedOperatorIds.isEmpty)
    }

    private func infoText() -> some View {
        Button {
            sheetItem = .showInfo
        } label: {
            Label("How it helps privacy", systemImage: "info.circle")
                .font(.headline)
        }
    }

    private func operatorCheckView(_ serverOperator: ServerOperator) -> some View {
        let checked = selectedOperatorIds.contains(serverOperator.operatorId)
        let icon = checked ? "checkmark.circle.fill" : "circle"
        let iconColor = checked ? theme.colors.primary : Color(uiColor: .tertiaryLabel).asAnotherColorFromSecondary(theme)
        return HStack(spacing: 10) {
            Image(serverOperator.largeLogo(colorScheme))
                .resizable()
                .scaledToFit()
                .frame(height: 48)
            Spacer()
            Image(systemName: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .foregroundColor(iconColor)
        }
        .background(theme.colors.background)
        .padding()
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color(uiColor: .secondarySystemFill), lineWidth: 2)
        )
        .padding(.horizontal, 2)
        .onTapGesture {
            if checked {
                selectedOperatorIds.remove(serverOperator.operatorId)
            } else {
                selectedOperatorIds.insert(serverOperator.operatorId)
            }
        }
    }

    private func setOperatorsButton() -> some View {
        Button {
            dismiss()
        } label: {
            Text("OK")
        }
        .buttonStyle(OnboardingButtonStyle(isDisabled: selectedOperatorIds.isEmpty))
        .disabled(selectedOperatorIds.isEmpty)
    }
}

struct ChooseServerOperatorsInfoView: View {
    @Environment(\.colorScheme) var colorScheme: ColorScheme
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: 12) {
                    Text("The app protects your privacy by using different operators in each conversation.")
                    Text("When more than one operator is enabled, none of them has metadata to learn who communicates with whom.")
                }
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .padding(.top)

                Section {
                    ForEach(ChatModel.shared.conditions.serverOperators) { op in
                        operatorInfoNavLinkView(op)
                    }
                } header: {
                    Text("About operators")
                        .foregroundColor(theme.colors.secondary)
                }
            }
            .navigationTitle("Server operators")
            .navigationBarTitleDisplayMode(.large)
            .modifier(ThemedBackground(grouped: true))
        }
    }

    private func operatorInfoNavLinkView(_ op: ServerOperator) -> some View {
        NavigationLink() {
            OperatorInfoView(serverOperator: op)
                .navigationBarTitle("Network operator")
                .modifier(ThemedBackground(grouped: true))
                .navigationBarTitleDisplayMode(.large)
        } label: {
            HStack {
                Image(op.logo(colorScheme))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                Text(op.tradeName)
            }
        }
    }
}

struct OnboardingConditionsView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingConditionsView(selectedOperatorIds: [])
    }
}
