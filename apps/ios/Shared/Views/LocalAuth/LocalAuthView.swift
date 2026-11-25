//
//  LocalAuthView.swift
//  POPOPX (iOS)
//
//  Created by Evgeny on 10/04/2023.
//  Copyright © 2023 SimpleX Chat. All rights reserved.
//  Modifications Copyright © 2026 POPOPX Chat.
//
// Spec: spec/architecture.md

import SwiftUI
import POPOPXChat

struct LocalAuthView: View {
    @EnvironmentObject var m: ChatModel
    var authRequest: LocalAuthRequest
    @State private var password = ""
    @State private var allowToReact = true

    var body: some View {
        PasscodeView(passcode: $password, title: authRequest.title ?? "Enter Passcode", reason: authRequest.reason, submitLabel: "Submit",
                     buttonsEnabled: $allowToReact) {
            if let sdPassword = kcSelfDestructPassword.get(), authRequest.selfDestruct && password == sdPassword {
                allowToReact = false
                deleteStorageAndRestart(sdPassword) { r in
                    m.laRequest = nil
                    authRequest.completed(r)
                }
                return
            }
            let r: LAResult
            if password == authRequest.password {
                if authRequest.selfDestruct && kcSelfDestructPassword.get() != nil && !m.chatInitialized {
                    initChatAndMigrate()
                }
                r = .success
            } else {
                r = .failed(authError: NSLocalizedString("Incorrect passcode", comment: "PIN entry"))
            }
            m.laRequest = nil
            authRequest.completed(r)
        } cancel: {
            m.laRequest = nil
            authRequest.completed(.failed(authError: NSLocalizedString("Authentication cancelled", comment: "PIN entry")))
        }
    }

    private func deleteStorageAndRestart(_ password: String, completed: @escaping (LAResult) -> Void) {
        /**
         * This used to be a hand-written 56-line "close the store → delete the files → clear memory → rebuild" sequence. It was extracted into
         * `PopopxStorageWipe`（Shared/Features/AntiTheftDuress/PopopxDuressAuthManager.swift），
         * because the dual-passphrase duress self-destruct has to do **the same thing**; the price of a copy is that one side alone gets changed later.
         *
         * `displayName` must be read **before** the call: the extracted sequence first clears
         * the two `DEFAULT_LA_SELF_DESTRUCT*` keys and then creates the new user, so reading it only at user-creation time would always give nil,
         * and the owner's preset post-rebuild display name would be silently lost.
         */
        PopopxStorageWipe.run(
            options: PopopxStorageWipe.Options(
                reinstatesAppPasscode: password,
                displayName: UserDefaults.standard.string(forKey: DEFAULT_LA_SELF_DESTRUCT_DISPLAY_NAME),
                disarmsAntiTheft: false,
                afterRebuild: nil
            ),
            completed: completed
        )
    }
}

struct LocalAuthView_Previews: PreviewProvider {
    static var previews: some View {
        LocalAuthView(authRequest: LocalAuthRequest.sample)
    }
}
