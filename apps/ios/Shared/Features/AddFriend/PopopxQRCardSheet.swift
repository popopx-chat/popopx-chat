//
//  PopopxQRCardSheet.swift
//  POPOPX (iOS)
//
//  我的加密名片 — the one-time encrypted-connection QR card, opened from the
//  添加朋友 page and from the top-bar `+` menu.
//
//  A Wallet-style "physical object" pass: it is the one surface where the brand
//  spec allows a gradient (Docs/popopx-brand-spec.md §2.4), so the fill is built
//  only from `PopopxPalette.brand` and a dimmed stop of that same brand — never a
//  purple→blue wash. Red lines observed: the QR itself is the existing
//  `POPOPXLinkQRCode` (no CIFilter written here), colour/spacing/type/material all
//  come from PopopxTheme, the sheet carries no navigation container of its own and
//  dismissal chrome stays with the host (`presentationDetents`), and every
//  user-facing string is Chinese and lives once in `Copy`.
//

import SwiftUI
import UIKit

struct PopopxQRCardSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var toast = PopopxToastModel()

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

    /// Opaque `brand` at the leading edge, a dimmed `brand` at the trailing one.
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

    private var passGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: PopopxPalette.brand, location: 0),
                .init(color: PopopxPalette.brand.opacity(0.92), location: 0.45),
                .init(color: PopopxPalette.brand.opacity(Pass.dimOpacity(for: colorScheme)), location: 1)
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
    private var qrInk: UIColor {
        UIColor(PopopxPalette.brand).resolvedColor(
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
    static let sheetTitle = "我的加密名片"
    static let sheetSubtitle = "出示此码，对方扫码即可向你发起连接"
    static let issuerOverline = "匿名身份"
    static let close = "关闭"
    static let share = "分享"
    static let copy = "复制链接"
    static let copiedToast = "已复制到剪贴板"
    static let securityNote = "该链接仅用于建立一次性加密连接，任何人得到它都可以向你发起连接（不要公开传播）。"
    static let qrAccessibilityLabel = "加密名片二维码"
}

// MARK: - Preview

#if DEBUG
struct PopopxQRCardSheet_Previews: PreviewProvider {
    static var previews: some View {
        PopopxQRCardSheet(
            uri: "popopx:/contact#lrdvu2d8A1GumSmoKb2krQmtKhWXq-tyGpHuM7aMwsw",
            identityName: "墨蓝信使"
        )
    }
}
#endif
