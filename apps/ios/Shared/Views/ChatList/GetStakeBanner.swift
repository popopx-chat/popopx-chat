//
//  GetStakeBanner.swift
//  POPOPX (iOS)
//

import SwiftUI
import POPOPXChat

// Spec: spec/client/chat-list.md#GetStakeBanner

// The round is SimpleX Chat Ltd's own campaign, so the URL keeps their spelling; the utm_source is what
// identifies this build to them.
let wefunderURL = URL(string: "https://wefunder.com/simplex.chat?utm_source=app_ios")!

struct GetStakeBanner: View {
    @EnvironmentObject var theme: AppTheme
    var showDismiss: Bool
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Upstream's crowdfunding round")
                            .font(.headline)
                            .foregroundColor(theme.colors.primary)
                            .lineLimit(2)
                        Text("The round is run by SimpleX Chat Ltd - POPOPX receives none of it")
                            .font(.subheadline)
                            .foregroundColor(theme.colors.onBackground)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 6)
                }
                .modifier(BannerCard())
            }
            .buttonStyle(.plain)

            if showDismiss {
                BannerDismissButton(onDismiss: onDismiss)
            }
        }
    }
}

struct GetStakeView: View {
    @Environment(\.dismiss) var dismiss: DismissAction
    var fromSettings: Bool = false

    var body: some View {
        ZoomablePageView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Upstream's crowdfunding on Wefunder")
                    .font(.largeTitle)
                    .bold()
                    .fixedSize(horizontal: false, vertical: true)
                    .if(!fromSettings) { $0.padding(.top) }
                Text("POPOPX Chat is a fork of SimpleX Chat. The investment round at wefunder.com/simplex.chat is run by SimpleX Chat Ltd for their own company: this fork is not part of it, and POPOPX receives none of the money raised.")
                    .multilineTextAlignment(.leading)

                Button {
                    UIApplication.shared.open(wefunderURL)
                } label: {
                    Text("Learn more on Wefunder")
                }
                .buttonStyle(OnboardingButtonStyle())
            }
            .padding()
        }
        .ignoresSafeArea(edges: .bottom)
        .modifier(ThemedBackground(grouped: true))
    }
}

struct GetStakeBanner_Previews: PreviewProvider {
    static var previews: some View {
        GetStakeBanner(showDismiss: true, onTap: {}, onDismiss: {})
            .padding()
    }
}
