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

// The privacy statement POPOPX shows in its consent flows. Single place to edit; it is the policy file
// in this repository, which is where the text is published - the site serves no /privacy page.
let popopxPrivacyURL = URL(string: "https://github.com/popopx-chat/popopx-chat/blob/master/PRIVACY.md")!
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
// Onboarding screen 4: three safety commitments + launch protection + two built-in legal documents.
// The order of the "agree and enter" chain cannot be swapped: first persist the server-side conditions acceptance, then the biometric attestation,
// and lastly the idempotent pioneer badge grant with both toasts awaited to the end; only then is the onboarding stack torn down.
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

    /// Screen 4 has to be finished with one screen of taps at 393×852: the primary button is pinned into the bottom safe area, the card gap and the commitment row's inner padding each tighten one notch by screen height,
    /// the three commitments become short-phrase summaries and the two legal documents sit side by side as two capsules. The deciding measure is again GeometryReader's available height.
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

    /// Fixed bottom bar: primary button + gate hint, with the same opaque background and hairline as screens 1 and 3.
    /// The hint stays inside the bar: when the check progress changes it disappears in place above the button, so there is no need to swipe down hunting for the reason.
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

    // MARK: - Cards

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

    /// The commitment row has to be tappable across the whole row: `PopopxCheckbox` uses a custom `ToggleStyle`, and on a real device the hit area is only
    /// the 16pt square at the row's end, so the three commitments read like plain copy (`agreementRow` was composed inside this file for that very reason
    /// in the first place). That same approach is reused here without touching the shared `PopopxControls.swift`, and other call sites stay as they were:
    /// an outer `Button` + `contentShape(Rectangle())` spread over the whole row, and the selected state stacks three signals
    /// (an 8% brand row background, a 1pt brand stroke, a filled square + a bold pure-white checkmark), while the haptic is still fired on the tap side.
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
                    // An unchecked square must still read as a square: on card `separator` is only 1.19:1,
                    // while `labelHint` is 3.42:1.
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

    /// The Face ID card is composed inside this file and does not use `PopopxToggleRow`: that atom fixes 8pt of top and bottom padding,
    /// it is written in the shared `PopopxControls.swift` and cannot be changed this round, and those 16pt are exactly the divide for screen 4 on
    /// 393×852 between needing a swipe down and not needing one. Its geometry is followed item by item here (the same pair of font sizes, the `spaceS` gap,
    /// the `spaceXL` badge, the `.switch` style and the brand tint), with only the vertical padding tightened one notch by screen height.
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

    /// Legal card: the two documents change from "Disclosure rows taking two lines" into two capsules side by side, saving one line of vertical space;
    /// immediately below the capsules comes the whole-row-tappable agreement line. The titles are still the same pair of Keys, matching the offline reader's page header word for word.
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

    /// One document capsule: the whole capsule is tappable and the hit height never falls below `minHitTarget`; narrow languages may use two lines,
    /// but it is never truncated to "POPOPX Privacy...": a legal entry's title cut short is the same as not giving it in full.
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

    // MARK: - Agreement row (checkbox + inline hot zone)

    /// `PopopxCheckbox`'s title takes a `String`, which cannot hold a tappable hot zone, and fragments glued together with `Text`
    /// cannot be tapped on their own. So this row is composed inside this file: the left square keeps
    /// `PopopxCheckboxToggleStyle`'s geometry and colours (the `spaceM` square, `radiusChip`,
    /// brand/onBrand fill, the `labelHint` stroke when unchecked), and the whole right-hand sentence goes through an `openURL` interception,
    /// so the reader opens only for this file's `popopx://legal/*` pattern; every other URL is still handed back to the system.
    private var agreementRow: some View {
        ZStack(alignment: .topLeading) {
            // The whole-row hot zone sits on the lowest layer: SwiftUI only hit-tests views that carry a gesture, and ordinary text and blank space take no hits,
            // so taps land on this transparent button; the Privacy Policy and Terms of Use titles are interactive runs whose
            // hits stay on them and are picked up by the openURL interception below, so they cannot be mis-checked.
            // The square itself is still a standalone button and is still the VoiceOver control (this transparent button layer is hidden from accessibility).
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

    /// The sentence is split only where "the title occurs in the original sentence", once each in the order Privacy Policy then Terms of Use.
    /// If some language does not hit, that span stays in the body text exactly as it is - better to carry no link than to lose a word.
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

    // MARK: - Gate

    private var commitmentsMet: Bool { relayCommitted && routingCommitted && wipeCommitted }

    /// The gate looks only at the two things this page can change. `selectedOperatorIds` takes no part in the verdict: it is a value carried in from screen 3,
    /// and it can be empty with a single operator or when conditions has no operators at all, while screen 4 has no entry that could change it
    /// - that would lock "agree and enter" shut forever (the second cause of the P0 on a real device).
    private var canEnter: Bool { commitmentsMet && agreed }

    /// When the set is empty it falls back to every known operator, matching the same chain upstream:
    /// `NetworkAndServers.swift:288` just `map`s the whole displayed operators list over.
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

    // MARK: - Completion chain

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

        // Idempotent: `PopopxBadgeManager` persists `.trialGuard` before the badge, so a repeated call only returns nil,
        // and therefore this chain on the fourth screen never burns a second 72 hours (ruling 2).
        _ = await PopopxBadgeManager.shared.issuePioneerTrialIfNeeded()

        toast.show(PopopxToastMessage(text: PopopxOnboardingCopy.readyToast, kind: .encrypted, duration: Self.toastHold))
        toast.show(PopopxToastMessage(text: PopopxOnboardingCopy.badgeToast, kind: .mesh, duration: Self.toastHold))
        try? await Task.sleep(for: Self.toastPair)
        PopopxHaptics.impact(.heavy)
        completeOnboarding()
    }

    /// The same contract as `ContentView.initialEnableLA()` (ContentView.swift:429):
    /// mode goes back to `.system` -> system biometric attestation -> only on success are `prefPerformLA` and the app group mirror written.
    /// Failure or unavailability always writes false back, never leaving "the switch is on but was never proven".
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

/// The inline hot zone of the agreement row: URLs are resolved only inside this file, never handed to the system and never opened as web pages.
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
