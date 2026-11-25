//
//  PopopxControls.swift
//  POPOPX (iOS)
//
//  The atomic control library every popopx screen is built from. Colour, type and
//  spacing come only from PopopxTheme.swift; no control here reads AppTheme, and no
//  user-facing string is hardcoded — copy arrives from the caller so the existing
//  localization catalogs keep working.
//
//  Docs/popopx-brand-spec.md §1.4, §2.3, §4, §5.
//

import SwiftUI
import UIKit

// MARK: - Press feedback

/// The scale leg of the triple feedback. Fires on pointer-down, not on release, so
/// the haptic and the visual are the same frame.
struct PopopxPressButtonStyle: ButtonStyle {
    /// `nil` for controls that already make their own haptic (a toggle, a slider).
    var feedback: PopopxHapticImpact? = .light

    func makeBody(configuration: Configuration) -> some View {
        PopopxPressBody(configuration: configuration, feedback: feedback)
    }
}

private struct PopopxPressBody: View {
    let configuration: ButtonStyleConfiguration
    let feedback: PopopxHapticImpact?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? PopopxSpring.pressScale : 1)
            .popopxAnimation(PopopxSpring.snappy, value: configuration.isPressed, reduceMotion: reduceMotion)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed, let feedback { PopopxHaptics.impact(feedback) }
            }
    }
}

// MARK: - Button

enum PopopxButtonRole: Hashable {
    case primary, secondary, ghost, destructive
}

struct PopopxButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    private let title: String
    private let systemImage: String?
    private let role: PopopxButtonRole
    private let fullWidth: Bool
    private let externalLoading: Bool
    private let action: () async -> Void

    @State private var isRunning = false
    @State private var showsSuccess = false
    @State private var busyWasSeen = false

    init(
        _ title: String,
        systemImage: String? = nil,
        role: PopopxButtonRole = .primary,
        fullWidth: Bool = true,
        isLoading: Bool = false,
        action: @escaping () async -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.fullWidth = fullWidth
        self.externalLoading = isLoading
        self.action = action
    }

    private var isBusy: Bool { externalLoading || isRunning }
    private var canFire: Bool { isEnabled && !isBusy }

    var body: some View {
        Button(action: run) { label }
            .buttonStyle(PopopxPressButtonStyle(feedback: role == .destructive ? .medium : .light))
            .disabled(!canFire)
            .opacity(isEnabled ? 1 : 0.45)
            .onChange(of: isBusy) { _, busy in
                if busy {
                    busyWasSeen = true
                } else if busyWasSeen {
                    busyWasSeen = false
                    flashSuccess()
                }
            }
    }

    @ViewBuilder private var label: some View {
        content
            .font(PopopxType.emphasis)
            .foregroundStyle(inkColor)
            .padding(.horizontal, PopopxMetrics.spaceM)
            .padding(.vertical, PopopxMetrics.spaceS)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: PopopxMetrics.minHitTarget)
            .background(fillColor, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .overlay {
                if role == .secondary {
                    RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                        .strokeBorder(PopopxPalette.labelHint, lineWidth: PopopxMetrics.divider)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl))
            .popopxAnimation(PopopxSpring.fluid, value: showsSuccess, reduceMotion: reduceMotion)
            .popopxAnimation(PopopxSpring.fluid, value: isBusy, reduceMotion: reduceMotion)
    }

    @ViewBuilder private var content: some View {
        ZStack {
            HStack(spacing: PopopxMetrics.spaceXS) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .opacity(isBusy || showsSuccess ? 0 : 1)

            if isBusy {
                ProgressView()
                    .controlSize(.regular)
                    .tint(inkColor)
            } else if showsSuccess {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
            }
        }
    }

    /// The green is a *flash*, never a resting state: it marks the end of one action
    /// and leaves before the next one can be mistaken for it.
    private var fillColor: Color {
        if showsSuccess { return PopopxPalette.success }
        switch role {
        case .primary: return PopopxPalette.brand
        case .secondary: return PopopxPalette.card
        case .ghost: return Color.clear
        case .destructive: return PopopxPalette.dangerFill
        }
    }

    private var inkColor: Color {
        if showsSuccess { return PopopxPalette.onSuccess }
        switch role {
        case .primary: return PopopxPalette.onBrand
        case .secondary: return PopopxPalette.label
        case .ghost: return PopopxPalette.brand
        case .destructive: return PopopxPalette.onDanger
        }
    }

    @MainActor private func run() {
        guard canFire else { return }
        isRunning = true
        Task { @MainActor in
            await action()
            isRunning = false
        }
    }

    @MainActor private func flashSuccess() {
        showsSuccess = true
        PopopxHaptics.notice(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            showsSuccess = false
        }
    }
}

