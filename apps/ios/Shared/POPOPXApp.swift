//
//  POPOPXApp.swift
//  Shared
//
//  Created by Evgeny Poberezkin on 17/01/2022.
//
// Spec: spec/architecture.md

import SwiftUI
import OSLog
import POPOPXChat

let logger = Logger()

@main
// Spec: spec/architecture.md#POPOPXApp
struct POPOPXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var chatModel = ChatModel.shared
    @ObservedObject var alertManager = AlertManager.shared

    @Environment(\.scenePhase) var scenePhase
    @State private var enteredBackgroundAuthenticated: TimeInterval? = nil

    init() {
        DispatchQueue.global(qos: .background).sync {
            haskell_init()
//            hs_init(0, nil)
        }
        UserDefaults.standard.register(defaults: appDefaults)
        setGroupDefaults()
        registerGroupDefaults()
        setDbContainer()
        BGManager.shared.register()
        NtfManager.shared.registerCategories()
        installSecureEphemeralHost()
        installAntiTheftDuress()
        installCommerceRuntime()
        // Anti-debug only really performs `PT_DENY_ATTACH` in Release; under Debug this line only sets a flag
        // (`PopopxAntiDebug.swift:41`), otherwise Xcode cannot attach and the whole feature could not be verified during development.
        PopopxAntiDebug.enableProtection()
    }

    /// The two resident machines of the credits ecosystem: the badge state machine and the credits ledger.
    ///
    /// Why it is installed in `init()` rather than in some view's `.task`: each `start()` does three things that cannot be done
    /// only after the user opens the panel - taking over StoreKit delivery (unsettled transactions are pushed at launch), starting the time heartbeat, and reconciling with Apple entitlements
    /// (`PopopxBadgeManager.swift:76-84` / `PopopxCreditsManager.swift:79-86`). Installing late does not crash,
    /// but during that delay nobody comes to credit the points that were bought.
    ///
    /// Neither of the two `Task`s may `await`: `App.init()` is on the main actor, and waiting for them would stall the launch screen on a Keychain read.
    /// Both places are idempotent (`guard deliveryToken == nil`), so a repeated call amounts to nothing happening.
    /// StoreKit's transaction observer is installed along the way by the `PopopxBadgeManager.start()` step, so it is not called a second time here.
    private func installCommerceRuntime() {
        Task { await PopopxBadgeManager.shared.start() }
        Task { await PopopxCreditsManager.shared.start() }
    }

    /// The two host-side hooks of top-secret view-once: physically deleting this device's record, and sending the destruction receipt back to the other side.
    ///
    /// Why it is installed in `init()` rather than in some view's `.task`: `PopopxSecureWindowManager` is fail-closed
    /// (with empty hooks it refuses to open the window outright), so the assembly must come before any card appears, or the user runs into
    /// that "the card is there, tapping does nothing" case. `App.init()` itself is on the main actor (SwiftUI's `App` protocol is `@MainActor`),
    /// so that `@MainActor` singleton can be called directly here.
    ///
    /// `target.chatId` is only used to look up the live chat (`ChatModel.getChat(_:)`, ChatModel.swift:548),
    /// and what is passed in is `ChatInfo.id` exactly as it is; these two values are not assembled a second time here (see `PopopxSecureChatTarget` for the reason).
    /// When the lookup finds nothing, log one error only: better that this one row fails to delete than using a guessed key to delete someone else's row.
    private func installSecureEphemeralHost() {
        PopopxSecureWindowManager.shared.install(
            host: PopopxSecureHostHooks(
                deleteItem: { target in
                    guard let itemId = target.itemId else { return }
                    // The whole section runs on the main actor: `getChat` reads `ChatModel.chats`,
                    // and reading it on another thread is racing the UI over an array with no lock. The two awaits only yield, they do not occupy the main thread.
                    Task { @MainActor in
                        guard let chat = ChatModel.shared.getChat(target.chatId) else {
                            logger.error("secure burn: chat not found for \(target.chatId)")
                            return
                        }
                        do {
                            // `.cidmInternal` = delete only this device's copy, do not broadcast the deletion to the other side. The other side's path to knowing
                            // is only the receipt text below: a sentence saying "I finished reading it and destroyed it", not a protocol event.
                            let deletions = try await apiDeleteChatItems(
                                type: chat.chatInfo.chatType,
                                id: chat.chatInfo.apiId,
                                scope: chat.chatInfo.groupChatScope(),
                                itemIds: [itemId],
                                mode: .cidmInternal
                            )
                            let model = ChatModel.shared
                            for deletion in deletions {
                                if let toItem = deletion.toChatItem {
                                    _ = model.upsertChatItem(chat.chatInfo, toItem.chatItem)
                                } else {
                                    model.removeChatItem(chat.chatInfo, deletion.deletedChatItem.chatItem)
                                }
                                model.updateChatInfo(deletion.deletedChatItem.chatInfo)
                            }
                        } catch {
                            // This log line is the acceptance measure: every occurrence of "read but not deleted" is counted by it.
                            logger.error("secure burn: apiDeleteChatItems failed \(responseError(error))")
                        }
                    }
                },
                sendReceipt: { text, target in
                    Task { @MainActor in
                        guard let chat = ChatModel.shared.getChat(target.chatId) else {
                            logger.error("secure receipt: chat not found for \(target.chatId)")
                            return
                        }
                        // The receipt is **an ordinary plaintext message**: what it states is the fact "that top-secret message has been destroyed",
                        // and it carries no body text itself, so it needs no second payload wrap and the other side always receives it.
                        guard let items = await apiSendMessages(
                            type: chat.chatInfo.chatType,
                            id: chat.chatInfo.apiId,
                            scope: chat.chatInfo.groupChatScope(),
                            sendAsGroup: chat.chatInfo.sendAsGroup,
                            live: false,
                            ttl: nil,
                            sign: false,
                            composedMessages: [ComposedMessage(msgContent: .text(text))]
                        ) else {
                            logger.error("secure receipt: apiSendMessages returned nil")
                            return
                        }
                        let model = ChatModel.shared
                        for item in items { model.addChatItem(chat.chatInfo, item) }
                    }
                }
            )
        )
    }

    /// Host-side assembly for the anti-theft and dual-password modules.
    ///
    /// `enabled` defaults to false (fail-closed: never switched on in the settings page, so no 20Hz sampling), and `sync()` is idempotent,
    /// so calling it again after the settings switch is flipped will not start it twice. This does only that one thing here:
    /// the Keychain probe (`refreshConfiguration()`) is one synchronous `SecItemCopyMatching`,
    /// so it is not put on the cold-start critical path; the root view's `.task` takes it after the first frame instead.
    private func installAntiTheftDuress() {
        PopopxAntiTheftMotionGuard.shared.sync()
        PopopxBehaviorGuard.shared.sync()
    }

    var body: some Scene {
        WindowGroup {
            // contentAccessAuthenticationExtended has to be passed to ContentView on view initialization,
            // so that it's computed by the time view renders, and not on event after rendering
            ContentView(contentAccessAuthenticationExtended: !authenticationExpired())
                .environmentObject(chatModel)
                .environmentObject(AppTheme.shared)
                // Stage-two app-side mounting: the two offline-mesh mounts. Both lines only affect the modifiers the app itself added, and with the kill switch off
                // `PopopxMeshPanicWipeMount`'s overlay puts nothing in it (not even the 44pt corner is a hit area),
                // and `bootstrap()` does not build any Bluetooth object either - see the end of Shared/Model/POPOPXAPI.swift.
                .modifier(PopopxMeshPanicWipeMount())
                .task {
                    await PopopxMeshRuntime.shared.bootstrap()
                    // The touch heartbeat: supplies real interaction timestamps for "how long without movement before locking". The window handle is stored by SceneDelegate
                    // in willConnectTo (AppDelegate.swift:145), and `.task` comes after the first frame,
                    // so by then it must be ready; failing to mount only means the idle timer stops being refreshed, it never locks the wrong person.
                    PopopxTouchBeat.install(in: SceneDelegate.windowStatic)
                    PopopxDuressAuthManager.shared.refreshConfiguration()
                }
                .onOpenURL { url in
                    // an app link can carry a secret, such as a badge code that anyone who reads it can redeem
                    logger.debug("ContentView.onOpenURL: \(isAppLink(url) ? "app link" : url.absoluteString)")
                    if AppChatState.shared.value == .active {
                        chatModel.appOpenUrl = url
                    } else {
                        chatModel.appOpenUrlLater = url
                    }
                }
                .onAppear() {
                    // Present screen for continue migration if it wasn't finished yet
                    if chatModel.migrationState != nil {
                        // It's important, otherwise, user may be locked in undefined state
                        onboardingStageDefault.set(.step1_POPOPXInfo)
                        chatModel.onboardingStage = onboardingStageDefault.get()
                    } else if kcAppPassword.get() == nil || kcSelfDestructPassword.get() == nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            initChatAndMigrate()
                        }
                    }
                }
