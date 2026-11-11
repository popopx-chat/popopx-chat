//
//  CreatePOPOPXAddress.swift
//  POPOPX (iOS)
//
//  Created by spaced4ndy on 28.04.2023.
//  Copyright © 2023 POPOPX Chat. All rights reserved.
//
// Spec: spec/client/navigation.md

import SwiftUI
import Contacts
import ContactsUI
import MessageUI
import POPOPXChat

struct CreatePOPOPXAddress: View {
    @EnvironmentObject var m: ChatModel
    @State private var progressIndicator = false
    @State private var showMailView = false
    @State private var mailViewResult: Result<MFMailComposeResult, Error>? = nil

    var body: some View {
        GeometryReader { g in
            ScrollView {
                ZStack {
                    VStack(alignment: .leading) {
                        Text("POPOPX Address")
                            .font(.largeTitle)
                            .bold()
                            .frame(maxWidth: .infinity)

                        Spacer()

                        if let userAddress = m.userAddress {
                            POPOPXCreatedLinkQRCode(link: userAddress.connLinkContact, short: Binding.constant(false))
                                .frame(maxHeight: g.size.width)
                            shareQRCodeButton(userAddress)
                                .frame(maxWidth: .infinity)

                            if MFMailComposeViewController.canSendMail() {
                                Spacer()
                                
                                shareViaEmailButton(userAddress)
                                    .frame(maxWidth: .infinity)
                            }

                            Spacer()

                            continueButton()
                                .padding(.bottom, 8)
                                .frame(maxWidth: .infinity)
                        } else {
                            createAddressButton()
                                .frame(maxWidth: .infinity)

                            Spacer()

                            skipButton()
                                .padding(.bottom, 56)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(minHeight: g.size.height)

                    if progressIndicator {
                        ProgressView().scaleEffect(2)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .padding()
    }

    private func createAddressButton() -> some View {
        VStack(spacing: 8) {
            Button {
                progressIndicator = true
                Task {
                    do {
                        if let connLinkContact = try await apiCreateUserAddress() {
                            DispatchQueue.main.async {
                                m.userAddress = UserContactLink(connLinkContact)
                            }
                        }
                        await MainActor.run { progressIndicator = false }
                    } catch let error {
                        logger.error("CreatePOPOPXAddress create address: \(responseError(error))")
                        await MainActor.run {
                            progressIndicator = false
                            showErrorAlert(error, NSLocalizedString("Error creating address", comment: ""))
                        }
                    }
                }
            } label: {
                Text("Create POPOPX address").font(.title)
            }
            Text("You can make it visible to your POPOPX contacts via Settings.")
                .multilineTextAlignment(.center)
                .font(.footnote)
                .padding(.horizontal, 32)
        }
    }

    private func skipButton() -> some View {
        VStack(spacing: 8) {
            Button {
                withAnimation {
                    onboardingStageDefault.set(.step4_SetNotificationsMode)
                    m.onboardingStage = .step4_SetNotificationsMode
                }
            } label: {
                HStack {
                    Text("Don't create address")
                    Image(systemName: "chevron.right")
                }
            }
            Text("You can create it later").font(.footnote)
        }
    }

    private func shareQRCodeButton(_ userAddress: UserContactLink) -> some View {
        Button {
            showShareSheet(items: [popopxChatLink(userAddress.connLinkContact.popopxChatUri(short: false))])
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private func shareViaEmailButton(_ userAddress: UserContactLink) -> some View {
        Button {
            showMailView = true
        } label: {
            Label("Invite friends", systemImage: "envelope")
                .font(.title2)
        }
        .sheet(isPresented: $showMailView) {
            SendAddressMailView(
                showMailView: $showMailView,
                mailViewResult: $mailViewResult,
                userAddress: userAddress
            )
            .edgesIgnoringSafeArea(.bottom)
        }
        .onChange(of: mailViewResult == nil) { _ in
            if let r = mailViewResult {
                switch r {
                case let .success(composeResult):
                    switch composeResult {
                    case .sent:
                        onboardingStageDefault.set(.step4_SetNotificationsMode)
                        m.onboardingStage = .step4_SetNotificationsMode
                    default: ()
                    }
                case let .failure(error):
                    logger.error("CreatePOPOPXAddress share via email: \(responseError(error))")
                    showErrorAlert(error, NSLocalizedString("Error sending email", comment: ""))
                }
                mailViewResult = nil
            }
        }
    }

    private func continueButton() -> some View {
        Button {
            withAnimation {
                onboardingStageDefault.set(.step4_SetNotificationsMode)
                m.onboardingStage = .step4_SetNotificationsMode
            }
        } label: {
            HStack {
                Text("Continue")
                Image(systemName: "greaterthan")
            }
        }
    }
}

struct SendAddressMailView: View {
    @Binding var showMailView: Bool
    @Binding var mailViewResult: Result<MFMailComposeResult, Error>?
    var userAddress: UserContactLink

    var body: some View {
        let messageBody = String(format: NSLocalizedString("""
            <p>Hi!</p>
            <p><a href="%@">Connect to me via POPOPX Chat</a></p>
            """, comment: "email text"), popopxChatLink(userAddress.connLinkContact.popopxChatUri(short: false)))
        MailView(
            isShowing: self.$showMailView,
            result: $mailViewResult,
            subject: NSLocalizedString("Let's talk in POPOPX Chat", comment: "email subject"),
            messageBody: messageBody
        )
    }
}

struct CreatePOPOPXAddress_Previews: PreviewProvider {
    static var previews: some View {
        CreatePOPOPXAddress()
    }
}