// MARK: - Text input

struct PopopxTextField: View {
    @Binding private var text: String
    private let label: String
    private let prompt: String
    private let systemImage: String?
    private let isSecure: Bool
    private let keyboard: UIKeyboardType
    private var onSubmit: ((String) -> Void)?

    @FocusState private var isFocused: Bool

    init(
        _ label: String,
        prompt: String = "",
        text: Binding<String>,
        systemImage: String? = nil,
        isSecure: Bool = false,
        keyboard: UIKeyboardType = .default,
        onSubmit: ((String) -> Void)? = nil
    ) {
        self.label = label
        self.prompt = prompt
        self._text = text
        self.systemImage = systemImage
        self.isSecure = isSecure
        self.keyboard = keyboard
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(PopopxType.body)
                    .foregroundStyle(isFocused ? PopopxPalette.brand : PopopxPalette.labelSecondary)
                    .frame(width: PopopxMetrics.spaceXL)
            }
            field
                .focused($isFocused)
        }
        .padding(.horizontal, PopopxMetrics.spaceS)
        .frame(minHeight: PopopxMetrics.minHitTarget)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                .strokeBorder(
                    isFocused ? PopopxPalette.brand : PopopxPalette.labelHint,
                    lineWidth: isFocused ? PopopxMetrics.stroke : PopopxMetrics.divider
                )
        )
        .accessibilityLabel(label)
    }

    @ViewBuilder private var field: some View {
        if isSecure {
            SecureField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(submit)
        } else {
            TextField(prompt, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)
                .onSubmit(submit)
        }
    }

    private func submit() {
        onSubmit?(text)
    }
}

struct PopopxTextArea: View {
    @Binding private var text: String
    private let label: String
    private let prompt: String

    @FocusState private var isFocused: Bool

    init(_ label: String, prompt: String = "", text: Binding<String>) {
        self.label = label
        self.prompt = prompt
        self._text = text
    }

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .font(PopopxType.body)
            .lineLimit(3...8)
            .focused($isFocused)
            .padding(PopopxMetrics.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                    .strokeBorder(
                        isFocused ? PopopxPalette.brand : PopopxPalette.labelHint,
                        lineWidth: isFocused ? PopopxMetrics.stroke : PopopxMetrics.divider
                    )
            )
            .accessibilityLabel(label)
    }
}

// MARK: - Selection

/// The SF Symbol chip in front of a settings row. Each case is a fill and the ink
/// that actually clears AA on it, so a badge can never be assembled wrongly.
enum PopopxIconTint: Hashable {
    case brand, mesh, danger, success, neutral

    var fill: Color {
        switch self {
        case .brand: PopopxPalette.brand
        case .mesh: PopopxPalette.mesh
        case .danger: PopopxPalette.dangerFill
        case .success: PopopxPalette.success
        case .neutral: PopopxPalette.separator
        }
    }

    var ink: Color {
        switch self {
        case .brand: PopopxPalette.onBrand
        case .mesh: PopopxPalette.onMesh
        case .danger: PopopxPalette.onDanger
        case .success: PopopxPalette.onSuccess
        case .neutral: PopopxPalette.label
        }
    }
}

