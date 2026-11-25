//
//  BadgesSupportPopopxView.swift
//  POPOPX (iOS)
//
//  Created by spaced4ndy on 28.07.2026.
//  Copyright © 2026 SimpleX Chat. All rights reserved.
//  Modifications Copyright © 2026 POPOPX Chat.
//

import SwiftUI
import POPOPXChat

struct BadgesSupportPopopxView: View {
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var chatModel: ChatModel
    @ObservedObject private var store = BadgeStore.shared
    // set true when presented as a sheet root (from the chat-list banner) — that path doesn't
    // reserve nav-bar space like a NavigationLink push does, so the title lands too close to the top
    var showsAsSheet: Bool = false
    var servedByAppStore: Bool? = nil
    @State private var whyBuiltActive = false
    @State private var howItWorksActive = false
    @State private var chooseLevelActive = false

    var body: some View {
        GeometryReader { g in
            VStack(alignment: .center, spacing: 16) {
                Text("Support POPOPX")
                    .font(.largeTitle)
                    .bold()
                    .foregroundColor(theme.colors.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Get a badge to send larger files (2-5GB) that stay available longer (7-21 days), and to show it on your profile.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                howItWorksButton()

                Spacer(minLength: 0)

                PhoneSupporterHero()
                    .frame(maxWidth: g.size.width * 0.55)
                    .layoutPriority(-1)

                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    if servedByAppStore ?? store.servedByAppStore {
                        chooseLevelButton()
                            .padding(.vertical, 10)
                        Group {
                            if badgeBrowserAllowed {
                                buyInBrowserButton()
                            }
                        }
                        .frame(height: 22)
                        RestorePurchasesButton()
                            .frame(height: 22)
                            .padding(.top, 10)
                        Text("If you were charged but have no badge, this adds it. A subscription bought with this App Store account moves to this profile, and the device or profile that had it loses its badge at its next renewal.")
                            .font(.footnote)
                            .foregroundColor(theme.colors.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        chooseBadgeOnSiteButton()
                            .padding(.vertical, 10)
                    }
                }
                .padding(.bottom, g.safeAreaInsets.bottom == 0 ? 20 : 0)
            }
            .padding(.horizontal, 25)
            .padding(.top, showsAsSheet ? 48 : 0)
            .padding(.bottom, 20)
            // .frame(height:) not minHeight — inside the banner sheet's NavigationStack minHeight
            // would let the VStack expand past the visible area and inflate the hero.
            .frame(height: g.size.height)
        }
        .frame(maxHeight: .infinity)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.readEnvironment() }
    }

    private func chooseLevelButton() -> some View {
        let disabled = !store.canBuy(chatModel.currentUser?.userId)
        return Button {
            chooseLevelActive = true
        } label: {
            Text("Choose your badge")
        }
        .buttonStyle(OnboardingButtonStyle(isDisabled: disabled))
        .disabled(disabled)
        .navigationDestination(isPresented: $chooseLevelActive) {
            BadgesChooseBadgeView()
                .modifier(ThemedBackground())
        }
    }

    private func whyBuiltButton() -> some View {
        Button { whyBuiltActive = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                Text("Why POPOPX is built.").fontWeight(.medium)
            }
            .font(.body)
        }
        .navigationDestination(isPresented: $whyBuiltActive) {
            WhyPOPOPX(onboarding: false, titleColor: theme.colors.primary, createProfileNavLinkActive: .constant(false))
        }
    }

    private func howItWorksButton() -> some View {
        Button { howItWorksActive = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                Text("How badges protect your privacy").fontWeight(.medium)
            }
            .font(.body)
        }
        .navigationDestination(isPresented: $howItWorksActive) {
            BadgesHowItWorksView()
                .modifier(ThemedBackground())
        }
    }

    private func chooseBadgeOnSiteButton() -> some View {
        Button {
            UIApplication.shared.open(URL(string: badgePageUrl)!)
        } label: {
            Text("Choose your badge")
        }
        .buttonStyle(OnboardingButtonStyle(isDisabled: false))
    }

    private func buyInBrowserButton() -> some View {
        Button {
            UIApplication.shared.open(URL(string: badgePageUrl)!)
        } label: {
            Text("Buy in browser")
                .font(.body)
                .fontWeight(.medium)
                .foregroundColor(theme.colors.primary)
        }
    }
}

struct PhoneSupporterHero: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.colorScheme) var colorScheme: ColorScheme

    var body: some View {
        #if POPOPX_ASSETS || SIMPLEX_ASSETS
        Image(colorScheme == .light ? "phone-supporter" : "phone-supporter-light")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
        #else
        ZStack {
            let gp = OnboardingCardView.gradientPoints(aspectRatio: 1.0, scale: colorScheme == .light ? 1.2 : 1.5)
            LinearGradient(
                stops: colorScheme == .light ? OnboardingCardView.lightStops : OnboardingCardView.darkStops,
                startPoint: gp.start,
                endPoint: gp.end
            )
            Image("badge-supporter")
                .resizable()
                .scaledToFit()
                .frame(width: 96)
        }
        .aspectRatio(1.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .frame(maxWidth: .infinity)
        #endif
    }
}

struct BadgesSupportPopopxView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            BadgesSupportPopopxView(servedByAppStore: true)
        }
    }
}
