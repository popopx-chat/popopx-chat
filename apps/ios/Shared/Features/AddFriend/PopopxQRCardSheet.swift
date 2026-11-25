//
//  PopopxQRCardSheet.swift
//  POPOPX (iOS)
//
//  My encrypted card — the one-time encrypted-connection QR card, opened from the
//  Add friend page and from the top-bar `+` menu.
//
//  A Wallet-style "physical object" pass: it is the one surface where the brand
//  spec allows a gradient (Docs/popopx-brand-spec.md §2.4), so the fill is built
//  only from `PopopxPalette.brand` and a dimmed stop of that same brand — never a
//  purple→blue wash. One opt-in exception exists: the purchased cosmetic
//  `PopopxCosmetic.darkGoldQRCardSkin` replaces the *hue* of that same single-hue
//  ramp with a dark-gold one (`Pass.darkGoldBase`). The three stop locations, the
//  three alphas, the `label` underlay and the `onBrand` ink are all untouched, so
//  the ramp is still one brand colour fading into itself — §2.4's ban on a two-hue
//  wash is not relaxed, only its hue is. No skin ever touches the purple logo
//  mark, and the ownership flag is read only here: the QR payload is identical
//  either way, which is what "device-side colours, never uploaded" means in code.
//  Red lines observed: the QR itself is the existing
//  `POPOPXLinkQRCode` (no CIFilter written here), colour/spacing/type/material all
//  come from PopopxTheme (except the two skin hues in `Pass`, documented above), the
//  sheet carries no navigation container of its own and
//  dismissal chrome stays with the host (`presentationDetents`), and every
//  user-facing string is Chinese and lives once in `Copy`.
//

import SwiftUI
import UIKit

struct PopopxQRCardSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var toast = PopopxToastModel()
    /// The one cosmetic the owner may have bought for this surface. Read-only here:
    /// the sheet never spends, never loads a paywall and never explains the price —
    /// that conversation happens in the Compute Credits centre, and a card whose face depends on it
    /// only has to answer "worn or not".
    /// `.task` matters: `owns` reads a Keychain-backed set, and on a cold launch the
    /// sheet can be opened before the ledger has been read. Without the load the
    /// owned skin silently renders as the default brand card.
    @State private var credits = PopopxCreditsManager.shared

    private let uri: String
    private let identityName: String

    init(uri: String, identityName: String) {
        self.uri = uri
        self.identityName = identityName
    }

    var body: some View {
        PopopxSheetContainer(Copy.sheetTitle, subtitle: Copy.sheetSubtitle) {
            closeButton
            passCard
            securityNote
        } footer: {
            actionRow
        }
        .popopxToast(toast)
        .task { credits.loadIfNeeded() }
    }

    // MARK: - Pass

    /// The card body: issuer overline + identity headline on the gradient, the QR
    /// on an inset `card` plate, the link prefix as a tabular caption.
    private var passCard: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(Copy.issuerOverline)
                        .font(PopopxType.microTag)
                        .foregroundStyle(PopopxPalette.onBrand)
                    Text(identityName)
                        .font(PopopxType.title)
                        .foregroundStyle(PopopxPalette.onBrand)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: PopopxMetrics.spaceXS)
                Image(PopopxBrandAsset.mark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                    .clipShape(.rect(cornerRadius: PopopxMetrics.radiusChip, style: .continuous))
                    .accessibilityHidden(true)
            }

            qrPlate
        }
        .padding(PopopxMetrics.spaceL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { passSurface }
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusSheet, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .popopxCardElevation(colorScheme: colorScheme)
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    /// Opaque `passBase` at the leading edge, a dimmed `passBase` at the trailing one
    /// (brand purple by default, dark gold while the owned cosmetic is worn).
    /// The dim stop needs a solid base under it: over the sheet's `cardHigh` it
    /// would wash out to a pale lilac that no `onBrand` ink can clear, so `label`
    /// (near-black in light, near-white in dark) carries it — the tail then deepens
    /// in light mode and brightens in dark mode, and `onBrand` stays above 4.5:1 at
    /// both ends either way.
    private var passSurface: some View {
        ZStack {
            PopopxPalette.label
            Rectangle().fill(passGradient)
        }
        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusSheet, style: .continuous))
    }

    /// The single hue the ramp is built from: brand purple, or dark gold once the
    /// cosmetic is owned. Everything downstream is derived from this one value, so
    /// the skin cannot desynchronise the three stops from each other.
    private var passBase: Color {
        credits.owns(.darkGoldQRCardSkin) ? Pass.darkGoldBase : PopopxPalette.brand
    }

    private var passGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: passBase, location: 0),
                .init(color: passBase.opacity(0.92), location: 0.45),
                .init(color: passBase.opacity(Pass.dimOpacity(for: colorScheme)), location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - QR plate

    /// Scanners read luminance difference, not brand polish: the code always sits on
    /// the `card` surface (white in light mode, the dark card grey in dark mode) so
    /// module-to-plate contrast stays above 4.5:1 in either scheme.
    private var qrPlate: some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            POPOPXLinkQRCode(uri: uri, withLogo: true, tintColor: qrInk)
                .aspectRatio(1, contentMode: .fit)

            Text(linkPreview)
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.qrAccessibilityLabel)
        .accessibilityValue(uri)
    }

    /// The QR tint, in UIKit because the CI renderer samples components off a
    /// `UIColor`. `PopopxPalette.brand` is a two-mode `Color`, so it is resolved
    /// against this sheet's own style rather than whatever traits happen to be
    /// current when the image is generated off the main layout pass.
    ///
    /// The skin's ink is deliberately NOT the gold the card is wearing: a light
    /// 0xD9B24C-style module on the white `card` plate drops module-to-plate contrast
    /// below 4.5:1, which is a scanner failure rather than a taste problem. So the
    /// face may be gold while the code stays dark bronze.
    private var qrInk: UIColor {
        let ink = credits.owns(.darkGoldQRCardSkin) ? Pass.darkGoldQRInk : PopopxPalette.brand
        return UIColor(ink).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        )
    }

    private var linkPreview: String {
        uri.count > Pass.linkPreviewCharacters
            ? String(uri.prefix(Pass.linkPreviewCharacters)) + "…"
            : uri
    }

    // MARK: - Note and actions

    private var securityNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "lock.shield.fill")
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxPalette.brand)
            Text(Copy.securityNote)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    private var closeButton: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Spacer(minLength: PopopxMetrics.spaceXS)
            PopopxButton(Copy.close, systemImage: "xmark", role: .secondary, fullWidth: false) {
                dismiss()
            }
        }
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    private var actionRow: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            PopopxButton(Copy.share, systemImage: "square.and.arrow.up", role: .primary) {
                share()
            }
            PopopxButton(Copy.copy, systemImage: "doc.on.doc", role: .secondary) {
                copyLink()
            }
        }
        .padding(PopopxMetrics.spaceM)
    }

    @MainActor private func share() {
        showShareSheet(items: [uri])
    }

    @MainActor private func copyLink() {
        UIPasteboard.general.string = uri
        toast.show(Copy.copiedToast, kind: .success)
    }
}