private struct PopopxIconBadge: View {
    let systemName: String
    let tint: PopopxIconTint

    var body: some View {
        Image(systemName: systemName)
            .font(PopopxType.microTag)
            .imageScale(.medium)
            .foregroundStyle(tint.ink)
            .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
            .background(tint.fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
            .accessibilityHidden(true)
    }
}

private struct PopopxRowLabel: View {
    let title: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(title)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PopopxToggle: View {
    @Binding private var isOn: Bool
    private let label: String

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        Toggle(label, isOn: $isOn)
            .font(PopopxType.body)
            .tint(PopopxPalette.brand)
    }
}

/// Whole-row switch. The row is the `Toggle`'s own label, so the 44pt hit area and
/// the VoiceOver state come from the system rather than a hand-rolled gesture.
struct PopopxToggleRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding private var isOn: Bool
    private let title: String
    private let note: String?
    private let badge: (String, PopopxIconTint)?

    init(
        _ title: String,
        note: String? = nil,
        systemImage: String? = nil,
        tint: PopopxIconTint = .brand,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.note = note
        self.badge = systemImage.map { ($0, tint) }
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: PopopxMetrics.spaceS) {
                if let badge {
                    PopopxIconBadge(systemName: badge.0, tint: badge.1)
                }
                PopopxRowLabel(title: title, note: note)
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
        }
        .toggleStyle(.switch)
        .tint(PopopxPalette.brand)
        .popopxAnimation(PopopxSpring.snappy, value: isOn, reduceMotion: reduceMotion)
        .padding(.vertical, PopopxMetrics.spaceXS)
        .contentShape(Rectangle())
    }
}

struct PopopxCheckbox: View {
    @Binding private var isOn: Bool
    private let title: String
    private let note: String?

    init(_ title: String, note: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.note = note
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            PopopxRowLabel(title: title, note: note)
        }
        .toggleStyle(PopopxCheckboxToggleStyle())
        .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

struct PopopxCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            configuration.label
            Spacer(minLength: PopopxMetrics.spaceXS)
            Image(systemName: "checkmark")
                .font(PopopxType.microTag)
                .fontWeight(.bold)
                .foregroundStyle(configuration.isOn ? PopopxPalette.onBrand : Color.clear)
                .frame(width: PopopxMetrics.spaceM, height: PopopxMetrics.spaceM)
                .background(
                    configuration.isOn ? PopopxPalette.brand : Color.clear,
                    in: .rect(cornerRadius: PopopxMetrics.radiusChip)
                )
                // An unchecked box still has to read as a box: `separator` would be
                // 1.19:1 on a card, `labelHint` is 3.42:1.
                .overlay(
                    RoundedRectangle(cornerRadius: PopopxMetrics.radiusChip)
                        .strokeBorder(
                            PopopxPalette.labelHint,
                            lineWidth: PopopxMetrics.stroke
                        )
                        .opacity(configuration.isOn ? 0 : 1)
                )
        }
        .contentShape(Rectangle())
    }
}

struct PopopxRadioRow: View {
    private let title: String
    private let note: String?
    private let isSelected: Bool
    private let action: () -> Void

    init(
        _ title: String,
        note: String? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.note = note
        self.isSelected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxRowLabel(title: title, note: note)
                Spacer(minLength: PopopxMetrics.spaceXS)
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? PopopxPalette.brand : PopopxPalette.labelHint,
                            lineWidth: PopopxMetrics.stroke
                        )
                    if isSelected {
                        Circle()
                            .fill(PopopxPalette.brand)
                            .padding(PopopxMetrics.spaceXS)
                    }
                }
                .frame(width: PopopxMetrics.spaceM, height: PopopxMetrics.spaceM)
            }
            .padding(.vertical, PopopxMetrics.spaceXS)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A settings disclosure row: title, current value, chevron. The caller owns the
