//
//  PopopxTheme.swift
//  POPOPX (iOS)
//
//  popopx design system: dual-mode palette, typography ladder, metrics, materials
//  and spring constants. Docs/popopx-brand-spec.md is the prose contract; the
//  contrast figures it quotes come from Docs/contrast_check.py, so re-run that
//  script after touching a token here.
//

import SwiftUI

// MARK: - Colour construction

extension Color {
    /// An sRGB hex token (`0xRRGGBB`), declared in the sRGB space so the same
    /// literal resolves to the same components in every colour context.
    static func popopx(_ rgb: UInt32, opacity: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// A token that follows the interface style rather than the app's own theme
    /// switch, so system surfaces (sheets, alerts, the keyboard) and popopx
    /// surfaces cannot disagree about which mode they are in.
    static func popopx(light: Color, dark: Color) -> Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
            }
        )
    }

    /// The two-mode form of the same thing, with a per-mode opacity for the
    /// hairlines and washes.
    static func popopx(
        light lightRGB: UInt32,
        dark darkRGB: UInt32,
        lightOpacity: Double = 1,
        darkOpacity: Double = 1
    ) -> Color {
        popopx(
            light: popopx(lightRGB, opacity: lightOpacity),
            dark: popopx(darkRGB, opacity: darkOpacity)
        )
    }
}

// MARK: - Palette

/// Online (SMP) traffic reads as indigo, offline BLE mesh traffic as radar teal.
/// The two are never mixed inside one row, one bubble or one control: which
/// transport carried a message is the one thing the interface must state unambiguously.
enum PopopxPalette {

    // MARK: Brand — online encrypted state (SMP)

    /// Primary buttons, selected Tab state, the sender's online bubble, links.
    static let brand = Color.popopx(light: 0x5856D6, dark: 0x7D7AFF)

    /// Text and glyphs sitting on `brand`.
    ///
    /// Dark mode inverts this to a near-black ink: `#7D7AFF` is bright enough that
    /// white on it reaches only 3.44:1, while `#0A0A1F` on the same fill reaches
    /// 5.67:1.
    static let onBrand = Color.popopx(light: 0xFFFFFF, dark: 0x0A0A1F)

    // MARK: Mesh - offline BLE state (Cabin)

    /// Mesh nodes, the 1–7 hop badge, the radar, `#Cabin` channel affordances.
    static let mesh = Color.popopx(light: 0x00A896, dark: 0x00D2B8)

    /// Teal used as text or as a hairline stroke on a card. `mesh` itself is 2.98:1
    /// on a white card, so in light mode it must never carry a label unaided; this
    /// variant reaches 6.03:1.
    static let meshInk = Color.popopx(light: 0x00705F, dark: 0x00D2B8)

    /// Text and glyphs on a `mesh`-filled chip: a bright teal cannot take white
    /// text (2.98:1 light, 1.92:1 dark), so mesh fills always carry a dark ink.
    static let onMesh = Color.popopx(light: 0x00251F, dark: 0x00211C)

    // MARK: Danger - clearing records / PanicWipeManager

    /// Icons, borders, swipe-action backgrounds. Not body text in light mode:
    /// `#FF3B30` on white is 3.55:1.
    static let danger = Color.popopx(light: 0xFF3B30, dark: 0xFF453A)

    /// Destructive text, at AA in both modes (5.38 light / 4.99 dark on a card).
    static let dangerInk = Color.popopx(light: 0xD70015, dark: 0xFF453A)

    /// The destructive CTA fill, always paired with `onDanger`.
    static let dangerFill = Color.popopx(light: 0xD70015, dark: 0xFF453A)

    /// Text on a `dangerFill` surface.
    static let onDanger = Color.popopx(light: 0xFFFFFF, dark: 0x0A0A1F)

    // MARK: Success — transient confirmation only

    /// The fill behind a success flash. Never a glyph on its own: `#34C759` on a
    /// white card is 2.22:1, so this color only ever appears carrying `onSuccess`.
    static let success = Color.popopx(light: 0x34C759, dark: 0x30D158)

    /// Text and glyphs on a `success` fill — a dark green ink, for the same reason
    /// `onMesh` is one (7.46:1 light, 8.94:1 dark).
    static let onSuccess = Color.popopx(light: 0x07240F, dark: 0x071A0C)

    /// Green drawn *on* a surface: a tick, an icon, a hairline. 5.40:1 on a light
    /// card, 8.42:1 on a dark one, and 6.89:1 on the toast's `cardHigh`.
    static let successInk = Color.popopx(light: 0x1E7A34, dark: 0x30D158)

    // MARK: Surfaces

