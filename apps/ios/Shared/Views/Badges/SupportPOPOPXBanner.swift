//
//  SupportPOPOPXBanner.swift
//  POPOPX (iOS)
//
//  Created by spaced4ndy on 28.07.2026.
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//

import SwiftUI
import POPOPXChat

struct SupportPOPOPXBanner: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.colorScheme) var colorScheme: ColorScheme
    var title: LocalizedStringKey = "Support POPOPX"
    var subtitle: LocalizedStringKey = "Get badge + better files"
    var warning: Bool = false
    var showDismiss: Bool = true
    let onTap: () -> Void
    let onDismiss: () -> Void

    // the card's own height, for centring the fallback hero; hero stays fixed so its above-card
    // overhang shrinks at very large fonts
    @ScaledMetric(relativeTo: .body) private var scaledCardHeight: CGFloat = 72
    private var cardHeight: CGFloat { max(72, scaledCardHeight) }
    private let heroWidth: CGFloat = 110
    // shorter than the natural drawn height so .clipped() slices the phone body at card bottom
    private let heroVisibleHeight: CGFloat = 108
    // hero right edge sits exactly at the dismiss X's left edge (X trailing 16 + width 12)
    private let heroTrailingPadding: CGFloat = 28
    private let textToHeroGap: CGFloat = 6

    var body: some View {
        // Card is the Button; hero is an overlay so it can extend above the card top without
        // affecting layout size. Dismiss X is a ZStack sibling anchored to the card's top-right.
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                            .foregroundColor(warning ? .red : theme.colors.primary)
                            .lineLimit(2)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundColor(theme.colors.onBackground)
                            .lineLimit(2)
                    }
                    Spacer(minLength: heroWidth + heroTrailingPadding + textToHeroGap)
                }
                .modifier(BannerCard())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottomTrailing) {
                heroThumbnail()
                    .padding(.trailing, heroTrailingPadding)
                    .allowsHitTesting(false)
            }

            if showDismiss {
                BannerDismissButton(onDismiss: onDismiss)
            }
        }
    }

    @ViewBuilder
    private func heroThumbnail() -> some View {
        #if POPOPX_ASSETS || SIMPLEX_ASSETS
        // draws at natural aspect, top-aligned in a shorter slot; .clipped() cuts the overflow at card bottom
        Image(colorScheme == .light ? "phone-supporter" : "phone-supporter-light")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: heroWidth, height: heroVisibleHeight, alignment: .top)
            .clipped()
        #else
        Image("badge-supporter")
            .resizable()
            .scaledToFit()
            .frame(width: 48, height: 48)
            .padding(.vertical, (cardHeight - 48) / 2)
            .padding(.trailing, 12)
        #endif
    }
}

struct SupportPOPOPXBanner_Previews: PreviewProvider {
    static var previews: some View {
        SupportPOPOPXBanner(onTap: {}, onDismiss: {})
            .padding()
    }
}

// Banner chrome for the chat-list banners (`SupportPOPOPXBanner`, `GetStakeBanner`); one declaration so the cards cannot drift apart.
struct BannerCard: ViewModifier {
    @Environment(\.colorScheme) var colorScheme: ColorScheme

    // grows with Dynamic Type but never shrinks below the default, so small-font users see the same card
    @ScaledMetric(relativeTo: .body) private var scaledCardHeight: CGFloat = 72
    private var cardHeight: CGFloat { max(72, scaledCardHeight) }

    func body(content: Content) -> some View {
        content
            // the leading padding matches OneHandUICard's segment icon, so the text aligns with it in the list
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 12)
            .frame(minHeight: cardHeight)
            .background(gradientBackground())
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func gradientBackground() -> some View {
        // Asymmetric scale: start (dark end) pushed further below the card than the end (warm) is
        // above, so the card's middle lands at the bright/mid-transition stop instead of the dark
        // navy region. Keeps the small warm accent at top-right.
        GeometryReader { geo in
            let aspect = max(geo.size.height, 1) / max(geo.size.width, 1)
            let startScale: CGFloat = colorScheme == .light ? 2.5 : 3.0
            let endScale: CGFloat = colorScheme == .light ? 1.7 : 2.1
            let gp = OnboardingCardView.gradientPoints(aspectRatio: aspect, scale: 1.0)
            let start = UnitPoint(x: 0.5 + (gp.start.x - 0.5) * startScale, y: 0.5 + (gp.start.y - 0.5) * startScale)
            let end = UnitPoint(x: 0.5 + (gp.end.x - 0.5) * endScale, y: 0.5 + (gp.end.y - 0.5) * endScale)
            return LinearGradient(
                stops: colorScheme == .light ? OnboardingCardView.lightStops : OnboardingCardView.darkStops,
                startPoint: start,
                endPoint: end
            )
        }
    }
}

struct BannerDismissButton: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.colorScheme) var colorScheme: ColorScheme
    let onDismiss: () -> Void

    var body: some View {
        Image(systemName: "multiply")
            .foregroundColor(colorScheme == .dark ? theme.colors.onBackground : theme.colors.secondary)
            .frame(width: 12, height: 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .padding(.trailing, 16)
            .padding(.leading, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
    }
}
