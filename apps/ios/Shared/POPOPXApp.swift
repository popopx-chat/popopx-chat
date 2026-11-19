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
        // 反调试只在 Release 里真正 `PT_DENY_ATTACH`；Debug 下这行只置一个标志位
        // （PopopxAntiDebug.swift:41），否则 Xcode 挂不上去，整个特性在开发期就没法验。
        PopopxAntiDebug.enableProtection()
    }

    /// 绝密阅后即焚的宿主侧两只钩子：物理删除本机记录、把销毁回执发回给对方。
    ///
    /// 为什么装在 `init()` 而不是某个视图的 `.task`：`PopopxSecureWindowManager` 是 fail-closed 的
    /// （钩子为空时直接拒开窗口），装配必须排在任何卡片出现之前，否则用户会碰到"卡片在、点了没反应"
    /// 那一格。`App.init()` 本身就在主 actor 上（SwiftUI 的 `App` 协议是 `@MainActor` 的），
    /// 所以这里可以直接调那个 `@MainActor` 单例。
    ///
    /// `target.chatId` 只用来查现网会话（`ChatModel.getChat(_:)`，ChatModel.swift:548），
    /// 传进去的就是 `ChatInfo.id` 原样；这两个值不在这里二次拼装（理由见 `PopopxSecureChatTarget`）。
    /// 查不到就只记一条 error：宁可这一条没删成，也不能拿猜出来的键去删别人的行。
    private func installSecureEphemeralHost() {
        PopopxSecureWindowManager.shared.install(
            host: PopopxSecureHostHooks(
                deleteItem: { target in
                    guard let itemId = target.itemId else { return }
                    // 整段跑在主 actor 上：`getChat` 读的是 `ChatModel.chats`，
                    // 在别的线程读它等于和 UI 抢一份没有锁的数组。两个 await 只是让出，不占主线程。
                    Task { @MainActor in
                        guard let chat = ChatModel.shared.getChat(target.chatId) else {
                            logger.error("secure burn: chat not found for \(target.chatId)")
                            return
                        }
                        do {
                            // `.cidmInternal` = 只删本机这一份，不向对方广播删除。对方的知情路径
                            // 只有下面那条回执文本：一条"我看完了并销毁了"的话，而不是一条协议事件。
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
                            // 这条日志是验收口径："看完但没删掉"的全部发生次数都由它统计。
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
                        // 回执是**普通明文消息**：它说的是"那条绝密已经销毁了"这件事，
                        // 本身不含任何正文，所以不需要再走一次载荷封装，对方也永远收得到。
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

    /// 防盗与双密码模块的宿主侧装配。
    ///
    /// `enabled` 默认 false（fail-closed：没在设置页开过就没有 20Hz 采样），`sync()` 幂等，
    /// 所以设置页拨完开关再调一次也不会重复启动。这里只做这一件事：
    /// Keychain 探测（`refreshConfiguration()`）是一次同步 `SecItemCopyMatching`，
    /// 不排在冷启动关键路径上，改由根视图的 `.task` 在首帧之后取。
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
                // 第二阶段 app 侧挂载：离线网格的两条挂载。两行都只影响 app 自己新加的修饰符，熔断关闭时
                // `PopopxMeshPanicWipeMount` 的 overlay 里什么都不放（连 44pt 的角落都不是命中区），
                // `bootstrap()` 也不会建出任何蓝牙对象 —— 见 Shared/Model/POPOPXAPI.swift 末尾。
                .modifier(PopopxMeshPanicWipeMount())
                .task {
                    await PopopxMeshRuntime.shared.bootstrap()
                    // 触摸节拍：给"多久没动就锁"提供真实交互时间戳。窗口句柄由 SceneDelegate
                    // 在 willConnectTo 里存好（AppDelegate.swift:145），`.task` 排在首帧之后，
                    // 此时它必定已就绪；挂不上也只是不刷新空闲计时，不会锁错人。
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
                    logger.debug("scenePhase was \(String(describing: oldPhase)), now \(String(describing: phase))")
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
                                            Task { await BadgeStore.shared.presentUnfinished() }
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
                // 防盗遮罩：必须是这条内容链上的**最后一条**修饰符，才压得住上面所有业务页。
                // 只能无条件挂，不许在宿主外面再套一层 `if lock.coversContent`：
                // `submit(pin:)` 的顺序是 beginDuressFlow → 擦除 → endDuressFlow → unlock() → 补时，
                // `unlock()` 落在补时**之前**，宿主那一层 `if` 会在自毁还剩最多 1.2 秒时把遮罩连带
                // 它的 `@State` 整个从层级里摘掉——那一下"画面突然变了"正是整条静默路径要避免的暴露。
                // 遮罩自己在未锁时是空 `ZStack`（零命中区、零动画），所以常态开销等于不挂。
                // 失效范围也不在这里：`PopopxAppLockOverlayView` 自己是视图、就是失效边界，
                // App 的 body 不读锁状态，因此拉锁不会重跑上面那个 `!authenticationExpired()`。
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