    /// Screen background: `#F2F2F7` under white cards, OLED black under `#1C1C1E`.
    static let base = Color.popopx(light: 0xF2F2F7, dark: 0x000000)

    /// The grouped card, the inbound bubble, the list row.
    static let card = Color.popopx(light: 0xFFFFFF, dark: 0x1C1C1E)

    /// One step above `card`: sheets, the floating input bar, the toast. Dark mode
    /// lifts again to `#2C2C2E` because a `#1C1C1E` sheet on black is invisible.
    static let cardHigh = Color.popopx(light: 0xFFFFFF, dark: 0x2C2C2E)

    /// The hairline divider between rows.
    static let separator = Color.popopx(light: 0xE3E4EA, dark: 0x38383B)

    // MARK: Labels

    static let label = Color.popopx(light: 0x111114, dark: 0xF4F4F6)
    static let labelSecondary = Color.popopx(light: 0x5A5A66, dark: 0xA6A6B0)

    /// Placeholder and disabled text only — 3.42:1 light, 4.13:1 dark, so it is
    /// never the only carrier of readable content.
    static let labelHint = Color.popopx(light: 0x8A8A94, dark: 0x7C7C88)

    /// The 0.5pt highlight inside a dark card's edge (`PopopxMetrics.hairline`);
    /// light mode draws a shadow instead, so this reads as near-clear there.
    static let hairlineInner = Color.popopx(
        light: 0x111114,
        dark: 0xFFFFFF,
        lightOpacity: 0.055,
        darkOpacity: 0.12
    )

    /// The shadow under a light-mode card; `popopxCardElevation` drops it in dark.
    static let cardShadow = Color.popopx(0x111114, opacity: 0.07)
}

// MARK: - Metrics

enum PopopxMetrics {
    /// A 4pt lattice with 8pt as the step a layout should default to.
    static let space2XS: CGFloat = 4
    static let spaceXS: CGFloat = 8
    static let spaceS: CGFloat = 12
    static let spaceM: CGFloat = 16
    static let spaceL: CGFloat = 24
    static let spaceXL: CGFloat = 32
    static let space2XL: CGFloat = 48

    /// Screen gutter: every list card and section inset starts from this.
    static let gutter: CGFloat = spaceM

    static let radiusChip: CGFloat = 8
    static let radiusAvatar: CGFloat = 8
    static let radiusControl: CGFloat = 12
    static let radiusCard: CGFloat = 16
    static let radiusSheet: CGFloat = 20

    /// A bubble keeps `radiusCard` on its outer corners; only the corner nearest
    /// the previous message from the same sender tightens to this.
    static let radiusBubbleTucked: CGFloat = 4

    static let hairline: CGFloat = 0.5
    static let divider: CGFloat = 1
    static let stroke: CGFloat = 1.5

    /// HIG minimum, enforced rather than assumed.
    static let minHitTarget: CGFloat = 44

    /// Width cap of the top bar identity pill: it leaves the share for the status pills and the "+", so even a 375pt narrow screen does not push either end out of the safe area.
    /// 115 was set from the worst case - with the name filling the cap, the top bar row's minimum sum is 391, and 393 leaves 2pt;
    /// the previous 120 tier came to 396, and the negative 3pt was spread over the whole row: that is how a long nickname squeezed the two status pills out of shape
    /// (per-item details in the file head of `Shared/Navigation/PopopxTelemetryHeader.swift`).
    static let headerIdentityMaxWidth: CGFloat = 115
}

// MARK: - Typography

/// Every style is built on a Dynamic Type text style, so a font-size preference or
/// a Watch Pairing display setting moves the whole interface. Readable content
/// never gets a fixed point size.
enum PopopxType {
    static let display = Font.system(.largeTitle).weight(.bold)
    static let title = Font.system(.title2).weight(.semibold)
    static let sectionHeader = Font.system(.headline)
    static let body = Font.system(.body)
    static let emphasis = Font.system(.body).weight(.semibold)
    static let secondary = Font.system(.callout)
    static let meta = Font.system(.subheadline)
    static let caption = Font.system(.footnote)
    static let microTag = Font.system(.caption)

    /// Hop counts, latency, timestamps: tabular figures, so an updating number does
    /// not shift the layout under the user's finger.
    static let metric = Font.system(.footnote).monospacedDigit()
    static let metricSmall = Font.system(.caption2).monospacedDigit()
}

// MARK: - Materials and elevation

enum PopopxMaterial {
    /// The floating input bar and the toast capsule.
    static let bar: Material = .ultraThinMaterial
    /// Header pills sitting over scrolling content.
    static let chip: Material = .thinMaterial
}