/// navigation, so this stays a button and never a hidden `Picker`.
struct PopopxPickerRow: View {
    private let title: String
    private let value: String?
    private let badge: (String, PopopxIconTint)?
    private let action: () -> Void

    init(
        _ title: String,
        value: String? = nil,
        systemImage: String? = nil,
        tint: PopopxIconTint = .neutral,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.value = value
        self.badge = systemImage.map { ($0, tint) }
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: PopopxMetrics.spaceS) {
                if let badge {
                    PopopxIconBadge(systemName: badge.0, tint: badge.1)
                }
                Text(title)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
                if let value {
                    Text(value)
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.labelHint)
            }
            .padding(.vertical, PopopxMetrics.spaceXS)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
    }
}

struct PopopxSegmentedControl<Selection: Hashable>: View {
    struct Option {
        let selection: Selection
        let title: String
    }

    @Namespace private var pillNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let options: [Option]
    private var title: (Selection) -> String
    @Binding private var selection: Selection

    init(
        _ options: [Option],
        title: @escaping (Selection) -> String,
        selection: Binding<Selection>
    ) {
        self.options = options
        self.title = title
        self._selection = selection
    }

    var body: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            ForEach(options, id: \.selection) { option in
                Button {
                    guard selection != option.selection else { return }
                    PopopxHaptics.selection()
                    selection = option.selection
                } label: {
                    Text(title(option.selection))
                        .font(PopopxType.emphasis)
                        .foregroundStyle(
                            selection == option.selection
                                ? PopopxPalette.onBrand
                                : PopopxPalette.labelSecondary
                        )
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: PopopxMetrics.spaceXL)
                        .background {
                            if selection == option.selection {
                                RoundedRectangle(
                                    cornerRadius: PopopxMetrics.radiusChip,
                                    style: .continuous
                                )
                                .fill(PopopxPalette.brand)
                                .matchedGeometryEffect(
                                    id: "popopx.segment",
                                    in: pillNamespace,
                                    isSource: false
                                )
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PopopxPressButtonStyle(feedback: nil))
                .accessibilityAddTraits(selection == option.selection ? .isSelected : [])
            }
        }
        .padding(PopopxMetrics.space2XS)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                .strokeBorder(PopopxPalette.labelHint, lineWidth: PopopxMetrics.divider)
        )
        .popopxAnimation(PopopxSpring.snappy, value: selection, reduceMotion: reduceMotion)
    }
}

struct PopopxSliderRow: View {
    private let title: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double?
    private let valueText: (Double) -> String

    init(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        valueText: @escaping (Double) -> String = { String(Int($0)) }
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.valueText = valueText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
                Text(valueText(value))
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .accessibilityHidden(true)
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .tint(PopopxPalette.brand)
    }
}

// MARK: - Containers

/// Grouped card: 16pt corner radius, 16pt inner padding, shadow in light mode and a
/// 0.5pt highlight in dark. Section spacing between two of these is the outer
/// container's job (`PopopxMetrics.spaceL`), which keeps the card nesting-safe.
struct PopopxSectionCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    private let title: String?
    private let footnote: String?
    private let content: Content

    init(
        _ title: String? = nil,
        footnote: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            if let title {
                Text(title)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                    .padding(.leading, PopopxMetrics.space2XS)
            }
            VStack(spacing: 0) { content }
                .padding(PopopxMetrics.spaceM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
                .overlay(
                    RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                        .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
                )
                .popopxCardElevation(colorScheme: colorScheme)
            if let footnote {
                Text(footnote)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .padding(.leading, PopopxMetrics.space2XS)
            }
        }
        .padding(.horizontal, PopopxMetrics.gutter)
    }
}