/// Geometry the pass needs but the design system does not carry: the gradient's
/// tail opacity, per interface style (see `passSurface`), and how much of the link
/// the caption reveals.
private enum Pass {
    static let linkPreviewCharacters = 28

    /// The dark-gold skin's hue, and its scanner-safe ink. These two literals are the
    /// only colours in the commerce feature that live outside `PopopxPalette`, and
    /// they belong here rather than in the theme: an owned cosmetic is a decoration
    /// one person bought, not a semantic token every page may reach for. Each is read
    /// by exactly one computed property in this file, gated on `credits.owns`.
    static let darkGoldBase = Color.popopx(light: 0xB8912F, dark: 0xD9B24C)
    /// Dark bronze in light (over the white plate), bright gold in dark (over the
    /// dark card grey) — the same direction the brand purple already travels in.
    static let darkGoldQRInk = Color.popopx(light: 0x5C450F, dark: 0xE8CE72)

    /// Light mode fades further, so the tail reads as a deep indigo edge under the
    /// white ink; dark mode fades less, because there the ink is near-black and the
    /// tail has to stay the brighter end.
    static func dimOpacity(for scheme: ColorScheme) -> Double {
        scheme == .light ? 0.55 : 0.70
    }
}

// MARK: - Copy

/// Every user-visible string on the card, Chinese, declared once.
private enum Copy {
    static let sheetTitle = NSLocalizedString("My encrypted card", comment: "")
    static let sheetSubtitle = NSLocalizedString("Show this code — once they scan it, they can start a connection with you", comment: "")
    static let issuerOverline = NSLocalizedString("Anonymous identity", comment: "")
    static let close = NSLocalizedString("Close", comment: "")
    static let share = NSLocalizedString("Share", comment: "")
    static let copy = NSLocalizedString("Copy link", comment: "")
    static let copiedToast = NSLocalizedString("Copied to clipboard", comment: "")
    static let securityNote = NSLocalizedString("This link only sets up a one-time encrypted connection — anyone who gets it can start a connection with you, so do not publish it.", comment: "")
    static let qrAccessibilityLabel = NSLocalizedString("Encrypted card QR code", comment: "")
}

// MARK: - Preview

#if DEBUG
struct PopopxQRCardSheet_Previews: PreviewProvider {
    static var previews: some View {
        PopopxQRCardSheet(
            uri: "https://smp1.popopx.im/a#preview-contact-key",
            identityName: "Ink Courier"
        )
    }
}
#endif