extension View {
    /// Light mode: a card reads as raised. Dark mode: the step from `base` to
    /// `card` already reads as raised, and a shadow on OLED black only smears.
    func popopxCardElevation(colorScheme: ColorScheme) -> some View {
        shadow(
            color: colorScheme == .light ? PopopxPalette.cardShadow : .clear,
            radius: colorScheme == .light ? 3 : 0,
            x: 0,
            y: 1
        )
    }
}

// MARK: - Motion

/// `snappy` carries a control reacting to a finger; `fluid` carries something the
/// user did not touch — a pill that changes transport mode, a toast arriving.
enum PopopxSpring {
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0)
    static let fluid = Animation.spring(response: 0.4, dampingFraction: 1.0, blendDuration: 0)

    /// Pointer-down scale for `PopopxPressButtonStyle`.
    static let pressScale: CGFloat = 0.97
}

enum PopopxMotion {
    /// Reduce Motion removes the animation rather than shortening it: a value
    /// change that lands instantly, not a faster spring that still moves.
    static func animation(_ spring: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : spring
    }

    static func withAnimation<V>(_ spring: Animation, reduceMotion: Bool, _ body: () -> V) -> V {
        SwiftUI.withAnimation(reduceMotion ? nil : spring, body)
    }
}

extension View {
    /// `.animation(_:value:)` with the Reduce Motion decision taken at the call
    /// site, where `@Environment(\.accessibilityReduceMotion)` is in scope.
    func popopxAnimation<V: Equatable>(
        _ spring: Animation,
        value: V,
        reduceMotion: Bool
    ) -> some View {
        animation(PopopxMotion.animation(spring, reduceMotion: reduceMotion), value: value)
    }
}

// MARK: - Brand artwork

/// The popopx marks already shipped in `Shared/Assets.xcassets`. These names are
/// the artwork contract: no code in this design system may rename, overwrite or
/// delete the imagesets behind them.
enum PopopxBrandAsset {
    /// Square brand mark (notification icon, identity chip).
    static let mark = "popopx_app_icon"
    /// Horizontal wordmark, for light surfaces.
    static let wordmark = "logo"
    /// Horizontal wordmark, for dark surfaces.
    static let wordmarkDark = "logo-light"
    /// Stacked lockup (onboarding, empty states).
    static let lockup = "vertical_logo"

    static func wordmark(for scheme: ColorScheme) -> String {
        scheme == .light ? wordmark : wordmarkDark
    }
}

#if DEBUG
private struct PopopxSwatch: View {
    let name: String
    let fill: Color
    let ink: Color

    var body: some View {
        Text(name)
            .font(PopopxType.microTag)
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget)
            .background(fill, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
    }
}

private struct PopopxThemeGallery: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                Text(NSLocalizedString("popopx dual-mode palette", comment: "")).font(PopopxType.title)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 108), spacing: PopopxMetrics.spaceS)],
                    spacing: PopopxMetrics.spaceS
                ) {
                    PopopxSwatch(name: "brand", fill: PopopxPalette.brand, ink: PopopxPalette.onBrand)
                    PopopxSwatch(name: "mesh", fill: PopopxPalette.mesh, ink: PopopxPalette.onMesh)
                    PopopxSwatch(name: "dangerFill", fill: PopopxPalette.dangerFill, ink: PopopxPalette.onDanger)
                    PopopxSwatch(name: "label", fill: PopopxPalette.label, ink: PopopxPalette.card)
                    PopopxSwatch(name: "labelSecondary", fill: PopopxPalette.labelSecondary, ink: PopopxPalette.card)
                }

                Text("Typography").font(PopopxType.sectionHeader)
                Text(NSLocalizedString("Offline mesh channel", comment: "")).font(PopopxType.display)
                Text(NSLocalizedString("Offline messages go over the Bluetooth mesh relay, up to 7 hops.", comment: "")).font(PopopxType.body)
                Text("Hop 3 · 128 ms").font(PopopxType.metric).foregroundStyle(PopopxPalette.labelSecondary)

                VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                    Label(NSLocalizedString("SMP online encryption", comment: ""), systemImage: "lock.shield.fill")
                        .foregroundStyle(PopopxPalette.brand)
                    Label(NSLocalizedString("Offline mesh networking", comment: ""), systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(PopopxPalette.meshInk)
                }
                .font(PopopxType.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PopopxMetrics.spaceM)
                .background(
                    PopopxPalette.card,
                    in: .rect(cornerRadius: PopopxMetrics.radiusCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                        .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
                )
                .popopxCardElevation(colorScheme: colorScheme)
            }
            .padding()
        }
        .background(PopopxPalette.base)
    }
}

struct PopopxThemeGallery_Previews: PreviewProvider {
    static var previews: some View {
        PopopxThemeGallery()
    }
}
#endif