/// The body of a sheet: drag indicator, title block, scrolling content and an
/// optional pinned action bar. Dismissal chrome is deliberately absent — the caller
/// owns it via `.presentationDragIndicator` and a toolbar, so no string lives here.
struct PopopxSheetContainer<Content: View, Footer: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    private let title: String
    private let subtitle: String?
    private let content: Content
    private let footer: Footer

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(PopopxPalette.separator)
                .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.space2XS)
                .padding(.top, PopopxMetrics.spaceXS)

            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(title)
                    .font(PopopxType.title)
                    .foregroundStyle(PopopxPalette.label)
                if let subtitle {
                    Text(subtitle)
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.vertical, PopopxMetrics.spaceS)

            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    content
                }
                .padding(.bottom, PopopxMetrics.space2XL)
            }
            .scrollDismissesKeyboard(.interactively)

            footer
        }
        .background(PopopxPalette.cardHigh)
        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusSheet, style: .continuous))
    }
}

extension PopopxSheetContainer where Footer == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, subtitle: subtitle, content: content, footer: { EmptyView() })
    }
}

#if DEBUG
private struct PopopxControlsGallery: View {
    @State private var nickname = ""
    @State private var bio = ""
    @State private var meshEnabled = true
    @State private var readReceipts = false
    @State private var relayCount = 3.0
    @State private var filter = 0
    @State private var agreed = false
    @State private var transport = 0
    @State private var busy = false
    private let toast = PopopxToastModel()

    var body: some View {
        PopopxSheetContainer("第二阶段控件", subtitle: "PopopxControls") {
            PopopxSectionCard("输入") {
                PopopxTextField("昵称", prompt: "匿名昵称", text: $nickname, systemImage: "person")
                PopopxTextArea("简介", prompt: "一句话", text: $bio)
                    .padding(.top, PopopxMetrics.spaceS)
            }
            PopopxSectionCard("开关与选项") {
                PopopxToggleRow(
                    "厢语离线组网",
                    note: "无网络时经蓝牙中继，最多 7 跳",
                    systemImage: "antenna.radiowaves.left.and.right",
                    tint: .mesh,
                    isOn: $meshEnabled
                )
                PopopxDivider()
                PopopxToggleRow("已读回执", isOn: $readReceipts)
                PopopxDivider()
                PopopxCheckbox("我已了解离线消息会经过附近设备", isOn: $agreed)
                PopopxDivider()
                PopopxRadioRow("青绿 Mesh 优先", selected: transport == 0) { transport = 0 }
                PopopxRadioRow("靛紫 SMP 优先", selected: transport == 1) { transport = 1 }
            }
            PopopxSectionCard("分段与滑杆") {
                PopopxSegmentedControl(
                    [
                        .init(selection: 0, title: "全部"),
                        .init(selection: 1, title: "在线加密"),
                        .init(selection: 2, title: "厢语离线")
                    ],
                    title: { $0 == 0 ? "全部" : ($0 == 1 ? "在线加密" : "厢语离线") },
                    selection: $filter
                )
                PopopxSliderRow("中继跳数上限", value: $relayCount, in: 1...7, step: 1) { "\(Int($0)) 跳" }
            }
            PopopxSectionCard("按钮") {
                PopopxButton("保存", systemImage: "lock.shield.fill") {
                    try? await Task.sleep(for: .milliseconds(700))
                }
                PopopxButton("外部进行中", role: .secondary, isLoading: busy) {
                    busy = false
                }
                .padding(.top, PopopxMetrics.spaceS)
                PopopxButton("清除记录", systemImage: "exclamationmark.triangle.fill", role: .destructive, fullWidth: false) {
                    toast.show("已清除", kind: .danger)
                }
                .padding(.top, PopopxMetrics.spaceS)
            }
        } footer: {
            PopopxButton("完成") { }
                .padding(PopopxMetrics.spaceM)
        }
        .background(PopopxPalette.base)
        .popopxToast(toast)
    }
}

private struct PopopxDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

struct PopopxControlsGallery_Previews: PreviewProvider {
    static var previews: some View {
        PopopxControlsGallery()
    }
}
#endif
