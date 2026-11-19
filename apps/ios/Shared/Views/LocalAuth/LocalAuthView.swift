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
         * 这里原本是 56 行手写的"关库 → 删文件 → 清内存 → 重建"序列。它被抽到
         * `PopopxStorageWipe`（Shared/Features/AntiTheftDuress/PopopxDuressAuthManager.swift），
         * 因为双密码胁迫自毁要做的是**同一件事**；复制一份的代价是将来只改了一边。
         *
         * `displayName` 必须在调用**之前**读出来：抽出去的那段序列会先清掉
         * `DEFAULT_LA_SELF_DESTRUCT*` 两个键再建新用户，等到建用户时再读就永远是 nil，
         * 机主预设的重建后显示名会静默丢失。
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