// Spec: spec/architecture.md#scenePhaseHandling
                .onChange(of: scenePhase) { oldPhase, phase in
                    logger.debug("scenePhase was \(String(describing: oldPhase), privacy: .public), now \(String(describing: phase), privacy: .public)")
                    AppSheetState.shared.scenePhaseActive = phase == .active
                    switch (phase) {
                    case .background:
                        // --- authentication
                        // see ContentView .onChange(of: scenePhase) for remaining authentication logic
                        if chatModel.contentViewAccessAuthenticated {
                            enteredBackgroundAuthenticated = ProcessInfo.processInfo.systemUptime
                        }
                        chatModel.contentViewAccessAuthenticated = false
                        // authentication ---

                        if CallController.useCallKit() && chatModel.activeCall != nil {
                            CallController.shared.shouldSuspendChat = true
                        } else {
                            suspendChat()
                            BGManager.shared.schedule()
                        }
                        NtfManager.shared.setNtfBadgeCount(chatModel.totalUnreadCountForAllUsers())
                    case .active:
                        CallController.shared.shouldSuspendChat = false
                        let appState = AppChatState.shared.value

                        if appState != .stopped {
                            startChatAndActivate {
                                if chatModel.chatRunning == true {
                                    if let ntfResponse = chatModel.notificationResponse {
                                        chatModel.notificationResponse = nil
                                        NtfManager.shared.processNotificationResponse(ntfResponse)
                                    }
                                    if appState.inactive {
                                        Task {
                                            await updateChats()
                                            if !chatModel.showCallView && !CallController.shared.hasActiveCalls() {
                                                await updateCallInvitations()
                                            }
                                            // Legacy upstream badge purchase presentation removed — self-developed PopopxStoreKitManager has a resident Transaction.updates listener (PopopxBadgeManager init).
                                            if let url = chatModel.appOpenUrlLater {
                                                await MainActor.run {
                                                    chatModel.appOpenUrlLater = nil
                                                    chatModel.appOpenUrl = url
                                                }
                                            }
                                        }
                                    } else if let url = chatModel.appOpenUrlLater {
                                        chatModel.appOpenUrlLater = nil
                                        chatModel.appOpenUrl = url
                                    }
                                }
                            }
                        }
                    default:
                        break
                    }
                }
                // The anti-theft shield: it must be the **last** modifier on this content chain, or it cannot cover all the business pages above it.
                // It may only be mounted unconditionally; do not wrap another `if lock.coversContent` outside the host:
                // `submit(pin:)` goes beginDuressFlow → wipe → endDuressFlow → unlock() → time top-up, in that order,
                // and `unlock()` lands **before** the top-up, so the host's `if` layer would, with at most 1.2 seconds of self-destruction left, take the shield
                // and its whole `@State` out of the hierarchy - that one moment of "the picture suddenly changed" is exactly the exposure the entire silent path avoids.
                // The shield itself is an empty `ZStack` when unlocked (zero hit area, zero animation), so the steady-state cost equals not mounting it.
                // The invalidation scope is not here either: `PopopxAppLockOverlayView` is itself a view, so it is the invalidation boundary,
                // and the App's body does not read the lock state, so raising the lock never re-runs that `!authenticationExpired()` above.
                .popopxAppLockOverlay()
        }
    }

    private func setDbContainer() {
// Uncomment and run once to open DB in app documents folder:
//         dbContainerGroupDefault.set(.documents)
//         v3DBMigrationDefault.set(.offer)
// to create database in app documents folder also uncomment:
//         let legacyDatabase = true
        let legacyDatabase = hasLegacyDatabase()
        if legacyDatabase, case .documents = dbContainerGroupDefault.get() {
            dbContainerGroupDefault.set(.documents)
            setMigrationState(.offer)
            logger.debug("POPOPXApp init: using legacy DB in documents folder: \(getAppDatabasePath())*.db")
        } else {
            dbContainerGroupDefault.set(.group)
            setMigrationState(.ready)
            logger.debug("POPOPXApp init: using DB in app group container: \(getAppDatabasePath())*.db")
            logger.debug("POPOPXApp init: legacy DB\(legacyDatabase ? "" : " not") present")
        }
    }

    private func setMigrationState(_ state: V3DBMigrationState) {
        if case .migrated = v3DBMigrationDefault.get() { return }
        v3DBMigrationDefault.set(state)
    }

    private func authenticationExpired() -> Bool {
        if let enteredBackgroundAuthenticated = enteredBackgroundAuthenticated {
            let delay = Double(UserDefaults.standard.integer(forKey: DEFAULT_LA_LOCK_DELAY))
            return ProcessInfo.processInfo.systemUptime - enteredBackgroundAuthenticated >= delay
        } else {
            return true
        }
    }

    private func updateChats() async {
        do {
            let chats = try await apiGetChatsAsync()
            await MainActor.run { chatModel.updateChats(chats) }
            if let id = chatModel.chatId,
               let chat = chatModel.getChat(id),
               !NtfManager.shared.navigatingToChat {
                Task { await loadChat(chat: chat, im: ItemsModel.shared, clearItems: false) }
            }
            if let ncr = chatModel.ntfContactRequest {
                await MainActor.run { chatModel.ntfContactRequest = nil }
                if case let .contactRequest(contactRequest) = chatModel.getChat(ncr.chatId)?.chatInfo {
                    Task { await acceptContactRequest(incognito: false, contactRequestId: contactRequest.apiId) }
                }
            }
        } catch let error {
            logger.error("apiGetChats: cannot update chats \(responseError(error))")
        }
    }

    private func updateCallInvitations() async {
        do {
            try await refreshCallInvitations()
        } catch let error {
            logger.error("apiGetCallInvitations: cannot update call invitations \(responseError(error))")
        }
    }
}
