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

    /// 第 4 屏必须在 393×852 上一屏点完：主按钮钉进底部安全区，卡片间距与承诺行内边距按屏高收一档，
    /// 三条承诺改为短句摘要，法务两本文档并排成双胶囊。判据同样是 GeometryReader 的可用高度。
    var body: some View {
        GeometryReader { g in
            let compact = g.size.height < 900
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? PopopxMetrics.spaceS : PopopxMetrics.spaceL) {
                    PopopxOnboardingHeader(
                        step: 3,
                        steps: 3,
                        stage: PopopxOnboardingCopy.stageCommitments,
                        title: PopopxOnboardingCopy.commitmentsTitle
                    )
                    .padding(.horizontal, PopopxMetrics.gutter)

                    commitmentsCard(compact: compact)

                    launchCard(compact: compact)

                    legalCard(compact: compact)
                }
                .padding(.top, PopopxMetrics.spaceS)
                .padding(.bottom, PopopxMetrics.spaceM)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: PopopxMetrics.spaceS) {
            enterBar
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

    /// 底部固定栏：主按钮 + 闸门提示，不透明底与发丝线同第 1、3 屏。
    /// 提示语留在栏内，勾选进度变化时它就在按钮上方原地消失，不必下滑去找原因。
    private var enterBar: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            enterButton
            gateHint
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

    // MARK: - 卡片

    private func commitmentsCard(compact: Bool) -> some View {
        PopopxSectionCard(PopopxOnboardingCopy.commitmentsCard) {
            commitmentRow(PopopxOnboardingCopy.commitmentRelay, isOn: $relayCommitted, compact: compact)
                .padding(.vertical, compact ? PopopxMetrics.space2XS : PopopxMetrics.spaceXS)
            commitmentRow(PopopxOnboardingCopy.commitmentRouting, isOn: $routingCommitted, compact: compact)
                .padding(.vertical, compact ? PopopxMetrics.space2XS : PopopxMetrics.spaceXS)
            commitmentRow(PopopxOnboardingCopy.commitmentWipe, isOn: $wipeCommitted, compact: compact)
                .padding(.vertical, compact ? PopopxMetrics.space2XS : PopopxMetrics.spaceXS)
        }
    }

    /// 承诺行必须整行可点：`PopopxCheckbox` 走的是自定义 `ToggleStyle`，真机上命中区只有行尾
    /// 那枚 16pt 方格，三句承诺读起来像纯文案（`agreementRow` 当初就因为同一件事在本文件里
    /// 自己组合）。这里沿用那套写法，但不动共享的 `PopopxControls.swift`，其它调用点保持原样：
    /// 外层 `Button` + `contentShape(Rectangle())` 铺满整行，选中态叠三重信号
    /// （brand 8% 行底、1pt brand 描边、实心方格 + 纯白加粗勾），触觉仍在点击这一侧发。
    private func commitmentRow(_ title: String, isOn: Binding<Bool>, compact: Bool) -> some View {
        let checked = isOn.wrappedValue
        return Button {
            PopopxHaptics.selection()
            withAnimation(PopopxSpring.snappy) {
                isOn.wrappedValue.toggle()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
                Text(title)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(checked ? PopopxPalette.brand : PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: PopopxMetrics.spaceXS)
                Image(systemName: "checkmark")
                    .font(PopopxType.microTag)
                    .fontWeight(.bold)
                    .foregroundStyle(checked ? PopopxPalette.onBrand : Color.clear)
                    .frame(width: PopopxMetrics.spaceM, height: PopopxMetrics.spaceM)
                    .background(
                        checked ? PopopxPalette.brand : Color.clear,
                        in: .rect(cornerRadius: PopopxMetrics.radiusChip)
                    )
                    // 未选中的方格也要读得出是个方格：card 上 `separator` 只有 1.19:1，
                    // `labelHint` 是 3.42:1。
                    .overlay(
                        RoundedRectangle(cornerRadius: PopopxMetrics.radiusChip)
                            .strokeBorder(
                                PopopxPalette.labelHint,
                                lineWidth: PopopxMetrics.stroke
                            )
                            .opacity(checked ? 0 : 1)
                    )
            }
            .padding(.horizontal, PopopxMetrics.spaceXS)
            .padding(.vertical, compact ? PopopxMetrics.space2XS : PopopxMetrics.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                checked ? PopopxPalette.brand.opacity(0.08) : Color.clear,
                in: .rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
                    .strokeBorder(
                        checked ? PopopxPalette.brand : PopopxPalette.hairlineInner,
                        lineWidth: checked ? PopopxMetrics.divider : PopopxMetrics.hairline
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
        .accessibilityLabel(title)
        .accessibilityAddTraits(checked ? .isSelected : [])
        .popopxAnimation(PopopxSpring.snappy, value: checked, reduceMotion: reduceMotion)
    }

    /// Face ID 卡在本文件内组合，没有用 `PopopxToggleRow`：那个原子固定给 8pt 上下内边距，
    /// 写在共享的 `PopopxControls.swift` 里，本轮不能改，而这 16pt 恰好是第 4 屏
    /// 393×852 上要不要下滑的分界。这里逐条沿用它的几何（同一对字号、`spaceS` 间距、
    /// `spaceXL` 徽章、`.switch` 样式与 brand 着色），只把垂直内边距按屏高收一档。
    private func launchCard(compact: Bool) -> some View {
        PopopxSectionCard(PopopxOnboardingCopy.launchProtection) {
            Toggle(isOn: $biometricOn) {
                HStack(alignment: .center, spacing: PopopxMetrics.spaceS) {
                    PopopxOnboardingIconBadge(systemName: "faceid", tint: .brand)
                    VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                        Text(PopopxOnboardingCopy.biometricRow)
                            .font(PopopxType.sectionHeader)
                            .foregroundStyle(PopopxPalette.label)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(biometricAvailable
                                ? PopopxOnboardingCopy.biometricNote
                                : PopopxOnboardingCopy.biometricUnavailable)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: PopopxMetrics.spaceXS)
                }
            }
            .toggleStyle(.switch)
            .tint(PopopxPalette.brand)
            .disabled(!biometricAvailable)
            .padding(.vertical, compact ? PopopxMetrics.space2XS : PopopxMetrics.spaceS)
            .contentShape(Rectangle())
            .popopxAnimation(PopopxSpring.snappy, value: biometricOn, reduceMotion: reduceMotion)
        }
    }

    /// 法务卡：两本文档从"占两行的 Disclosure 行"改成左右并排的双胶囊，垂直空间省一行；
    /// 胶囊下面紧跟整行可点的同意行。标题仍是同一对 Key，与离线阅读器的页头逐字一致。
    private func legalCard(compact: Bool) -> some View {
        PopopxSectionCard(
            PopopxOnboardingCopy.legalCard,
            footnote: PopopxOnboardingCopy.legalReadableOffline
        ) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                legalCapsule(
                    PopopxOnboardingCopy.privacyPolicy,
                    systemImage: "hand.raised.fill",
                    doc: .privacy
                )
                legalCapsule(
                    PopopxOnboardingCopy.termsOfUse,
                    systemImage: "doc.text.fill",
                    doc: .terms
                )
            }
            PopopxOnboardingHairline()
            agreementRow
                .padding(.top, compact ? PopopxMetrics.space2XS : PopopxMetrics.spaceXS)
                .popopxAnimation(PopopxSpring.snappy, value: agreed, reduceMotion: reduceMotion)
        }
    }

    /// 单颗文档胶囊：整枚可点，命中高度不低于 `minHitTarget`；窄语种允许两行，
    /// 绝不省略成 "POPOPX Privacy…"，法务入口的标题被截断就等于没给全。
    private func legalCapsule(
        _ title: String,
        systemImage: String,
        doc: PopopxLegalDocumentSheet.Document
    ) -> some View {
        Button {
            PopopxHaptics.selection()
            document = doc
        } label: {
            HStack(alignment: .center, spacing: PopopxMetrics.space2XS) {
                Image(systemName: systemImage)
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.brand)
                Text(title)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.label)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.brand.opacity(0.10), in: .capsule)
            .overlay(
                Capsule()
                    .strokeBorder(PopopxPalette.brand.opacity(0.35), lineWidth: PopopxMetrics.hairline)
            )
            .contentShape(.capsule)
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
    }

    // MARK: - 同意行（勾选 + 行内热区）

    /// `PopopxCheckbox` 的标题收的是 `String`，装不下可点热区；而 `Text` 拼接出来的
    /// 片段不能被单独点击。所以这一行在本文件内组合：左格沿用
    /// `PopopxCheckboxToggleStyle` 的几何与配色（`spaceM` 方格、`radiusChip`、
    /// brand/onBrand 填充、未选中用 `labelHint` 描边），右句整段走 `openURL` 拦截，
    /// 命中本文件的 `popopx://legal/*` 才弹阅读器，其余 URL 仍交回系统。
    private var agreementRow: some View {
        ZStack(alignment: .topLeading) {
            // 整行热区放在最下层：SwiftUI 只对"挂了手势的视图"做命中，普通文字与空白不吃命中，
            // 点击会落到这枚透明按钮上；《隐私政策》《使用条款》两个书名是可交互的 run，
            // 命中留在它们身上，由下面的 openURL 拦截接走，不会被误勾选。
            // 方格自己仍是独立按钮，VoiceOver 的控件也仍是它（这层透明按钮对无障碍隐藏）。
            Button {
                toggleAgreement()
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            agreementContent
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let doc = PopopxLegalLink.document(for: url) else { return .systemAction }
            PopopxHaptics.selection()
            document = doc
            return .handled
        })
    }

    private var agreementContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            Button {
                toggleAgreement()
            } label: {
                Image(systemName: "checkmark")
                    .font(PopopxType.microTag)
                    .fontWeight(.bold)
                    .foregroundStyle(agreed ? PopopxPalette.onBrand : Color.clear)
                    .frame(width: PopopxMetrics.spaceM, height: PopopxMetrics.spaceM)
                    .background(
                        agreed ? PopopxPalette.brand : Color.clear,
                        in: .rect(cornerRadius: PopopxMetrics.radiusChip)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: PopopxMetrics.radiusChip)
                            .strokeBorder(
                                PopopxPalette.labelHint,
                                lineWidth: PopopxMetrics.stroke
                            )
                            .opacity(agreed ? 0 : 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PopopxOnboardingCopy.legalAgreement)
            .accessibilityAddTraits(agreed ? .isSelected : [])

            agreementSentence
                .font(PopopxType.sectionHeader)
                .foregroundStyle(PopopxPalette.label)
                .tint(PopopxPalette.brand)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleAgreement() {
        PopopxHaptics.selection()
        withAnimation(PopopxSpring.snappy) {
            agreed.toggle()
        }
    }

    /// 切句只认"标题在原句中出现"，且按隐私政策、使用条款的顺序各切一次。
    /// 某语言没命中时那段原样留在正文里 —— 宁可不带链接，也不丢字。
    private var agreementSentence: Text {
        let docs: [PopopxLegalDocumentSheet.Document] = [.privacy, .terms]
        let sentence = String(
            format: PopopxOnboardingCopy.legalAgreementLinks,
            docs[0].title,
            docs[1].title
        )
        var result = Text(verbatim: "")
        var rest = Substring(sentence)
        for doc in docs {
            let title = doc.title
            guard let range = rest.range(of: title) else { continue }
            result = result
                + Text(verbatim: String(rest[rest.startIndex..<range.lowerBound]))
                + Text(PopopxLegalLink.styled(title, url: PopopxLegalLink.url(for: doc)))
            rest = rest[range.upperBound..<rest.endIndex]
        }
        return result + Text(verbatim: String(rest))
    }

    // MARK: - 闸门

    private var commitmentsMet: Bool { relayCommitted && routingCommitted && wipeCommitted }

    /// 闸门只看这页能改的两件事。`selectedOperatorIds` 不参与判定：它是从第 3 屏带过来的值，
    /// 单运营商、或 conditions 里根本没有运营商时可能为空，而第 4 屏没有任何入口能改它
    /// ——那会把「同意并进入」永久锁死（真机 P0 的第二条成因）。
    private var canEnter: Bool { commitmentsMet && agreed }

    /// 集合为空时回落到全部已知运营商，与上游同一条链一致：
    /// `NetworkAndServers.swift:288` 直接把展示出来的 operators 整份 `map` 过去。
    private var operatorIdsToSubmit: [Int64] {
        let ids = Array(selectedOperatorIds)
        return ids.isEmpty ? m.conditions.serverOperators.map { $0.operatorId } : ids
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
            let r = try await acceptConditions(conditionsId: conditionsId, operatorIds: operatorIdsToSubmit)
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

/// 同意行的行内热区：URL 只在本文件内解析，不交给系统、也不打开网页。
private enum PopopxLegalLink {
    static func url(for document: PopopxLegalDocumentSheet.Document) -> URL {
        switch document {
        case .privacy: return URL(string: "popopx://legal/privacy")!
        case .terms: return URL(string: "popopx://legal/terms")!
        }
    }

    static func document(for url: URL) -> PopopxLegalDocumentSheet.Document? {
        guard url.scheme == "popopx", url.host == "legal" else { return nil }
        switch url.lastPathComponent {
        case "privacy": return .privacy
        case "terms": return .terms
        default: return nil
        }
    }

    static func styled(_ title: String, url: URL) -> AttributedString {
        var attributed = AttributedString(title)
        attributed.link = url
        attributed.foregroundColor = PopopxPalette.brand
        return attributed
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var serverOperators: [ServerOperator]
    @Binding var selectedOperatorIds: Set<Int64>
    @State private var sheetItem: ChooseServerOperatorsSheet? = nil

    var body: some View {
        PopopxSheetContainer(
            PopopxOnboardingCopy.operatorsTitle,
            subtitle: PopopxOnboardingCopy.operatorsNote
        ) {
            PopopxPickerRow(
                PopopxOnboardingCopy.operatorsHowItHelps,
                systemImage: "info.circle",
                tint: .brand
            ) {
                sheetItem = .showInfo
            }
            .padding(.horizontal, PopopxMetrics.gutter)

            VStack(spacing: PopopxMetrics.spaceS) {
                ForEach(serverOperators) { srvOperator in
                    operatorCheckView(srvOperator)
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
        } footer: {
            PopopxButton(PopopxOnboardingCopy.operatorsOK, systemImage: "checkmark") {
                dismiss()
            }
            .disabled(selectedOperatorIds.isEmpty)
            .padding(PopopxMetrics.spaceM)
        }
        .sheet(item: $sheetItem) { item in
            switch item {
            case .showInfo:
                ChooseServerOperatorsInfoView()
            }
        }
        .interactiveDismissDisabled(selectedOperatorIds.isEmpty)
    }

    private func operatorCheckView(_ serverOperator: ServerOperator) -> some View {
        let checked = selectedOperatorIds.contains(serverOperator.operatorId)
        return Button {
            PopopxHaptics.selection()
            if checked {
                selectedOperatorIds.remove(serverOperator.operatorId)
            } else {
                selectedOperatorIds.insert(serverOperator.operatorId)
            }
        } label: {
            HStack(spacing: PopopxMetrics.spaceM) {
                Image(serverOperator.largeLogo(colorScheme))
                    .resizable()
                    .scaledToFit()
                    .frame(height: PopopxMetrics.space2XL)
                Spacer(minLength: PopopxMetrics.spaceXS)
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
                    .foregroundStyle(checked ? PopopxPalette.brand : PopopxPalette.labelHint)
            }
            .padding(PopopxMetrics.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                PopopxPalette.card,
                in: .rect(cornerRadius: PopopxMetrics.radiusCard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard, style: .continuous)
                    .strokeBorder(
                        checked ? PopopxPalette.brand : PopopxPalette.hairlineInner,
                        lineWidth: checked ? PopopxMetrics.stroke : PopopxMetrics.hairline
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked ? .isSelected : [])
        .popopxAnimation(PopopxSpring.snappy, value: checked, reduceMotion: reduceMotion)
    }
}

struct ChooseServerOperatorsInfoView: View {
    @Environment(\.colorScheme) var colorScheme: ColorScheme

    var body: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                    Text("The app protects your privacy by using different operators in each conversation.")
                    Text("When more than one operator is enabled, none of them has metadata to learn who communicates with whom.")
                }
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: PopopxMetrics.spaceS, trailing: 0))
                .padding(.top)

                Section {
                    ForEach(ChatModel.shared.conditions.serverOperators) { op in
                        operatorInfoNavLinkView(op)
                    }
                } header: {
                    Text(PopopxOnboardingCopy.operatorsAbout)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                }
            }
            .navigationTitle(PopopxOnboardingCopy.operatorsTitle)
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
                    .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
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
