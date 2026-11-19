// Spec: spec/client/compose.md

import SwiftUI
import POPOPXChat
import PopopxMeshKit
import SwiftyGif
import PhotosUI

let MAX_NUMBER_OF_MENTIONS = 3

// Spec: spec/client/compose.md#ComposePreview
enum ComposePreview {
    case noPreview
    case linkPreview(linkPreview: LinkPreview?)
    case chatLinkPreview(chatLink: MsgChatLink, ownerSig: LinkOwnerSig?)
    case mediaPreviews(mediaPreviews: [(String, UploadContent?)])
    case voicePreview(recordingFileName: String, duration: Int)
    case filePreview(fileName: String, file: URL)
}

// Spec: spec/client/compose.md#ComposeContextItem
enum ComposeContextItem: Equatable {
    case noContextItem
    case quotedItem(chatItem: ChatItem)
    case editingItem(chatItem: ChatItem)
    case forwardingItems(chatItems: [ChatItem], fromChatInfo: ChatInfo)
    case reportedItem(chatItem: ChatItem, reason: ReportReason)
}

// Spec: spec/client/compose.md#VoiceMessageRecordingState
enum VoiceMessageRecordingState {
    case noRecording
    case recording
    case finished
}

// Spec: spec/client/compose.md#LiveMessage
struct LiveMessage {
    var chatItem: ChatItem
    var typedMsg: String
    var sentMsg: String?
}

typealias MentionedMembers = [String: CIMention]

// Spec: spec/client/compose.md#ComposeState
struct ComposeState {
    var message: String
    var parsedMessage: [FormattedText]
    var liveMessage: LiveMessage? = nil
    var preview: ComposePreview
    var contextItem: ComposeContextItem
    var voiceMessageRecordingState: VoiceMessageRecordingState
    var inProgress = false
    var progressByTimeout = false
    var useLinkPreviews = true
    var mentions: MentionedMembers = [:]

    init(
        message: String = "",
        parsedMessage: [FormattedText] = [],
        liveMessage: LiveMessage? = nil,
        preview: ComposePreview = .noPreview,
        contextItem: ComposeContextItem = .noContextItem,
        voiceMessageRecordingState: VoiceMessageRecordingState = .noRecording,
        mentions: MentionedMembers = [:]
    ) {
        self.message = message
        self.parsedMessage = parsedMessage
        self.liveMessage = liveMessage
        self.preview = preview
        self.contextItem = contextItem
        self.voiceMessageRecordingState = voiceMessageRecordingState
        self.mentions = mentions
    }

    init(editingItem: ChatItem) {
        let text = if case let .chat(t, chatLink, _) = editingItem.content.msgContent {
            stripTextLink(t, chatLink.connLinkStr)
        } else {
            editingItem.content.text
        }
        self.message = text
        self.parsedMessage = editingItem.formattedText ?? FormattedText.plain(text)
        self.preview = chatItemPreview(chatItem: editingItem)
        self.contextItem = .editingItem(chatItem: editingItem)
        if let emc = editingItem.content.msgContent,
           case .voice = emc {
            self.voiceMessageRecordingState = .finished
        } else {
            self.voiceMessageRecordingState = .noRecording
        }
        self.mentions = editingItem.mentions ?? [:]
    }

    init(forwardingItems: [ChatItem], fromChatInfo: ChatInfo) {
        self.message = ""
        self.parsedMessage = []
        self.preview = .noPreview
        self.contextItem = .forwardingItems(chatItems: forwardingItems, fromChatInfo: fromChatInfo)
        self.voiceMessageRecordingState = .noRecording
    }

    func copy(
        message: String? = nil,
        parsedMessage: [FormattedText]? = nil,
        liveMessage: LiveMessage? = nil,
        preview: ComposePreview? = nil,
        contextItem: ComposeContextItem? = nil,
        voiceMessageRecordingState: VoiceMessageRecordingState? = nil,
        mentions: MentionedMembers? = nil
    ) -> ComposeState {
        ComposeState(
            message: message ?? self.message,
            parsedMessage: parsedMessage ?? self.parsedMessage,
            liveMessage: liveMessage ?? self.liveMessage,
            preview: preview ?? self.preview,
            contextItem: contextItem ?? self.contextItem,
            voiceMessageRecordingState: voiceMessageRecordingState ?? self.voiceMessageRecordingState,
            mentions: mentions ?? self.mentions
        )
    }

    func mentionMemberName(_ name: String) -> String {
        var n = 0
        var tryName = name
        while mentions[tryName] != nil {
            n += 1
            tryName = "\(name)_\(n)"
        }
        return tryName
    }

    var memberMentions: [String: Int64] {
        var result: [String: Int64] = [:]
        for ft in parsedMessage {
            if result.count >= MAX_NUMBER_OF_MENTIONS { break }
            if case let .mention(name) = ft.format, let id = mentions[name]?.memberRef?.groupMemberId { result[name] = id }
        }
        return result
    }

    var editing: Bool {
        switch contextItem {
        case .editingItem: return true
        default: return false
        }
    }

    var quoting: Bool {
        switch contextItem {
        case .quotedItem: return true
        default: return false
        }
    }

    var forwarding: Bool {
        switch contextItem {
        case .forwardingItems: return true
        default: return false
        }
    }

    var reporting: Bool {
        switch contextItem {
        case .reportedItem: return true
        default: return false
        }
    }

    var submittingValidReport: Bool {
        switch contextItem {
        case let .reportedItem(_, reason):
            switch reason {
            case .other: return !message.isEmpty
            default: return true
            }
        default: return false
        }
    }

    var sendEnabled: Bool {
        switch preview {
        case let .mediaPreviews(media): return !media.isEmpty
        case .voicePreview: return voiceMessageRecordingState == .finished
        case .chatLinkPreview: return true
        case .filePreview: return true
        default: return !whitespaceOnly || forwarding || liveMessage != nil || submittingValidReport
        }
    }

    var endLiveDisabled: Bool {
        liveMessage != nil && message.isEmpty && noPreview && !quoting
    }

    var linkPreviewAllowed: Bool {
        switch preview {
        case .chatLinkPreview: return false
        case .mediaPreviews: return false
        case .voicePreview: return false
        case .filePreview: return false
        default: return useLinkPreviews
        }
    }

    var linkPreview: LinkPreview? {
        switch preview {
        case let .linkPreview(linkPreview): return linkPreview
        default: return nil
        }
    }

    var voiceMessageRecordingFileName: String? {
        switch preview {
        case let .voicePreview(recordingFileName: recordingFileName, _): return recordingFileName
        default: return nil
        }
    }

    var noPreview: Bool {
        switch preview {
        case .noPreview: return true
        default: return false
        }
    }

    var voicePreview: Bool {
        switch preview {
        case .voicePreview: return true
        default: return false
        }
    }

    var manyMediaPreviews: Bool {
        switch preview {
        case let .mediaPreviews(mediaPreviews): return mediaPreviews.count > 1
        default: return false
        }
    }

    var attachmentDisabled: Bool {
        if editing || forwarding || liveMessage != nil || inProgress || reporting { return true }
        switch preview {
        case .noPreview: return false
        case .linkPreview: return false
        default: return true
        }
    }

    var attachmentPreview: Bool {
        switch preview {
        case .noPreview: false
        case .linkPreview: false
        case .chatLinkPreview: false
        case let .mediaPreviews(mediaPreviews): !mediaPreviews.isEmpty
        case .voicePreview: false
        case .filePreview: true
        }
    }

    var placeholder: String? {
        switch contextItem {
        case let .reportedItem(_, reason):
            return reason.text
        default:
            return nil
        }
    }

    var empty: Bool {
        whitespaceOnly && noPreview
    }

    var whitespaceOnly: Bool {
        message.allSatisfy { $0.isWhitespace }
    }
}

// Spec: spec/client/compose.md#chatItemPreview
func chatItemPreview(chatItem: ChatItem) -> ComposePreview {
    switch chatItem.content.msgContent {
    case .text:
        return .noPreview
    case let .link(_, preview: preview):
        return .linkPreview(linkPreview: preview)
    case let .image(_, image):
        return .mediaPreviews(mediaPreviews: [(image, nil)])
    case let .video(_, image, _):
        return .mediaPreviews(mediaPreviews: [(image, nil)])
    case let .voice(_, duration):
        return .voicePreview(recordingFileName: chatItem.file?.fileName ?? "", duration: duration)
    case .file:
        let fileName = chatItem.file?.fileName ?? ""
        return .filePreview(fileName: fileName, file: getAppFilePath(fileName))
    default:
        return .noPreview
    }
}

// Spec: spec/client/compose.md#UploadContent
enum UploadContent: Equatable {
    case simpleImage(image: UIImage)
    case imageFile(image: UIImage, url: URL)
    case animatedImage(image: UIImage)
    case video(image: UIImage, url: URL, duration: Int)

    var uiImage: UIImage {
        switch self {
        case let .simpleImage(image): return image
        case let .imageFile(image, _): return image
        case let .animatedImage(image): return image
        case let .video(image, _, _): return image
        }
    }

    func imagePreview() async -> String? {
        if case let .imageFile(_, url) = self, let preview = resizeImageFileToStrSize(url, maxDataSize: 14000) {
            return preview
        }
        return await resizeImageToStrSize(uiImage, maxDataSize: 14000)
    }

    static func loadImageFileFromURL(url: URL) -> UploadContent? {
        let content = loadFromURL(url: url)
        guard case let .simpleImage(image)? = content else { return content }
        let tempUrl = URL(fileURLWithPath: generateNewFileName(getTempFilesDirectory().path + "/" + "image", url.pathExtension, fullPath: true))
        do {
            try FileManager.default.copyItem(at: url, to: tempUrl)
        } catch let err {
            logger.error("UploadContent copyItem error: \(err.localizedDescription)")
            return content
        }
        _ = ChatModel.shared.filesToDelete.insert(tempUrl)
        return .imageFile(image: image, url: tempUrl)
    }

    static func loadFromURL(url: URL) -> UploadContent? {
        do {
            let data = try Data(contentsOf: url)
            if let image = UIImage(data: data) {
                try image.setGifFromData(data, levelOfIntegrity: 1.0)
                logger.log("UploadContent: added animated image")
                return .animatedImage(image: image)
            } else { return nil }
        } catch {
            do {
                if let image = try UIImage(data: Data(contentsOf: url)) {
                    logger.log("UploadContent: added simple image")
                    return .simpleImage(image: image)
                }
            } catch {}
        }
        return nil
    }

    static func loadVideoFromURL(url: URL) async -> UploadContent? {
        let asset = AVAsset(url: url)
        if let (image, duration) = await asset.generatePreview() {
            return .video(image: image, url: url, duration: duration)
        }
        return nil
    }
}

// A badge only helps below the largest badge's limit, and not in incognito chats, so outside that
// the alert is informational as before.
func showLargeFileAlert(_ fileSize: Int64, incognito: Bool, senderProfile: LocalProfile?) {
    let title = NSLocalizedString("Large file!", comment: "file alert title")
    let message = largeFileMessage(fileSize, incognito: incognito, badgeIssue: expiredBadgeReason(fileSize, senderProfile))
    if !incognito && fileSize <= MAX_FILE_SIZE_XFTP_LEGEND && noShownBadge() {
        showAlert(title, message: message) { [supportPOPOPXAlertAction, okAlertAction] }
    } else {
        showAlert(title, message: message)
    }
}

// Spec: spec/client/compose.md#ComposeView
struct ComposeView: View {
    @EnvironmentObject var chatModel: ChatModel
    @EnvironmentObject var theme: AppTheme
    @ObservedObject var chat: Chat
    @ObservedObject var im: ItemsModel
    @Binding var composeState: ComposeState
    @Binding var showCommandsMenu: Bool
    @Binding var keyboardVisible: Bool
    @Binding var keyboardHiddenDate: Date
    @Binding var selectedRange: NSRange

    @State var linkUrl: String? = nil
    @State var hasPopopxLink: Bool = false
    @State var prevLinkUrl: String? = nil
    @State var pendingLinkUrl: String? = nil
    @State var cancelledLinks: Set<String> = []

    @Environment(\.colorScheme) private var colorScheme
    @State private var showChooseSource = false
    @State private var showMediaPicker = false
    @State private var showTakePhoto = false
    @State var chosenMedia: [UploadContent] = []
    @State private var showFileImporter = false
    @State private var showLocationPicker = false
    /// 「+」面板里那一格「个人主页」按下后的本次发送确认表单（模式 + 时长只作用于这一次发送）。
    @State private var showProfileSendSheet = false
    // 「+」面板里红包与礼品卡两格的开关。
    //
    // 落点在按下那一刻快照进 `packetDestination` / `giftCardContactId`，而不是让 Sheet 每次刷新时
    // 重新读当前会话：面板里"扣点 → 发可见行 → 发机器行"是三步，中途读到别的会话就会把红包发进
    // 一个没预览过的位置。空的那一格只在 Sheet 收起时出现。
    @State private var showRedPacketSheet = false
    @State private var packetDestination: PopopxPacketDestination?
    @State private var showGiftCardSheet = false
    @State private var giftCardContactId: Int64?

    @State private var audioRecorder: AudioRecorder?
    @State private var voiceMessageRecordingTime: TimeInterval?
    @State private var startingRecording: Bool = false
    // for some reason voice message preview playback occasionally
    // fails to stop on ComposeVoiceView.playbackMode().onDisappear,
    // this is a workaround to fire an explicit event in certain cases
    @State private var stopPlayback: Bool = false

    @UserDefault(DEFAULT_PRIVACY_SAVE_LAST_DRAFT) private var saveLastDraft = true
    @UserDefault(DEFAULT_TOOLBAR_MATERIAL) private var toolbarMaterial = ToolbarMaterial.defaultMaterial
    @AppStorage(GROUP_DEFAULT_INCOGNITO, store: groupDefaults) private var incognitoDefault = false
    @AppStorage(GROUP_DEFAULT_PRIVACY_SANITIZE_LINKS, store: groupDefaults) private var privacySanitizeLinks = false
    @AppStorage(GROUP_DEFAULT_PRIVACY_LINK_PREVIEWS, store: groupDefaults) private var useLinkPreviews = true
    @AppStorage(GROUP_DEFAULT_PRIVACY_LINK_PREVIEWS_SHOW_ALERT, store: groupDefaults) private var linkPreviewsShowAlert = true
    @State private var updatingCompose = false
    @State private var relayListExpanded = false
    @StateObject private var channelRelaysModel = ChannelRelaysModel.shared

    // 【B6】下面三个是 `PopopxInputBar` 挂在会话页底部时新长的宿主状态，全部 private + 带默认值，
    // 所以合成 memberwise init 的入参表一位没动（`ChatView.swift:237`-`:245` 那个唯一调用点照常）。
    /// 阅后即焚的真值在宿主：输入条只读只报（`PopopxInputBar.swift:21`）。旧的 `SendMessageView`
    /// 把它藏在发送键菜单的 `@State` 里（`SendMessageView.swift:48`-`:52`），换皮后必须有地方接。
    @State private var popopxTTLSeconds: Int? = nil
    /// 绝密档的真值同样在宿主，和上面那一格**互不影响**：`ttlSeconds` 管 SMP 侧留多久，
    /// 这一格管明文在对方屏幕上留多久。两格同时非 nil 是合法组合（既走在线阅后即焚、又阅后即焚）。
    /// 也全部 private + 带默认值，理由与上面那三格相同：不动 memberwise init 的入参表。
    @State private var popopxSecureTTLSeconds: Int? = nil
    @FocusState private var popopxComposerFocused: Bool
    /// 和 `SendMessageView.swift:51` 用同一个 UserDefaults 键：提醒只弹一次这件事不该有两份真值。
    @UserDefault(DEFAULT_LIVE_MESSAGE_ALERT_SHOWN) private var liveMessageAlertShown = false

    // Spec: spec/client/compose.md#body
    var body: some View {
        VStack(spacing: 0) {
            Divider()

            if chat.chatInfo.nextConnectPrepared,
               !composeState.inProgress,
               let user = chatModel.currentUser {
                ContextProfilePickerView(
                    chat: chat,
                    selectedUser: user
                )
                Divider()
            }

            let ownerState = ownerRelayState
            let subscriberState = subscriberRelayState
            if let gInfo = chat.chatInfo.groupInfo, gInfo.useRelays,
               ![.memRejected, .memLeft, .memRemoved, .memGroupDeleted].contains(gInfo.membership.memberStatus) {
                if gInfo.membership.memberRole == .owner {
                    if let s = ownerState, s.relays.isEmpty || s.activeCount < s.relays.count {
                        ownerChannelRelayBar(relays: s.relays, activeCount: s.activeCount, failedCount: s.failedCount, removedCount: s.removedCount)
                    }
                } else if let s = subscriberState {
                    let showProgress = !gInfo.nextConnectPrepared || composeState.inProgress
                    let resolvedCount = s.connectedCount + s.removedCount + s.failedCount
                    if s.total == 0 || s.removedCount + s.failedCount > 0 || resolvedCount < s.total {
                        subscriberChannelRelayBar(
                            hostnames: s.hostnames,
                            relayMembers: s.relayMembers,
                            connectedCount: s.connectedCount,
                            removedCount: s.removedCount,
                            failedCount: s.failedCount,
                            total: s.total,
                            showProgress: showProgress
                        )
                    }
                }
            }

            let userCantSendReason = chat.chatInfo.userCantSendReason(allRelaysBroken: (ownerState?.noActiveRelays ?? subscriberState?.noActiveRelays) ?? false)
            let composeEnabled = (
                userCantSendReason == nil ||
                (chat.chatInfo.groupInfo?.nextConnectPrepared ?? false) ||
                (chat.chatInfo.contact?.nextAcceptContactRequest ?? false)
            )
            Group {

                if let groupInfo = chat.chatInfo.groupInfo,
                   case let .groupChatScopeContext(groupScopeInfo) = im.secondaryIMFilter,
                   case let .memberSupport(member) = groupScopeInfo,
                   let member = member,
                   member.memberPending,
                   composeState.contextItem == .noContextItem,
                   composeState.noPreview {
                    ContextPendingMemberActionsView(
                        groupInfo: groupInfo,
                        member: member
                    )
                    Divider()
                }

                if case let .reportedItem(_, reason) = composeState.contextItem {
                    reportReasonView(reason)
                    Divider()
                }
                // preference checks should match checks in forwarding list
                let popopxLinkProhibited = im.secondaryIMFilter == nil && hasPopopxLink && !chat.groupFeatureEnabled(.popopxLinks)
                let fileProhibited = im.secondaryIMFilter == nil && composeState.attachmentPreview && !chat.groupFeatureEnabled(.files)
                let voiceProhibited = composeState.voicePreview && !chat.chatInfo.featureEnabled(.voice)
                let disableSendButton = popopxLinkProhibited || fileProhibited || voiceProhibited
                if popopxLinkProhibited {
                    msgNotAllowedView("POPOPX links not allowed", icon: "link")
                    Divider()
                } else if fileProhibited {
                    msgNotAllowedView("Files and media not allowed", icon: "doc")
                    Divider()
                } else if voiceProhibited {
                    msgNotAllowedView("Voice messages not allowed", icon: "mic")
                    Divider()
                }
                contextItemView()
                switch (composeState.editing, composeState.preview) {
                case (true, .filePreview): EmptyView()
                case (true, .voicePreview): EmptyView() // ? we may allow playback when editing is allowed
                default: previewView()
                }

                let contact = chat.chatInfo.contact

                if chat.chatInfo.groupInfo?.nextConnectPrepared == true {
                    if chat.chatInfo.groupInfo?.businessChat == nil {
                        let isChannel = chat.chatInfo.groupInfo?.useRelays == true
                        connectButtonView(
                            isChannel ? "Join channel" : "Join group",
                            icon: isChannel ? "antenna.radiowaves.left.and.right.circle.fill" : "person.2.fill",
                            connect: connectPreparedGroup
                        )
                    } else {
                        sendContactRequestView(disableSendButton, icon: "briefcase.fill", sendRequest: connectPreparedGroup)
                    }
                } else if contact?.nextSendGrpInv == true {
                    contextSendMessageToConnect("Send direct message to connect")
                    Divider()
                    HStack (alignment: .center) {
                        attachmentAndCommandsButtons().disabled(true)
                        sendMessageView(disableSendButton, sendToConnect: sendMemberContactInvitation)
                    }
                    .padding(.horizontal, 12)
                } else if let contact,
                          contact.nextConnectPrepared == true,
                          let linkType = contact.preparedContact?.uiConnLinkType {
                    switch linkType {
                    case .inv:
                        connectButtonView("Connect", icon: "person.fill.badge.plus", connect: sendConnectPreparedContact)
                    case .con:
                        if contact.isBot {
                            connectButtonView("Connect", icon: "bolt.fill", connect: sendConnectPreparedContact)
                        } else {
                            sendContactRequestView(disableSendButton, icon: "person.fill.badge.plus", sendRequest: sendConnectPreparedContactRequest)
                        }
                    }
                } else if contact?.nextAcceptContactRequest == true, let crId = contact?.contactRequestId {
                    ContextContactRequestActionsView(contactRequestId: crId)
                } else if let ct = contact, ct.nextAcceptContactRequest, let groupDirectInv = ct.groupDirectInv {
                    ContextMemberContactActionsView(contact: ct, groupDirectInv: groupDirectInv)
                } else if popopxBarEligible {
                    // 【B6】底部输入条换皮：引用条（`contextItemView()`）与附件预览条（`previewView()`）
                    // 在上面原样呈现，这一支只替掉最底下那一条。为什么不是全部会话都换，见
                    // `popopxBarEligible` 的注释。
                    popopxComposerBar(disableSendButton: disableSendButton)
                        .padding(.horizontal, 12)
                } else {
                    HStack (alignment: .center) {
                        attachmentAndCommandsButtons()
                        sendMessageView(
                            disableSendButton,
                            placeholder: chat.chatInfo.groupInfo.map { gi in
                                gi.useRelays && gi.membership.memberRole >= .owner && chat.chatInfo.groupChatScope() == nil
                                ? NSLocalizedString("Broadcast", comment: "compose placeholder for channel owner")
                                : nil
                            } ?? nil
                        )
                    }
                    .padding(.horizontal, 12)
                }

            } // Group
            .disabled(!composeEnabled)
            .if(!composeEnabled) { v in
                v.onTapGesture {
                    if let reason = userCantSendReason {
                        AlertManager.shared.showAlertMsg(
                            title: "You can't send messages!",
                            message: reason.alertMessage
                        )
                    }
                }
            }
        }
        .background {
            Color.clear
                .overlay(ToolbarMaterial.material(toolbarMaterial))
                .ignoresSafeArea(.all, edges: .bottom)
        }
        .onChange(of: composeState.message) { _, msg in
            if updatingCompose {
                updatingCompose = false
                return
            }
            var parsedMsg = parsePOPOPXMarkdown(msg)
            if privacySanitizeLinks, let parsed = parsedMsg {
                let r = sanitizeMessage(parsed)
                if let sanitizedPos = r.sanitizedPos {
                    updatingCompose = true
                    composeState = composeState.copy(message: r.message, parsedMessage: r.parsedMsg)
                    if sanitizedPos < selectedRange.location {
                        selectedRange = NSRange(location: sanitizedPos, length: 0)
                    }
                    parsedMsg = r.parsedMsg
                } else {
                    composeState = composeState.copy(parsedMessage: parsedMsg)
                }
            } else {
                composeState = composeState.copy(parsedMessage: parsedMsg ?? FormattedText.plain(msg))
            }
            if composeState.linkPreviewAllowed && useLinkPreviews {
                if !msg.isEmpty {
                    showLinkPreview(parsedMsg)
                } else {
                    resetLinkPreview()
                    hasPopopxLink = false
                    composeState = composeState.copy(preview: .noPreview)
                }
            } else {
                resetLinkPreview()
                hasPopopxLink = !msg.isEmpty && !chat.groupFeatureEnabled(.popopxLinks) && getMessageLinks(parsedMsg).hasPopopxLink
                if composeState.linkPreviewAllowed {
                    composeState = composeState.copy(preview: .noPreview)
                }
            }
        }
        .onChange(of: chat.chatInfo.sendMsgEnabled) { _, sendEnabled in
            if !sendEnabled {
                cancelCurrentVoiceRecording()
                clearCurrentDraft()
                clearState()
            }
        }
        .onChange(of: composeState.inProgress) { _, inProgress in
            if inProgress {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    composeState.progressByTimeout = composeState.inProgress
                }
            } else {
                composeState.progressByTimeout = false
            }
        }
        .confirmationDialog("Attach", isPresented: $showChooseSource, titleVisibility: .visible) {
            Button("Take picture") {
                showTakePhoto = true
            }
            Button("Choose from library") {
                showMediaPicker = true
            }
            if UIPasteboard.general.hasImages {
                Button("Paste image") {
                    UIPasteboard.general.itemProviders.forEach { p in
                        if p.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                            p.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
                                if let url = url, let image = UploadContent.loadFromURL(url: url) {
                                    chosenMedia.append(image)
                                }
                            }
                        }
                    }
                }
            }
            Button("Choose file") {
                showFileImporter = true
            }
        }
        .fullScreenCover(isPresented: $showTakePhoto) {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                CameraImageListPicker(images: $chosenMedia)
            }
        }
        .sheet(isPresented: $showMediaPicker) {
            LibraryMediaListPicker(addMedia: addMediaContent, selectionLimit: 10, finishedPreprocessing: finishedPreprocessingMediaContent) { itemsSelected in
                await MainActor.run {
                    showMediaPicker = false
                    if itemsSelected {
                        composeState = composeState.copy(preview: .mediaPreviews(mediaPreviews: []))
                    }
                }
            }
        }
        .sheet(isPresented: $showLocationPicker) {
            // 选择器只管选出坐标，发不发、走哪条通道归这里：它连 `chat` 都不知道。
            // 关掉开关由宿主做，`onSend` 里先关再发，避免发送失败时表单还挂在那儿。
            PopopxLocationPickerSheet { payload in
                showLocationPicker = false
                Task { await popopxSendLocation(payload) }
            }
            .presentationDetents([.fraction(0.8)])
        }
        .sheet(isPresented: $showProfileSendSheet) {
            // 表单只决定"这一次怎么发"（模式 + 时长），已保存的主页草稿它一个字都不改；
            // 关开关的时机抄上面那一支：先关再发，发送失败时表单不会还挂在那儿。
            ProfileSendModeSheet { manifest in
                showProfileSendSheet = false
                Task { await popopxSendProfile(manifest) }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showRedPacketSheet, onDismiss: { packetDestination = nil }) {
            // 扣点、发可见行、发机器行三步全在面板里完成（`PopopxSendRedPacketSheet.send()`），
            // 宿主这里只给落点。`if let` 那一层不是装饰： destination 为空时呈现一个空白面板，
            // 用户只会看见一个发不出去红包的页面。
            if let packetDestination {
                PopopxSendRedPacketSheet(destination: packetDestination)
                    .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showGiftCardSheet, onDismiss: { giftCardContactId = nil }) {
            // 铸码、发卡片、发信令也全在面板里（它自己持有 `PopopxSilentSignalingRouter`）。
            // `contactId` 是可选项：面板据此决定"发送给联系人"那颗按钮画不画。
            PopopxGiftBadgeCardSheet(contactId: giftCardContactId)
                .presentationDetents([.large])
        }
        .onChange(of: chosenMedia) { _, selected in
            Task {
                var media: [(String, UploadContent)] = []
                for content in selected {
                    if let img = await content.imagePreview() {
                        media.append((img, content))
                        await MainActor.run {
                            composeState = composeState.copy(preview: .mediaPreviews(mediaPreviews: media))
                        }
                    }
                }
                if media.count == 0 {
                    await MainActor.run {
                        composeState = composeState.copy(preview: .noPreview)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(files) = result, let fileURL = files.first {
                do {
                    var fileSize: Int? = nil
                    if fileURL.startAccessingSecurityScopedResource() {
                        let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                        fileSize = resourceValues.fileSize
                    }
                    fileURL.stopAccessingSecurityScopedResource()
                    if let fileSize = fileSize,
                        fileSize <= maxFileSize {
                        composeState = composeState.copy(preview: .filePreview(fileName: fileURL.lastPathComponent, file: fileURL))
                    } else {
                        showLargeFileAlert(Int64(fileSize ?? 0), incognito: sendIncognito, senderProfile: sendProfile)
                    }
                } catch {
                    logger.error("ComposeView fileImporter error \(error.localizedDescription)")
                }
            }
        }
        .onDisappear {
            if composeState.liveMessage != nil
                && (!composeState.message.isEmpty || composeState.liveMessage?.sentMsg != nil) {
                cancelCurrentVoiceRecording()
                clearCurrentDraft()
                sendMessage(ttl: nil)
                resetLinkPreview()
            } else if (composeState.inProgress) {
                clearCurrentDraft()
            } else if !composeState.empty  {
                if case .recording = composeState.voiceMessageRecordingState {
                    finishVoiceMessageRecording()
                    if let fileName = composeState.voiceMessageRecordingFileName {
                        chatModel.filesToDelete.insert(getAppFilePath(fileName))
                    }
                }
                if saveLastDraft {
                    saveCurrentDraft()
                }
            } else {
                cancelCurrentVoiceRecording()
                clearCurrentDraft()
                clearState()
            }
            chatModel.removeLiveDummy(animated: false)
        }
        .onChange(of: chatModel.stopPreviousRecPlay) { _, _ in
            if !startingRecording {
                if composeState.voiceMessageRecordingState == .recording {
                    finishVoiceMessageRecording()
                }
            } else {
                startingRecording = false
            }
        }
        .onChange(of: chat.chatInfo.featureEnabled(.voice)) { _, vmAllowed in
            if !vmAllowed && composeState.voicePreview,
               let fileName = composeState.voiceMessageRecordingFileName {
                cancelVoiceMessageRecording(fileName)
                clearState()
            }
        }
        .onAppear {
            if case let .voicePreview(_, duration) = composeState.preview {
                voiceMessageRecordingTime = TimeInterval(duration)
            }
        }
    }

    private var ownerRelayState: (relays: [GroupRelay], activeCount: Int, failedCount: Int, removedCount: Int, noActiveRelays: Bool)? {
        guard let gInfo = chat.chatInfo.groupInfo, gInfo.useRelays,
              gInfo.membership.memberRole == .owner,
              ![.memLeft, .memRemoved, .memGroupDeleted].contains(gInfo.membership.memberStatus)
        else { return nil }
        guard channelRelaysModel.groupId == gInfo.groupId else { return nil }
        let relays = channelRelaysModel.groupRelays
        guard !relays.isEmpty else { return ([], 0, 0, 0, true) }
        let relayMembers = relays.map { relay in
            (relay, chatModel.groupMembers.first(where: { $0.wrapped.groupMemberId == relay.groupMemberId })?.wrapped)
        }
        let removedCount = relayMembers.filter { (_, m) in relayMemberRemoved(m?.memberStatus) }.count
        let activeCount = relayMembers.filter { (relay, m) in !relayMemberRemoved(m?.memberStatus) && relay.relayStatus == .active && m?.activeConn?.connFailedErr == nil }.count
        let failedCount = relayMembers.filter { (_, m) in !relayMemberRemoved(m?.memberStatus) && m?.activeConn?.connFailedErr != nil }.count
        let noActiveRelays = activeCount == 0 && (failedCount + removedCount) == relays.count
        return (relays, activeCount, failedCount, removedCount, noActiveRelays)
    }

    private var subscriberRelayState: (hostnames: [String], relayMembers: [GMember], connectedCount: Int, removedCount: Int, failedCount: Int, total: Int, noActiveRelays: Bool)? {
        guard let gInfo = chat.chatInfo.groupInfo, gInfo.useRelays,
              gInfo.membership.memberRole != .owner,
              ![.memRejected, .memLeft, .memRemoved, .memGroupDeleted].contains(gInfo.membership.memberStatus)
        else { return nil }
        let hostnames = (chatModel.channelRelayHostnames[gInfo.groupId] ?? []).sorted()
        let relayMembers = chatModel.groupMembers
            .filter { $0.wrapped.memberRole == .relay && ![.memRemoved, .memGroupDeleted].contains($0.wrapped.memberStatus) }
            .sorted { hostFromRelayLink($0.wrapped.relayLink ?? "") < hostFromRelayLink($1.wrapped.relayLink ?? "") }
        let removedCount = relayMembers.filter { relayMemberRemoved($0.wrapped.memberStatus) }.count
        let connectedCount = relayMembers.filter { !relayMemberRemoved($0.wrapped.memberStatus) && $0.wrapped.activeConn?.connStatus == .ready && $0.wrapped.activeConn?.connFailedErr == nil }.count
        let failedCount = relayMembers.filter { !relayMemberRemoved($0.wrapped.memberStatus) && $0.wrapped.activeConn?.connFailedErr != nil }.count
        let total = relayMembers.count > 0 ? relayMembers.count : hostnames.count
        guard total > 0 || chatModel.membersLoaded else { return nil }
        let noActiveRelays = connectedCount == 0 && (removedCount + failedCount) == total
        return (hostnames, relayMembers, connectedCount, removedCount, failedCount, total, noActiveRelays)
    }

    private var disabledText: LocalizedStringKey? {
        chat.chatInfo.userCantSendReason(allRelaysBroken: (ownerRelayState?.noActiveRelays ?? subscriberRelayState?.noActiveRelays) ?? false)?.composeLabel
    }

    @ViewBuilder private func ownerChannelRelayBar(relays: [GroupRelay], activeCount: Int, failedCount: Int, removedCount: Int) -> some View {
        let total = relays.count
        let allBroken = activeCount == 0 && (failedCount + removedCount) == total
        let sorted = relays.map { relay in
            (relay, chatModel.groupMembers.first(where: { $0.wrapped.groupMemberId == relay.groupMemberId })?.wrapped)
        }.sorted { relayDisplayName($0.0) < relayDisplayName($1.0) }
        VStack(spacing: 0) {
            relayBarHeader {
                if !allBroken && activeCount + failedCount + removedCount < total {
                    RelayProgressIndicator(active: activeCount, total: total)
                }
                if total == 0 {
                    Text("No relays")
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                } else if allBroken {
                    if removedCount == total {
                        Text("All relays removed")
                    } else if failedCount == total {
                        Text("All relays failed")
                    } else {
                        Text("No active relays")
                    }
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                } else if activeCount + failedCount + removedCount >= total {
                    if failedCount > 0 && removedCount > 0 {
                        Text(String.localizedStringWithFormat(NSLocalizedString("%d relays not active", comment: "channel relay bar"), failedCount + removedCount))
                    } else if failedCount > 0 {
                        Text(String.localizedStringWithFormat(NSLocalizedString("%d relays failed", comment: "channel relay bar"), failedCount))
                    } else {
                        Text(String.localizedStringWithFormat(NSLocalizedString("%d relays removed", comment: "channel relay bar"), removedCount))
                    }
                } else if failedCount > 0 && removedCount > 0 {
                    Text(String.localizedStringWithFormat(NSLocalizedString("%d/%d relays active, %d errors", comment: "channel relay bar"), activeCount, total, failedCount + removedCount))
                } else if failedCount > 0 {
                    Text(String.localizedStringWithFormat(NSLocalizedString("%d/%d relays active, %d failed", comment: "channel relay bar"), activeCount, total, failedCount))
                } else if removedCount > 0 {
                    Text(String.localizedStringWithFormat(NSLocalizedString("%d/%d relays active, %d removed", comment: "channel relay bar"), activeCount, total, removedCount))
                } else {
                    Text(String.localizedStringWithFormat(NSLocalizedString("%d/%d relays active", comment: "channel relay bar progress"), activeCount, total))
                }
            }
            if relayListExpanded {
                if allBroken {
                    Text("Add relays to restore message delivery.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.caption)
                        .foregroundColor(theme.colors.secondary)
                        .padding(.leading, 12)
                        .padding(.trailing)
                        .padding(.bottom, 4)
                }
                ForEach(sorted, id: \.0.id) { (relay, m) in
                    if let err = m?.activeConn?.connFailedErr {
                        Button {
                            showAlert(
                                NSLocalizedString("Relay connection failed", comment: "alert title"),
                                message: err
                            )
                        } label: {
                            ownerRelayDetailRow(relay, connFailed: true, memberStatus: m?.memberStatus)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ownerRelayDetailRow(relay, connFailed: false, memberStatus: m?.memberStatus)
                    }
                }
            }
        }
        .padding(.bottom, relayListExpanded ? 4 : 0)
        .animation(nil, value: relayListExpanded)
    }

    private func ownerRelayDetailRow(_ relay: GroupRelay, connFailed: Bool, memberStatus: GroupMemberStatus?) -> some View {
        relayBarDetailRow {
            Text(relayDisplayName(relay)).foregroundColor(theme.colors.secondary)
            Spacer()
            relayStatusIndicator(relay.relayStatus, connFailed: connFailed, memberStatus: memberStatus)
        }
    }

    @ViewBuilder private func subscriberChannelRelayBar(
        hostnames: [String],
        relayMembers: [GMember],
        connectedCount: Int,
        removedCount: Int,
        failedCount: Int,
        total: Int,
        showProgress: Bool
    ) -> some View {
        let errorCount = removedCount + failedCount
        let allBroken = connectedCount == 0 && errorCount == total
        VStack(spacing: 0) {
            relayBarHeader {
                if total == 0 {
                    Text("No relays")
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                } else if allBroken {
                    if removedCount == total {
                        Text("All relays removed")
                    } else if failedCount == total {
                        Text("All relays failed")
                    } else {
                        Text("No active relays")
                    }
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                } else {
                    if showProgress && connectedCount + errorCount < total {
                        RelayProgressIndicator(active: connectedCount, total: total)
                    }
                    if connectedCount + removedCount + failedCount >= total, removedCount + failedCount > 0 {
                        if failedCount > 0 && removedCount > 0 {
                            Text(String.localizedStringWithFormat(NSLocalizedString("%d relays not active", comment: "channel subscriber relay bar"), failedCount + removedCount))
                        } else if failedCount > 0 {
                            Text(String.localizedStringWithFormat(NSLocalizedString("%d relays failed", comment: "channel subscriber relay bar"), failedCount))
                        } else if removedCount > 0 {
                            Text(String.localizedStringWithFormat(NSLocalizedString("%d relays removed", comment: "channel subscriber relay bar"), removedCount))
                        }
                    } else if failedCount > 0 && removedCount > 0 {
                        Text(String.localizedStringWithFormat(NSLocalizedString("%d/%d relays connected, %d errors", comment: "channel subscriber relay bar"), connectedCount, total, errorCount))
                    } else if failedCount > 0 {
                        Text(String.localizedStringWithFormat(NSLocalizedString("%d/%d relays connected, %d failed", comment: "channel subscriber relay bar"), connectedCount, total, failedCount))
                    } else if removedCount > 0 {
                        Text(String.localizedStringWithFormat(NSLocalizedString("%d/%d relays connected, %d removed", comment: "channel subscriber relay bar"), connectedCount, total, removedCount))
                    } else {
                        Text(String.localizedStringWithFormat(NSLocalizedString("%d/%d relays connected", comment: "channel subscriber relay bar progress"), connectedCount, total))
                    }
                }
            }
            if relayListExpanded {
                if allBroken {
                    Text("Waiting for channel owner to add relays.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.caption)
                        .foregroundColor(theme.colors.secondary)
                        .padding(.leading, 12)
                        .padding(.trailing)
                        .padding(.bottom, 4)
                }
                if relayMembers.isEmpty {
                    ForEach(hostnames, id: \.self) { relay in
                        relayBarDetailRow {
                            Text(String.localizedStringWithFormat(NSLocalizedString("via %@", comment: "relay hostname"), hostFromRelayLink(relay)))
                                .foregroundColor(theme.colors.secondary)
                            Spacer()
                        }
                    }
                } else {
                    ForEach(relayMembers) { member in
                        let m = member.wrapped
                        let host = m.relayLink.map { hostFromRelayLink($0) }
                        let failedErr = m.activeConn?.connFailedErr
                        if let err = failedErr {
                            Button {
                                showAlert(
                                    NSLocalizedString("Relay connection failed", comment: "alert title"),
                                    message: err
                                )
                            } label: {
                                subscriberRelayDetailRow(m, host: host, connFailed: true)
                            }
                            .buttonStyle(.plain)
                        } else {
                            subscriberRelayDetailRow(m, host: host, connFailed: false)
                        }
                    }
                }
            }
        }
        .padding(.bottom, relayListExpanded ? 4 : 0)
        .animation(nil, value: relayListExpanded)
    }

    private func subscriberRelayDetailRow(_ m: GroupMember, host: String?, connFailed: Bool) -> some View {
        relayBarDetailRow {
            Text(String.localizedStringWithFormat(NSLocalizedString("via %@", comment: "relay hostname"), host ?? m.chatViewName))
                .foregroundColor(theme.colors.secondary)
            Spacer()
            let status = relayConnStatus(m)
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
            Text(status.text)
                .foregroundColor(theme.colors.secondary)
            if connFailed {
                Image(systemName: "exclamationmark.circle")
                    .foregroundColor(.accentColor)
            }
        }
    }

    private func relayBarHeader<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Button {
            withAnimation(nil) { relayListExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                content()
                Spacer()
                Image(systemName: relayListExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.colors.secondary)
                    .opacity(0.7)
            }
            .font(.callout)
            .foregroundColor(theme.colors.secondary)
            .padding(.top, 8)
            .padding(.bottom, relayListExpanded ? 4 : 8)
            .padding(.leading, 12)
            .padding(.trailing)
        }
    }

    private func relayBarDetailRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
        }
        .font(.caption)
        .padding(.leading, 12)
        .padding(.trailing)
        .padding(.vertical, 2)
    }


    private func relayMemberRemoved(_ status: GroupMemberStatus?) -> Bool {
        status.map { [.memLeft, .memRemoved, .memGroupDeleted].contains($0) } ?? false
    }

    private func connectButtonView(_ label: LocalizedStringKey, icon: String, connect: @escaping () -> Void) -> some View {
        Button(action: connect) {
            ZStack(alignment: .trailing) {
                Label(label, systemImage: icon)
                    .frame(maxWidth: .infinity)
                if composeState.progressByTimeout && chat.chatInfo.groupInfo?.useRelays != true {
                    ProgressView()
                        .padding()
                }
            }
        }
        .frame(height: 57)
        .disabled(composeState.inProgress)
    }

    private func sendContactRequestView(_ disableSendButton: Bool, icon: String, sendRequest: @escaping () -> Void) -> some View {
        HStack (alignment: .center) {
            sendMessageView(
                disableSendButton,
                placeholder: NSLocalizedString("Add message", comment: "placeholder for sending contact request"),
                sendToConnect: sendRequest
            )
            if composeState.whitespaceOnly {
                Button(action: sendRequest) {
                    HStack {
                        Text("Connect").fontWeight(.medium)
                        Image(systemName: icon)
                    }
                }
                .padding(.horizontal, 8)
                .disabled(composeState.inProgress)
            }
        }
        .padding(.horizontal, 12)
    }

    // Spec: spec/client/compose.md#sendMessageView
    private func sendMessageView(_ disableSendButton: Bool, placeholder: String? = nil, sendToConnect: (() -> Void)? = nil) -> some View {
        ZStack(alignment: .leading) {
            SendMessageView(
                placeholder: disabledText != nil ? nil : placeholder,
                composeState: $composeState,
                selectedRange: $selectedRange,
                sendMessage: { ttl in
                    sendMessage(ttl: ttl)
                    resetLinkPreview()
                },
                sendSignedMessage: {
                    sendMessage(ttl: nil, sign: true)
                    resetLinkPreview()
                },
                sendLiveMessage: chat.chatInfo.chatType != .local ? sendLiveMessage : nil,
                updateLiveMessage: updateLiveMessage,
                cancelLiveMessage: {
                    composeState.liveMessage = nil
                    chatModel.removeLiveDummy()
                },
                sendToConnect: sendToConnect,
                hideSendButton: chat.chatInfo.nextConnect && chat.chatInfo.contact?.nextSendGrpInv != true && composeState.whitespaceOnly,
                voiceMessageAllowed: chat.chatInfo.featureEnabled(.voice),
                disableSendButton: disableSendButton,
                showEnableVoiceMessagesAlert: chat.chatInfo.showEnableVoiceMessagesAlert,
                startVoiceMessageRecording: {
                    Task {
                        await startVoiceMessageRecording()
                    }
                },
                finishVoiceMessageRecording: finishVoiceMessageRecording,
                allowVoiceMessagesToContact: allowVoiceMessagesToContact,
                timedMessageAllowed: chat.chatInfo.featureEnabled(.timedMessages),
                showSign: chat.chatInfo.groupInfo?.useRelays == true,
                onMediaAdded: { media in if !media.isEmpty { chosenMedia = media }},
                keyboardVisible: $keyboardVisible,
                keyboardHiddenDate: $keyboardHiddenDate,
                sendButtonColor: chat.chatInfo.incognito
                ? .indigo.opacity(colorScheme == .dark ? 1 : 0.7)
                : theme.colors.primary
            )
            .disabled(!chat.chatInfo.sendMsgEnabled)

            if let disabledText {
                Text(disabledText)
                    .italic()
                    .foregroundColor(theme.colors.secondary)
                    .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder private func attachmentAndCommandsButtons() -> some View {
        let msg = composeState.message.trimmingCharacters(in: .whitespaces)
        let showAttachment = chat.chatInfo.contact?.profile.peerType != .bot || chat.chatInfo.featureEnabled(.files)
        let showCommands = chat.chatInfo.useCommands && (!showAttachment || msg.isEmpty || msg.starts(with: "/"))
        if showCommands {
            commandsButton()
        }
        if showAttachment {
            attachmentButton()
                .padding(.trailing, 3)
                .if(showCommands) { v in v.padding(.leading, 3) }
        }
    }

    private func commandsButton() -> some View {
        Button {
            showCommandsMenu.toggle()
        } label: {
            Text(verbatim: "//")
                .font(.title3)
                .italic()
                .contentShape(Rectangle())
        }
        .disabled(!chat.chatInfo.sendMsgEnabled || chat.chatInfo.menuCommands.isEmpty)
        .frame(width: 25, height: 25)
        .tint(theme.colors.primary)
        .padding(.bottom, 2)
    }

    @ViewBuilder private func attachmentButton() -> some View {
        let b = Button {
            showChooseSource = true
        } label: {
            Image(systemName: "paperclip")
                .resizable()
        }
            .disabled(composeState.attachmentDisabled || !chat.chatInfo.sendMsgEnabled)
            .frame(width: 25, height: 25)
            .tint(theme.colors.primary)
        if im.secondaryIMFilter == nil,
           !chat.chatInfo.featureEnabled(.files) {
            b.disabled(true).onTapGesture {
                AlertManager.shared.showAlertMsg(
                    title: "Files and media prohibited!",
                    message: chat.chatInfo.groupInfo == nil ? nil : "Only group owners can enable files and media."
                )
            }
        } else {
            b
        }
    }

    // MARK: - 【B6】`PopopxInputBar` 挂载（会话页底部输入条）
    //
    //  口径和 B5 的气泡完全一致：新组件能完整表达的那部分换皮，表达不了的整支留在旧视图树里，
    //  两边共用同一批宿主状态（`composeState`、`chosenMedia`、`audioRecorder`、`showCommandsMenu`）。
    //  旧链路的 `attachmentAndCommandsButtons()` 与 `sendMessageView()` 一位没动，
    //  引用条 `contextItemView()` 和附件预览条 `previewView()` 也原位不动 —— 它们本来就在输入条上方。

    /// 换皮范围三条边界，全部是**功能**边界不是审美边界：
    /// - 只有 active 的 1:1 联系人：厢语路由只认 `.direct` 的 contactId（`PopopxRouteTarget`），
    ///   `PopopxComposerContext` 也要求 active（`Contact.active`）。群 / 频道 / 待接受的联系留旧树。
    /// - 有命令菜单的会话留旧树：命令唯一的入口是旧树里的 `commandsButton()`（"//" 键），
    ///   `CommandsMenuView` 还要靠 `selectedRange` 在光标处插命令，而 `TextField` 不回写光标。
    /// - 群 @提及同理：`GroupMentionsView` 拿 `selectedRange` 做字符串拼接（`insertMention`），
    ///   群留在旧树里这个字段就还是真值。
    /// live 消息的节拍，和 `SendMessageView.swift:13` 的 `liveMsgInterval` 同一个值。
    private static let popopxLiveMsgInterval: UInt64 = 3_000_000_000

    private var popopxBarEligible: Bool {
        chat.chatInfo.contact?.active == true && !chat.chatInfo.useCommands
    }

    /// `ComposeState` → `PopopxComposerContext`。输入条故意不认识 `ComposeState`，
    /// 折算这一步必须由宿主做，九个前提一个都不能漏：漏一个就是"静默丢掉阅后即焚 / 引用 / 附件"那一类事故。
    private var popopxComposerContext: PopopxComposerContext {
        var ctx = PopopxComposerContext.outsideDirectContact
        if case let .direct(contact) = chat.chatInfo, contact.active {
            ctx = .directContact(contact.contactId)
        }
        switch composeState.preview {
        case let .mediaPreviews(media): ctx.hasAttachments = !media.isEmpty
        case .filePreview, .voicePreview: ctx.hasAttachments = true
        case .linkPreview, .chatLinkPreview: ctx.hasLinkPreview = true
        case .noPreview: break
        }
        ctx.carriesContextItem = composeState.contextItem != .noContextItem
        ctx.hasMentions = !composeState.memberMentions.isEmpty
        ctx.isLiveMessage = composeState.liveMessage != nil
        ctx.requiresSignature = chat.chatInfo.groupInfo?.useRelays == true
        return ctx
    }

    /// 亮不亮发送键，条件抄 `SendMessageView.swift:186`-`:192`（旧发送键的 `.disabled`）。
    /// "草稿非空"那一半归输入条自己判（它还要求挂了附件也能发，见 `PopopxComposerRouting.dispatch`）。
    private func popopxSendEnabled(_ disableSendButton: Bool) -> Bool {
        chat.chatInfo.sendMsgEnabled
        && composeState.sendEnabled
        && !composeState.inProgress
        && !(composeState.voicePreview && !chat.chatInfo.featureEnabled(.voice))
        && !composeState.endLiveDisabled
        && !disableSendButton
    }

    /// 刻意做成独立函数而不是就地展开：会话页这一路 `if/else` 已经贴着 Swift 类型检查的
    /// 表达式预算（B5 在 `ChatView` 为此连撞 5 次 `unable to type-check in reasonable time`），
    /// `some View` 不透明返回类型把这一支单独算一份预算。
    @ViewBuilder private func popopxComposerBar(disableSendButton: Bool) -> some View {
        let bar = ZStack(alignment: .leading) {
            PopopxInputBar(
                text: $composeState.message,
                context: popopxComposerContext,
                ttlSeconds: popopxTTLSeconds,
                secureTTLSeconds: popopxSecureTTLSeconds,
                isSendEnabled: popopxSendEnabled(disableSendButton),
                // 旧链路在禁用态把占位文案置 nil（`sendMessageView` 的 `placeholder:` 那一行），
                // 那句 `disabledText` 压在框上时不该再叠一层提示。
                placeholder: disabledText == nil ? "发消息…" : "",
                onSend: popopxComposerSend,
                onHoldToTalk: popopxHoldToTalk,
                onPlusTap: popopxPlusAction,
                onTTLChange: { seconds in popopxTTLSeconds = seconds },
                onSecureTTLChange: { seconds in popopxSecureTTLSeconds = seconds },
                plusActions: popopxPlusActions
            )
            if let disabledText {
                Text(disabledText)
                    .italic()
                    .foregroundColor(theme.colors.secondary)
                    .padding(.horizontal, 12)
            }
        }
        .focused($popopxComposerFocused)
        .onChange(of: popopxComposerFocused) { _, focused in
            keyboardVisible = focused
            if !focused { keyboardHiddenDate = Date.now }
        }
        if popopxLiveMessageAllowed {
            bar.contextMenu { popopxLiveMessageMenuItem() }
        } else {
            bar
        }
    }

    /// 发送键的落点：归谁发已经由 `PopopxComposerRouting.dispatch` 判完，这里只执行两支副作用。
    /// - `.routeViaMesh`：交给模块 5，由它决定公网 / 蓝牙 / 兜底队列；草稿由输入条自己清。
    /// - `.hostShouldSend`：原样走旧链路 `sendMessage(ttl:)`，草稿在 `sendMessageAsync` 末尾清；
    ///   阅后即焚是一次性的发送选项（旧菜单每按一次重选），所以发完把档位放回 nil。
    private func popopxComposerSend(_ send: PopopxComposerSend) {
        if let secureTTL = send.secureTTLSeconds {
            // 绝密这一支不走下面那张 switch：`send.dispatch` 是**用明文算出来的结论**，
            // 而真正要发出去的是密文行，判定表要拿到的是最终落在路上的那串字节。
            // 所以这里把明文交给载荷层重铸（`PopopxSecurePayload.make`），再按密文重新判定一次通道
            // —— 和 `popopxSendLocation` 同一个形状：那条也是自带文本、自己重算 dispatch。
            Task {
                await popopxSendSecure(
                    plaintext: send.text,
                    smpTTLSeconds: send.ttlSeconds,
                    secureTTLSeconds: secureTTL
                )
            }
            return
        }
        switch send.dispatch {
        case let .routeViaMesh(message):
            Task { await PopopxMeshRuntime.shared.router.send(message) }
        case .hostShouldSend:
            popopxTTLSeconds = nil
            sendMessage(ttl: send.ttlSeconds)
            resetLinkPreview()
        case .ignoreEmptyDraft:
            break
        }
    }

    /// 「按住说话」在新条里是一次**按下即回调**（`PopopxInputBar` 的 `holdToTalkBar`），
    /// 所以桥接成点按开始 / 点按结束。`audioRecorder` 与 `voiceMessageRecordingState`
    /// 那套状态机本身一位没动，计时也还是 `AudioRecorder.onTimer` 在推。
    private func popopxHoldToTalk() {
        if case .recording = composeState.voiceMessageRecordingState {
            finishVoiceMessageRecording()
        } else {
            Task { await startVoiceMessageRecording() }
        }
    }

    /// 「+」面板在当前会话里真正能用的格子。判据只有一条来源：`popopxPacketDestination`。
    /// 之所以筛而不是画出来再拦 —— 见 `PopopxInputBar.plusActions` 那段注释。
    private var popopxPlusActions: [PopopxPlusAction] {
        PopopxPlusAction.allCases.filter { action in
            switch action {
            case .redPacket: popopxPacketDestination != nil && chat.chatInfo.sendMsgEnabled
            // 礼品卡的核销回执只有 `PopopxCommerceTarget.contact` 一条落点（路由器没有群组那一支），
            // 所以这一格只在单聊出现；群里想要徽章请让对方把码抄给对方，或直接走「我的 · 兑换码」。
            case .giftCard: chat.chatInfo.contact != nil && chat.chatInfo.sendMsgEnabled
            case .photo, .camera, .file, .location, .secure, .personalProfile: true
            }
        }
    }

    /// 红包落点：**只有 1:1 单聊**。判据只有一条来源，`popopxPlusActions` 里那一格跟着它筛。
    ///
    /// 裁定记录（2026-11-19）：群里不发红包。一份红包在群里由 N 个人各自"拆开"，
    /// 而这一层没有服务端账本 —— 去重只存在于**各台设备自己的**流水里
    /// （`PopopxCreditsManager.claimRedPacket` 按 packetId 夹一份，`recordClaim` 按成员记账），
    /// 并发拆开时最坏能多到账。单聊没有这个形状：只有一台设备能拆，回执也只回它自己那一份。
    /// 频道、私人笔记、连接中、请求这四类会话同样返回 nil（后三类本来就没有对面这个人）。
    private var popopxPacketDestination: PopopxPacketDestination? {
        if let contact = chat.chatInfo.contact {
            return .contact(id: contact.contactId, name: contact.displayName)
        }
        return nil
    }

    /// 「+」面板每一格接回既有链路：相册 / 拍摄 / 文件是 `showMediaPicker` / `showTakePhoto` /
    /// `showFileImporter` 三个开关；位置与个人主页各开一个确认 Sheet，绝密那格只翻武装开关。
    /// 禁用条件抄 `attachmentButton()`：已有附件、改写 / 转发 / live / 举报中不给开，本会话禁文件时给同样的提示。
    /// 红包与礼品卡是最后两支：它们不共用那条门 —— 格子本身只在有落点的会话里出现（`popopxPlusActions`），
    /// 所以那两处的 `guard` 是给"筛完格子到按下之间会话变了"留的余量：宁可不发，也不把红包发进一个没有落点的会话。
    private func popopxPlusAction(_ action: PopopxPlusAction) {
        switch action {
        case .location:
            // 位置和相册 / 拍摄 / 文件不是一条链路：它在线上就是一行纯文本，所以群里"禁用文件与媒体"
            // 那条限制不该拦它；但改写 / 转发 / live / 举报 / 已挂附件的草稿会让这条独立消息和草稿
            // 各说各话（发出去的是位置，留在框里的还是草稿），所以沿用旧链路那个现成的门。
            if composeState.attachmentDisabled {
                AlertManager.shared.showAlertMsg(
                    title: "暂不能发送位置",
                    message: "正在改写、转发、录制即时消息或已挂载附件时，不能插入位置消息。"
                )
            } else if !chat.chatInfo.sendMsgEnabled {
                AlertManager.shared.showAlertMsg(title: "会话未就绪", message: "该会话当前不允许发送消息。")
            } else {
                showLocationPicker = true
            }
        case .personalProfile:
            // 和 `.location` 同一条门：主页在线上先是一行索引文本，媒体原件随后各自成行，
            // 所以"群里禁用文件与媒体"那道限制（`.photo/.camera/.file` 那一支）不该拦它——
            // 但改写 / 转发 / live / 举报 / 已挂附件的草稿会让主页和草稿各说各话，照旧拦。
            if composeState.attachmentDisabled {
                AlertManager.shared.showAlertMsg(
                    title: "暂不能发送个人主页",
                    message: "正在改写、转发、录制即时消息或已挂载附件时，不能另外发送一份个人主页。"
                )
            } else if !chat.chatInfo.sendMsgEnabled {
                AlertManager.shared.showAlertMsg(title: "会话未就绪", message: "该会话当前不允许发送消息。")
            } else {
                showProfileSendSheet = true
            }
        case .secure:
            // 「+」面板里那一格是**武装开关**，不是选择器：只翻宿主那一格真值，输入条不留副本。
            // 这里的拒绝只是提前说一句人话；真正的门禁在 `popopxSendSecure` 里，
            // 因为面板上那个复选框走的是另一条写入路径，挡不住它。
            if composeState.attachmentDisabled {
                AlertManager.shared.showAlertMsg(
                    title: "暂不能发送绝密消息",
                    message: "正在改写、转发、录制即时消息或已挂载附件时，不能把这条草稿标成绝密。"
                )
            } else if !chat.chatInfo.sendMsgEnabled {
                AlertManager.shared.showAlertMsg(title: "会话未就绪", message: "该会话当前不允许发送消息。")
            } else {
                PopopxHaptics.impact(.light)
                popopxSecureTTLSeconds = popopxSecureTTLSeconds == nil
                    ? PopopxSecureCopy.defaultTTLSeconds
                    : nil
            }
        case .redPacket:
            // 面板已经按会话筛过这一格（`popopxPlusActions`），能走到这里说明落点一定存在；
            // 这一支只兜"面板开着时会话变成了不能发消息"那种极窄的窗口 —— 宁可不发，也不发进一个没有落点的会话。
            guard let destination = popopxPacketDestination else { return }
            packetDestination = destination
            showRedPacketSheet = true
        case .giftCard:
            guard let contactId = chat.chatInfo.contact?.contactId else { return }
            giftCardContactId = contactId
            showGiftCardSheet = true
        case .photo, .camera, .file:
            if im.secondaryIMFilter == nil, !chat.chatInfo.featureEnabled(.files) {
                AlertManager.shared.showAlertMsg(
                    title: "Files and media prohibited!",
                    message: chat.chatInfo.groupInfo == nil ? nil : "Only group owners can enable files and media."
                )
            } else if !composeState.attachmentDisabled, chat.chatInfo.sendMsgEnabled {
                switch action {
                case .photo: showMediaPicker = true
                case .camera: showTakePhoto = true
                case .file: showFileImporter = true
                // 这几格在 `.photo/.camera/.file` 这一支里到不了：外层 switch 已经把它们分出去了。
                // 写 `break` 而不是删掉，是为了让这个 switch 保持穷尽 —— 加新的一格时
                // 这里会编译不过，提醒两处都要改。
                case .location, .secure, .personalProfile, .redPacket, .giftCard: break
                }
            }
        }
    }

    /// 「发送位置」的落点。位置在线上就是一行纯文本，所以它和输入条里的普通文本共用**同一张判定表**
    /// （`PopopxComposerRouting.dispatch`）：已绑定 + 射频开 + 邻居可达就交给模块 5，否则交回宿主的 SMP。
    /// 判定表因此不需要为位置开新格 —— 它判的是"这条消息有没有路由带不动的东西"，位置一个都没有。
    ///
    /// 刻意不走 `sendMessageAsync`：那条链路会连草稿一起发（`composeState.preview` 的六支），末尾还
    /// `clearState` 把用户没发完的草稿和链接预览清掉。位置是一条独立消息，草稿该原样留着。
    ///
    /// 同理它也不进 `checkComposeLinksAsync`：`popopx://loc` 和一次性邀请链接是同一个 scheme，
    /// 被当成连接链接就会把一条位置消息变成一次加好友（`PopopxLocation.swift:17`-`:21`）。
    @MainActor private func popopxSendLocation(_ payload: PopopxLocationPayload) async {
        let contactId = chat.chatInfo.contact?.contactId
        // 这条消息自己的前提只有"直聊联系人"一条：草稿里挂着的附件、引用、@提及、live 都不属于它，
        // 把它们算进来会让一条已经选好的位置因为框里有图而绕开蓝牙。阅后即焚是真档位，照旧参与判定。
        let context: PopopxComposerContext
        if let contactId {
            context = .directContact(contactId)
        } else {
            context = .outsideDirectContact
        }
        let eligibility = await PopopxInputBarModel.resolveFromRuntime(contactId: contactId)
        switch PopopxComposerRouting.dispatch(
            text: payload.messageContent,
            context: context,
            eligibility: eligibility,
            ttlSeconds: popopxTTLSeconds
        ) {
        case let .routeViaMesh(message):
            await PopopxMeshRuntime.shared.router.send(message)
        case .hostShouldSend:
            // 档位和旧链路一样是一次性的：发完放回 nil，下一条回到"不阅后即焚"。
            let ttl = popopxTTLSeconds
            popopxTTLSeconds = nil
            await popopxSendPlainViaSMP(payload.messageContent, ttl: ttl)
        case .ignoreEmptyDraft:
            break
        }
    }

    /// 「发送个人主页」的落点。和上面两支不同，这里**不在本文件里判定通道**：一份主页同时牵着一行
    /// 索引文本和 N 件媒体原件，原件永远不能走蓝牙（判定表的 `.richContent`），降级成纯文字又是产品
    /// 要求的行为——两件事的先后次序（索引先落公网、原件随后排队、断网时整份改走厢语投影）属于发送器，
    /// 放在这里会让 `ComposeView` 变成第二个真相源。所以本函数只做三件事：交出去、把结论说给用户、
    /// 清掉那条 live dummy（判据抄 `popopxSendPlainViaSMP`，只在真的公网送达之后）。
    ///
    /// 它同样不进 `checkComposeLinksAsync`，也不走 `sendMessageAsync`：两条理由和位置那一份完全相同
    /// （`popopx://profile` 与一次性邀请链接同 scheme；草稿必须原样留在框里）。
    @MainActor private func popopxSendProfile(_ manifest: PopopxProfileManifest) async {
        let outcome = await ProfileAutoSender.shared.send(manifest, to: chat)
        switch outcome {
        case let .sentFullMedia(indexSent, mediaQueued):
            if indexSent { chatModel.removeLiveDummy(animated: false) }
            logger.notice("POPOPX profile: 本机手动发送走公网（媒体排队 \(mediaQueued, privacy: .public) 件）")
        case let .sentMeshTextOnly(omitted):
            logger.notice("POPOPX profile: 本机手动发送走厢语纯文字（省去 \(omitted, privacy: .public) 件媒体）")
        case let .refused(refusal):
            PopopxHaptics.notice(.warning)
            AlertManager.shared.showAlertMsg(
                title: "无法发送个人主页",
                // 插值而不是直传：`showAlertMsg` 收的是 `LocalizedStringKey`（ContentView.swift:540），
                // 一句运行期才算出来的拒绝理由只能用插值落进去。
                message: "\(refusal.explanation ?? refusal.description)"
            )
        case let .failed(reason):
            PopopxHaptics.notice(.error)
            AlertManager.shared.showAlertMsg(title: "发送失败", message: "\(reason)")
        }
    }

    /// 交回宿主那一支，抄 `sendMessageAsync` 里嵌套的 `send(_ msgs:)`：`apiSendMessages` +
    /// `removeLiveDummy` + `addChatItem`，一位不多 —— 位置和绝密都没有文件要回收，失败提示也在
    /// `apiSendMessages` 自己那侧弹（`POPOPXAPI.swift:640`），这里不再叠第二层。
    ///
    /// 名字从 `…LocationViaSMP` 改成了 `…PlainViaSMP`：这条链路对"线上一行纯文本"负责，
    /// 位置是它第一个用户，绝密载荷是第二个（那两行文本在外形上完全同构，见
    /// `PopopxSecurePayload.swift:9`-`:14`）。留着 Location 的名字会让下一个人再抄一遍。
    @discardableResult
    private func popopxSendPlainViaSMP(_ text: String, ttl: Int?) async -> Bool {
        guard let chatItems = await apiSendMessages(
            type: chat.chatInfo.chatType,
            id: chat.chatInfo.apiId,
            scope: chat.chatInfo.groupChatScope(),
            sendAsGroup: chat.chatInfo.sendAsGroup,
            live: false,
            ttl: ttl,
            sign: false,
            composedMessages: [ComposedMessage(msgContent: .text(text))]
        ) else { return false }
        await MainActor.run {
            chatModel.removeLiveDummy(animated: false)
            for chatItem in chatItems {
                chatModel.addChatItem(chat.chatInfo, chatItem)
            }
        }
        return true
    }

    /// 「发送绝密消息」的落点。铸载荷排在**任何判定之前**：判定表、SMP、蓝牙中继队列拿到的
    /// 都只能是密文行（`payload.messageContent`）。让明文穿过其中任何一站，"严禁在列表里暴露明文"
    /// 就先在发送侧破了。
    ///
    /// 和位置一样**不走** `sendMessageAsync`：那条链路会把草稿连同链接预览、引用一起发出去，
    /// 末尾还 `clearState`；而 `popopx://sec` 与一次性邀请链接同 scheme，进了
    /// `checkComposeLinksAsync` 就是一次误加好友（`PopopxSecurePayload.swift:37`-`:41`）。
    ///
    /// 但绝密有一处和位置**必须**不同：位置的内容来自地图选择器，绝密的明文就停在输入框里，
    /// 所以发送成功后必须把它清掉 —— 见 `popopxAfterSecureSend()`。
    @MainActor private func popopxSendSecure(
        plaintext: String,
        smpTTLSeconds: Int?,
        secureTTLSeconds: Int
    ) async {
        // 门禁在这里，不在「+」面板那一格：面板上的复选框走的是另一条写入路径，
        // 只挡按钮会留下"能武装、发不出、也不说为什么"的那种静默失败。
        guard !composeState.attachmentDisabled else {
            popopxSecureBlocked()
            return
        }
        guard chat.chatInfo.sendMsgEnabled else {
            AlertManager.shared.showAlertMsg(title: "会话未就绪", message: "该会话当前不允许发送消息。")
            return
        }
        let payload: PopopxSecurePayload
        do {
            payload = try PopopxSecurePayload.make(plaintext: plaintext, ttlSeconds: secureTTLSeconds)
        } catch let error as PopopxSecureError {
            // 这一句走 `Text(verbatim:)` 而不是 `showAlertMsg`：后者的入参是 `LocalizedStringKey`
            // （ContentView.swift:540），运行时拼出来的 String 根本转不过去，而且里面带着字节数，
            // 当成格式化串去查本地化表是把话交给运气。
            AlertManager.shared.showAlert(
                Alert(title: Text(verbatim: "绝密消息未发出"),
                      message: Text(verbatim: Self.popopxSecureSendReason(error)))
            )
            return
        } catch {
            AlertManager.shared.showAlertMsg(
                title: "绝密消息未发出",
                message: "本机封装失败，这条内容一个字节都没离开这台设备。"
            )
            return
        }

        let contactId = chat.chatInfo.contact?.contactId
        // 同位置那条判定：这条消息自己的前提只有"直聊联系人"，框里挂着的附件/引用/live 不属于它。
        // 阅后即焚（SMP 那一档）是真档位，照旧参与判定。
        let context: PopopxComposerContext
        if let contactId {
            context = .directContact(contactId)
        } else {
            context = .outsideDirectContact
        }
        let eligibility = await PopopxInputBarModel.resolveFromRuntime(contactId: contactId)
        switch PopopxComposerRouting.dispatch(
            text: payload.messageContent,
            context: context,
            eligibility: eligibility,
            ttlSeconds: smpTTLSeconds
        ) {
        case let .routeViaMesh(message):
            await PopopxMeshRuntime.shared.router.send(message)
            popopxAfterSecureSend()
        case .hostShouldSend:
            // 只有真发出去了才清草稿：`apiSendMessages` 返回 nil 时它自己已经弹过提示，
            // 那时把明文清掉等于让用户白丢一条内容。
            if await popopxSendPlainViaSMP(payload.messageContent, ttl: smpTTLSeconds) {
                popopxAfterSecureSend()
            }
        case .ignoreEmptyDraft:
            break
        }
    }

    /// 绝密发送成功后的收尾。三件事各有各的理由：
    /// 1. **清草稿**：用户打的明文还在 `composeState.message` 里，不清就等于这条消息
    ///    在发送方自己的屏幕上永久留着 —— 这是整个特性里唯一一处"发送侧"的明文残留。
    /// 2. **关链接预览**：`composeState.preview` 是明文的第二种存法（它抄的就是这条草稿的文本）。
    /// 3. **两档都归 nil**：绝密与阅后即焚都是"一次发送一次选择"，和旧发送键菜单同一语义；
    ///    留着下一档会让下一条普通消息被误标成绝密，而那比反过来更糟。
    private func popopxAfterSecureSend() {
        composeState.message = ""
        resetLinkPreview()
        popopxSecureTTLSeconds = nil
        popopxTTLSeconds = nil
    }

    private func popopxSecureBlocked() {
        AlertManager.shared.showAlertMsg(
            title: "暂不能发送绝密消息",
            message: "正在改写、转发、录制即时消息或已挂载附件时，不能把这条草稿标成绝密。"
        )
    }

    /// 载荷层的错误到句人话。这里只做映射，不新增判断：长度上限的数字取自契约方，
    /// 免得这句提示和 `maximumPlainBytes` 长成两个版本。
    private static func popopxSecureSendReason(_ error: PopopxSecureError) -> String {
        switch error {
        case .emptyPlaintext:
            return "内容为空。"
        case let .plaintextTooLong(bytes):
            return "绝密消息最长 \(PopopxSecurePayload.maximumPlainBytes / 1024) KiB，当前 \(bytes) 字节。"
        case .sealingFailed:
            return "本机封装失败，这条内容一个字节都没离开这台设备。"
        case .unusablePlaintext, .wrongKeyLength, .wrongSealedLength, .decryptionFailed:
            // 这三条只在接收侧解得开时才可能出，发送侧到不了；写出来是为了让这个 switch 穷尽，
            // 也为了万一以后有人在这条路上调 `open()`，不会掉进 `default` 那句含糊话里。
            return "载荷不可用，未发送。"
        case .authenticationFailed, .biometricsUnavailable, .screenIsCaptured:
            return "这台设备当前不允许打开绝密消息。"
        }
    }

    /// live 消息的入口在旧链路里只长在发送键的长按菜单上（`SendMessageView.swift:194`-`:241`），
    /// 新条没有可挂菜单的发送键，所以整条 composer 接同一个菜单，内容只有这一项：
    /// 阅后即焚归「+」面板，签名那一支在上游就被注释掉了，而且它只属于群 / 频道，不在换皮范围内。
    private var popopxLiveMessageAllowed: Bool {
        composeState.liveMessage == nil
        && !composeState.editing
        && composeState.contextItem == .noContextItem
        && !composeState.voicePreview
        && !composeState.manyMediaPreviews
        && chat.chatInfo.chatType != .local
    }

    @ViewBuilder private func popopxLiveMessageMenuItem() -> some View {
        Button {
            startPopopxLiveMessage()
        } label: {
            Label("Send live message", systemImage: "bolt.fill")
        }
    }

    /// 和 `SendMessageView.startLiveMessage` 同一条链路：先发一条 live，再按同一个节拍 `updateLiveMessage`。
    /// 节拍常量 `liveMsgInterval` 在 `SendMessageView.swift:13` 是文件级 `private let`，取不过来，
    /// 这里写死同一个 3 秒；只弹一次提醒用的是同一个 UserDefaults 键，不是第二份开关。
    /// 旧键的脉冲动画（`sendButtonSize` / `sendButtonOpacity`）是旧发送键自己的皮，不跟过来。
    private func startPopopxLiveMessage() {
        func start() {
            Task {
                await sendLiveMessage()
                _ = try? await Task.sleep(nanoseconds: Self.popopxLiveMsgInterval)
                while composeState.liveMessage != nil {
                    await updateLiveMessage()
                    _ = try? await Task.sleep(nanoseconds: Self.popopxLiveMsgInterval)
                }
            }
        }
        if liveMessageAlertShown {
            start()
        } else {
            AlertManager.shared.showAlert(Alert(
                title: Text("Live message!"),
                message: Text("Send a live message - it will update for the recipient(s) as you type it"),
                primaryButton: .default(Text("Send")) {
                    liveMessageAlertShown = true
                    start()
                },
                secondaryButton: .cancel()
            ))
        }
    }

    private func sendMemberContactInvitation() {
        Task {
            do {
                await MainActor.run { hideKeyboard() }
                if let mc = connectCheckLinkPreview() {
                    await sending()
                    let contact = try await apiSendMemberContactInvitation(chat.chatInfo.apiId, mc)
                    await MainActor.run {
                        self.chatModel.updateContact(contact)
                        clearState()
                    }
                } else {
                    AlertManager.shared.showAlertMsg(title: "Empty message!")
                }
            } catch {
                await MainActor.run { composeState.inProgress = false }
                logger.error("ChatView.sendMemberContactInvitation error: \(error.localizedDescription)")
                AlertManager.shared.showAlertMsg(title: "Error sending member contact invitation", message: "Error: \(responseError(error))")
            }
        }
    }

    private func sendConnectPreparedContactRequest() {
        hideKeyboard()
        let empty = composeState.whitespaceOnly
        AlertManager.shared.showAlert(Alert(
            title: Text("Send contact request?"),
            message: Text("You will be able to send messages **only after your request is accepted**."),
            primaryButton: .default(
                Text(empty ? "Send request without message" : "Send request"),
                action: sendConnectPreparedContact
            ),
            secondaryButton:
                empty
                ? .cancel(Text("Add message"), action: hideKeyboard)
                : .cancel()
        ))
    }

    private func sendConnectPreparedContact() {
        Task {
            await MainActor.run { hideKeyboard() }
            await sending()
            let mc = connectCheckLinkPreview()
            let incognito = chat.chatInfo.profileChangeProhibited ? chat.chatInfo.incognito : incognitoDefault
            if let contact = await apiConnectPreparedContact(contactId: chat.chatInfo.apiId, incognito: incognito, msg: mc) {
                await MainActor.run {
                    self.chatModel.updateContact(contact)
                    clearState()
                }
            } else {
                await MainActor.run { composeState.inProgress = false }
            }
        }
    }

    private func connectPreparedGroup() {
        Task {
            await MainActor.run { hideKeyboard() }
            await sending()
            let mc = connectCheckLinkPreview()
            let incognito = chat.chatInfo.profileChangeProhibited ? chat.chatInfo.incognito : incognitoDefault
            if let (groupInfo, relayResults) = await apiConnectPreparedGroup(groupId: chat.chatInfo.apiId, incognito: incognito, msg: mc) {
                await MainActor.run {
                    self.chatModel.updateGroup(groupInfo)
                    self.chatModel.channelRelayHostnames.removeValue(forKey: groupInfo.groupId)
                    self.chatModel.groupMembers = relayResults.map { GMember($0.relayMember) }
                    self.chatModel.populateGroupMembersIndexes()
                    clearState()
                }
            } else {
                await MainActor.run { composeState.inProgress = false }
            }
        }
    }

    @inline(__always)
    private func connectCheckLinkPreview() -> MsgContent? {
        let msgText = composeState.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return msgText.isEmpty ? nil : checkLinkPreview_(msgText)
    }

    @inline(__always)
    private func checkLinkPreview() -> MsgContent {
        checkLinkPreview_(composeState.message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func checkLinkPreview_(_ msgText: String) -> MsgContent {
        switch (composeState.preview) {
        case let .linkPreview(linkPreview: linkPreview):
            if let parsedMsg = parsePOPOPXMarkdown(msgText),
               let url = getMessageLinks(parsedMsg).url,
               let linkPreview = linkPreview,
               url == linkPreview.uri {
                return .link(text: msgText, preview: linkPreview)
            } else {
                return .text(msgText)
            }
        default:
            return .text(msgText)
        }
    }

    // Spec: spec/client/compose.md#addMediaContent
    private func addMediaContent(_ content: UploadContent) async {
        if let img = await content.imagePreview() {
            var newMedia: [(String, UploadContent?)] = []
            if case var .mediaPreviews(media) = composeState.preview {
                media.append((img, content))
                newMedia = media
            } else {
                newMedia = [(img, content)]
            }
            await MainActor.run {
                composeState = composeState.copy(preview: .mediaPreviews(mediaPreviews: newMedia))
            }
        }
    }

    // When error occurs while converting video, remove media preview
    private func finishedPreprocessingMediaContent() {
        if case let .mediaPreviews(media) = composeState.preview, media.isEmpty {
            DispatchQueue.main.async {
                composeState = composeState.copy(preview: .noPreview)
            }
        }
    }

    // no badge is presented in incognito chats, so it does not raise the limit there
    private var sendIncognito: Bool {
        chat.chatInfo.profileChangeProhibited ? chat.chatInfo.incognito : incognitoDefault
    }

    private var sendProfile: LocalProfile? { sendIncognito ? nil : chatModel.currentUser?.profile }

    private var maxFileSize: Int64 { getMaxFileSize(.xftp, sendProfile) }

    // Spec: spec/client/compose.md#sendLiveMessage
    private func sendLiveMessage() async {
        let typedMsg = composeState.message
        let lm = composeState.liveMessage
        if (composeState.sendEnabled || composeState.quoting)
            && (lm == nil || lm?.sentMsg == nil),
           let ci = await sendMessageAsync(typedMsg, live: true, ttl: nil) {
            await MainActor.run {
                composeState = composeState.copy(liveMessage: LiveMessage(chatItem: ci, typedMsg: typedMsg, sentMsg: typedMsg))
            }
        } else if lm == nil {
            let cItem = chatModel.addLiveDummy(chat.chatInfo)
            await MainActor.run {
                composeState = composeState.copy(liveMessage: LiveMessage(chatItem: cItem, typedMsg: typedMsg, sentMsg: nil))
            }
        }
    }

    // Spec: spec/client/compose.md#updateLiveMessage
    private func updateLiveMessage() async {
        let typedMsg = composeState.message
        if let liveMessage = composeState.liveMessage {
            if let sentMsg = liveMessageToSend(liveMessage, typedMsg),
               let ci = await sendMessageAsync(sentMsg, live: true, ttl: nil) {
                await MainActor.run {
                    composeState = composeState.copy(liveMessage: LiveMessage(chatItem: ci, typedMsg: typedMsg, sentMsg: sentMsg))
                }
            } else if liveMessage.typedMsg != typedMsg {
                await MainActor.run {
                    var lm = liveMessage
                    lm.typedMsg = typedMsg
                    composeState = composeState.copy(liveMessage: lm)
                }
            }
        }
    }

    // Spec: spec/client/compose.md#liveMessageToSend
    private func liveMessageToSend(_ lm: LiveMessage, _ t: String) -> String? {
        let s = t != lm.typedMsg ? truncateToWords(t) : t
        return s != lm.sentMsg && (lm.sentMsg != nil || !s.isEmpty) ? s : nil
    }

    private func truncateToWords(_ s: String) -> String {
        var acc = ""
        var word = ""
        for c in s {
            if c.isLetter || c.isNumber {
                word = word + String(c)
            } else {
                acc = acc + word + String(c)
                word = ""
            }
        }
        return acc
    }

    @ViewBuilder func previewView() -> some View {
        switch composeState.preview {
        case .noPreview:
            EmptyView()
        case let .linkPreview(linkPreview: preview):
            ComposeLinkView(
                linkPreview: preview,
                cancelPreview: cancelLinkPreview,
                cancelEnabled: !composeState.inProgress
            )
            Divider()
        case let .chatLinkPreview(chatLink, _):
            ComposeChatLinkView(
                chatLink: chatLink,
                cancelPreview: {
                    composeState = composeState.copy(preview: .noPreview)
                },
                cancelEnabled: !composeState.inProgress
            )
            Divider()
        case let .mediaPreviews(mediaPreviews: media):
            ComposeImageView(
                images: media.map { (img, _) in img },
                cancelImage: {
                    composeState = composeState.copy(preview: .noPreview)
                    chosenMedia = []
                },
                cancelEnabled: !composeState.editing && !composeState.inProgress)
            Divider()
        case let .voicePreview(recordingFileName, _):
            ComposeVoiceView(
                recordingFileName: recordingFileName,
                recordingTime: $voiceMessageRecordingTime,
                recordingState: $composeState.voiceMessageRecordingState,
                cancelVoiceMessage: {
                    cancelVoiceMessageRecording($0)
                    clearState()
                },
                cancelEnabled: !composeState.editing && !composeState.inProgress,
                stopPlayback: $stopPlayback
            )
            Divider()
        case let .filePreview(fileName, _):
            ComposeFileView(
                fileName: fileName,
                cancelFile: {
                    composeState = composeState.copy(preview: .noPreview)
                },
                cancelEnabled: !composeState.editing && !composeState.inProgress)
            Divider()
        }
    }

    private func msgNotAllowedView(_ reason: LocalizedStringKey, icon: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(theme.colors.secondary)
            Text(reason).italic()
        }
        .padding(12)
        .frame(minHeight: 54)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    private func contextSendMessageToConnect(_ s: LocalizedStringKey) -> some View {
        HStack {
            Image(systemName: "message")
                .foregroundColor(theme.colors.secondary)
            Text(s)
        }
        .padding(12)
        .frame(minHeight: 54)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToolbarMaterial.material(toolbarMaterial))
    }

    private func reportReasonView(_ reason: ReportReason) -> some View {
        let reportText = switch reason {
        case .spam: NSLocalizedString("Report spam: only group moderators will see it.", comment: "report reason")
        case .profile: NSLocalizedString("Report member profile: only group moderators will see it.", comment: "report reason")
        case .community: NSLocalizedString("Report violation: only group moderators will see it.", comment: "report reason")
        case .illegal: NSLocalizedString("Report content: only group moderators will see it.", comment: "report reason")
        case .other: NSLocalizedString("Report other: only group moderators will see it.", comment: "report reason")
        case .unknown: "" // Should never happen
        }

        return Text(reportText)
            .italic()
            .font(.caption)
            .padding(12)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
    }


    @ViewBuilder private func contextItemView() -> some View {
        switch composeState.contextItem {
        case .noContextItem:
            EmptyView()
        case let .quotedItem(chatItem: quotedItem):
            ContextItemView(
                chat: chat,
                contextItems: [quotedItem],
                contextIcon: "arrowshape.turn.up.left",
                cancelContextItem: { composeState = composeState.copy(contextItem: .noContextItem) }
            )
            Divider()
        case let .editingItem(chatItem: editingItem):
            ContextItemView(
                chat: chat,
                contextItems: [editingItem],
                contextIcon: "pencil",
                cancelContextItem: { clearState() }
            )
            Divider()
        case let .forwardingItems(chatItems, _):
            ContextItemView(
                chat: chat,
                contextItems: chatItems,
                contextIcon: "arrowshape.turn.up.forward",
                cancelContextItem: { composeState = composeState.copy(contextItem: .noContextItem) }
            )
            Divider()
        case let .reportedItem(chatItem: reportedItem, _):
            ContextItemView(
                chat: chat,
                contextItems: [reportedItem],
                contextIcon: "flag",
                cancelContextItem: { composeState = composeState.copy(contextItem: .noContextItem) },
                contextIconForeground: Color.red
            )
            Divider()
        }
    }

    // Spec: spec/client/compose.md#sendMessage
    private func sendMessage(ttl: Int?, sign: Bool = false) {
        logger.debug("ChatView sendMessage")
        Task {
            logger.debug("ChatView sendMessage: in Task")
            _ = await sendMessageAsync(nil, live: false, ttl: ttl, sign: sign)
        }
    }

    // Spec: spec/client/compose.md#sendMessageAsync
    private func sendMessageAsync(_ text: String?, live: Bool, ttl: Int?, sign: Bool = false) async -> ChatItem? {
        var sent: ChatItem?
        let msgText = text ?? composeState.message
        let liveMessage = composeState.liveMessage
        let mentions = composeState.memberMentions
        if !live {
            if liveMessage != nil { composeState = composeState.copy(liveMessage: nil) }
            await sending()
        }
        if case let .forwardingItems(chatItems, fromChatInfo) = composeState.contextItem {
            // Composed text is send as a reply to the last forwarded item
            sent = await forwardItems(chatItems, fromChatInfo, ttl).last
            if !composeState.message.isEmpty {
                _ = await send(checkLinkPreview(), quoted: sent?.id, live: false, ttl: ttl, mentions: mentions, sign: sign)
            }
        } else if case let .editingItem(ci) = composeState.contextItem {
            sent = await updateMessage(ci, live: live)
        } else if let liveMessage = liveMessage, liveMessage.sentMsg != nil {
            sent = await updateMessage(liveMessage.chatItem, live: live)
        } else if case let .reportedItem(chatItem, reason) = composeState.contextItem {
            sent = await send(reason, chatItemId: chatItem.id)
        } else {
            var quoted: Int64? = nil
            if case let .quotedItem(chatItem: quotedItem) = composeState.contextItem {
                quoted = quotedItem.id
            }

            switch (composeState.preview) {
            case .noPreview:
                sent = await send(.text(msgText), quoted: quoted, live: live, ttl: ttl, mentions: mentions, sign: sign)
            case .linkPreview:
                sent = await send(checkLinkPreview(), quoted: quoted, live: live, ttl: ttl, mentions: mentions, sign: sign)
            case let .chatLinkPreview(chatLink, ownerSig):
                let linkStr = chatLink.connLinkStr
                let text = msgText.isEmpty ? linkStr : msgText + "\n" + linkStr
                sent = await send(.chat(text: text, chatLink: chatLink, ownerSig: ownerSig), quoted: quoted, live: live, ttl: ttl, mentions: mentions, sign: sign)
            case let .mediaPreviews(media):
                // TODO: CHECK THIS
                let last = media.count - 1
                var msgs: [ComposedMessage] = []
                if last >= 0 {
                    for i in 0..<last {
                        if i > 0 {
                            // Sleep to allow `progressByTimeout` update be rendered
                            try? await Task.sleep(nanoseconds: 100_000000)
                        }
                        if let (fileSource, msgContent) = mediaContent(media[i], text: "") {
                            msgs.append(ComposedMessage(fileSource: fileSource, msgContent: msgContent))
                        }
                    }
                    if let (fileSource, msgContent) = mediaContent(media[last], text: msgText) {
                        msgs.append(ComposedMessage(fileSource: fileSource, quotedItemId: quoted, msgContent: msgContent))
                    }
                }
                if msgs.isEmpty {
                    msgs = [ComposedMessage(quotedItemId: quoted, msgContent: .text(msgText))]
                }
                sent = await send(msgs, live: live, ttl: ttl, sign: sign).last

            case let .voicePreview(recordingFileName, duration):
                stopPlayback.toggle()
                let file = voiceCryptoFile(recordingFileName)
                sent = await send(.voice(text: msgText, duration: duration), quoted: quoted, file: file, ttl: ttl, mentions: mentions, sign: sign)
            case let .filePreview(_, file):
                if let savedFile = saveFileFromURL(file) {
                    sent = await send(.file(msgText), quoted: quoted, file: savedFile, live: live, ttl: ttl, mentions: mentions, sign: sign)
                }
            }
        }
        await MainActor.run {
            let wasForwarding = composeState.forwarding
            clearState(live: live)
            if wasForwarding,
               chatModel.draftChatId == draftChatId(chat.chatInfo.id, chat.chatInfo.groupChatScope()),
               let draft = chatModel.draft {
                composeState = draft
            }
        }
        return sent

        func mediaContent(_ media: (String, UploadContent?), text: String) -> (CryptoFile?, MsgContent)? {
            let (previewImage, uploadContent) = media
            return switch uploadContent {
            case let .simpleImage(image):
                (saveImage(image), .image(text: text, image: previewImage))
            case let .imageFile(image, url):
                (imageCryptoFile(url, image), .image(text: text, image: previewImage))
            case let .animatedImage(image):
                (saveAnimImage(image), .image(text: text, image: previewImage))
            case let .video(_, url, duration):
                (moveTempFileFromURL(url), .video(text: text, image: previewImage, duration: duration))
            case .none:
                nil
            }
        }

        func imageCryptoFile(_ url: URL, _ image: UIImage) -> CryptoFile? {
            let file = saveImageFile(url) ?? saveImage(image)
            removeFile(url)
            ChatModel.shared.filesToDelete.remove(url)
            return file
        }

        func updateMessage(_ ei: ChatItem, live: Bool) async -> ChatItem? {
            if let oldMsgContent = ei.content.msgContent {
                do {
                    let mc = updateMsgContent(oldMsgContent)
                    if mc != oldMsgContent || (ei.meta.itemLive ?? false) {
                        let chatItem = try await apiUpdateChatItem(
                            type: chat.chatInfo.chatType,
                            id: chat.chatInfo.apiId,
                            scope: chat.chatInfo.groupChatScope(),
                            itemId: ei.id,
                            updatedMessage: UpdatedMessage(msgContent: mc, mentions: composeState.memberMentions),
                            live: live
                        )
                        await MainActor.run {
                            _ = self.chatModel.upsertChatItem(self.chat.chatInfo, chatItem)
                        }
                        return chatItem
                    } else {
                        return nil
                    }
                } catch {
                    logger.error("ChatView.sendMessage error: \(error.localizedDescription)")
                    AlertManager.shared.showAlertMsg(title: "Error updating message", message: "Error: \(responseError(error))")
                }
            }
            return nil
        }

        func updateMsgContent(_ msgContent: MsgContent) -> MsgContent {
            switch msgContent {
            case .text:
                return checkLinkPreview()
            case .link:
                return checkLinkPreview()
            case .image(_, let image):
                return .image(text: msgText, image: image)
            case .video(_, let image, let duration):
                return .video(text: msgText, image: image, duration: duration)
            case .voice(_, let duration):
                return .voice(text: msgText, duration: duration)
            case .file:
                return .file(msgText)
            case .report(_, let reason):
                return .report(text: msgText, reason: reason)
            case let .chat(_, chatLink, ownerSig):
                let text = msgText.isEmpty ? chatLink.connLinkStr : msgText + "\n" + chatLink.connLinkStr
                return .chat(text: text, chatLink: chatLink, ownerSig: ownerSig)
            case .unknown(let type, _):
                return .unknown(type: type, text: msgText)
            }
        }

        func voiceCryptoFile(_ fileName: String) -> CryptoFile? {
            if !privacyEncryptLocalFilesGroupDefault.get() {
                return CryptoFile.plain(fileName)
            }
            let url = getAppFilePath(fileName)
            let toFile = generateNewFileName("voice", "m4a")
            let toUrl = getAppFilePath(toFile)
            if let cfArgs = try? encryptCryptoFile(fromPath: url.path, toPath: toUrl.path) {
                removeFile(url)
                return CryptoFile(filePath: toFile, cryptoArgs: cfArgs)
            } else {
                return nil
            }
        }

        func send(_ reportReason: ReportReason, chatItemId: Int64) async -> ChatItem? {
            if let chatItems = await apiReportMessage(
                groupId: chat.chatInfo.apiId,
                chatItemId: chatItemId,
                reportReason: reportReason,
                reportText: msgText
            ) {
                if showReportsInSupportChatAlertDefault.get() {
                    await MainActor.run {
                        showReportsInSupportChatAlert()
                    }
                }
                return chatItems.first
            }

            return nil
        }

        func showReportsInSupportChatAlert() {
            showAlert(
                NSLocalizedString("Report sent to moderators", comment: "alert title"),
                message: NSLocalizedString("You can view your reports in Chat with admins.", comment: "alert message"),
                actions: {[
                    UIAlertAction(
                        title: NSLocalizedString("Don't show again", comment: "alert action"),
                        style: .default,
                        handler: { _ in
                            showReportsInSupportChatAlertDefault.set(false)
                        }
                    ),
                    UIAlertAction(
                        title: NSLocalizedString("Ok", comment: "alert action"),
                        style: .default
                    )
                ]}
            )
        }

        func send(_ mc: MsgContent, quoted: Int64?, file: CryptoFile? = nil, live: Bool = false, ttl: Int?, mentions: [String: Int64], sign: Bool = false) async -> ChatItem? {
            await send(
                [ComposedMessage(fileSource: file, quotedItemId: quoted, msgContent: mc, mentions: mentions)],
                live: live,
                ttl: ttl,
                sign: sign
            ).first
        }

        func send(_ msgs: [ComposedMessage], live: Bool, ttl: Int?, sign: Bool = false) async -> [ChatItem] {
            if let chatItems = chat.chatInfo.chatType == .local
                ? await apiCreateChatItems(noteFolderId: chat.chatInfo.apiId, composedMessages: msgs)
                : await apiSendMessages(
                    type: chat.chatInfo.chatType,
                    id: chat.chatInfo.apiId,
                    scope: chat.chatInfo.groupChatScope(),
                    sendAsGroup: chat.chatInfo.sendAsGroup,
                    live: live,
                    ttl: ttl,
                    sign: sign,
                    composedMessages: msgs
                ) {
                await MainActor.run {
                    chatModel.removeLiveDummy(animated: false)
                    for chatItem in chatItems {
                        chatModel.addChatItem(chat.chatInfo, chatItem)
                    }
                }
                return chatItems
            }
            for msg in msgs {
                if let file = msg.fileSource {
                    removeFile(file.filePath)
                }
            }
            return []
        }

        func forwardItems(_ forwardedItems: [ChatItem], _ fromChatInfo: ChatInfo, _ ttl: Int?) async -> [ChatItem] {
            if let chatItems = await apiForwardChatItems(
                toChatType: chat.chatInfo.chatType,
                toChatId: chat.chatInfo.apiId,
                toScope: chat.chatInfo.groupChatScope(),
                sendAsGroup: chat.chatInfo.groupInfo.map { $0.useRelays && $0.membership.memberRole >= .owner } ?? false,
                fromChatType: fromChatInfo.chatType,
                fromChatId: fromChatInfo.apiId,
                fromScope: fromChatInfo.groupChatScope(),
                itemIds: forwardedItems.map { $0.id },
                ttl: ttl
            ) {
                await MainActor.run {
                    for chatItem in chatItems {
                        chatModel.addChatItem(chat.chatInfo, chatItem)
                    }
                    if forwardedItems.count != chatItems.count {
                        showAlert(
                            String.localizedStringWithFormat(
                                NSLocalizedString("%d messages not forwarded", comment: "alert title"),
                                forwardedItems.count - chatItems.count
                            ),
                            message: NSLocalizedString("Messages were deleted after you selected them.", comment: "alert message")
                        )
                    }
                }
                return chatItems
            } else {
                return []
            }
        }
    }

    func sending() async {
        await MainActor.run { composeState.inProgress = true }
    }

    // Spec: spec/client/compose.md#startVoiceMessageRecording
    private func startVoiceMessageRecording() async {
        startingRecording = true
        let fileName = generateNewFileName("voice", "m4a")
        chatModel.stopPreviousRecPlay = getAppFilePath(fileName)
        audioRecorder = AudioRecorder(
            onTimer: { voiceMessageRecordingTime = $0 },
            onFinishRecording: {
                updateComposeVMRFinished()
                if let fileSize = fileSize(getAppFilePath(fileName)) {
                    logger.debug("onFinishRecording recording file size = \(fileSize)")
                }
            }
        )
        if let recStartError = await audioRecorder?.start(fileName: fileName) {
            switch recStartError {
            case .permission:
                AlertManager.shared.showAlert(Alert(
                    title: Text("No permission to record voice message"),
                    message: Text("To record voice message please grant permission to use Microphone."),
                    primaryButton: .default(Text("Open Settings")) {
                        DispatchQueue.main.async {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
                        }
                    },
                    secondaryButton: .cancel()
                ))
            case let .error(error):
                AlertManager.shared.showAlertMsg(
                    title: "Unable to record voice message",
                    message: "Error: \(error)"
                )
            }
        } else {
            composeState = composeState.copy(
                preview: .voicePreview(recordingFileName: fileName, duration: 0),
                voiceMessageRecordingState: .recording
            )
        }
    }

    // Spec: spec/client/compose.md#finishVoiceMessageRecording
    private func finishVoiceMessageRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        updateComposeVMRFinished()
        if let fileName = composeState.voiceMessageRecordingFileName,
           let fileSize = fileSize(getAppFilePath(fileName)) {
            logger.debug("finishVoiceMessageRecording recording file size = \(fileSize)")
        }
    }

    // Spec: spec/client/compose.md#allowVoiceMessagesToContact
    private func allowVoiceMessagesToContact() {
        if case let .direct(contact) = chat.chatInfo {
            allowFeatureToContact(contact, .voice)
        }
    }

    // ? maybe we shouldn't have duration in ComposePreview.voicePreview
    private func updateComposeVMRFinished() {
        var preview = composeState.preview
        if let recordingFileName = composeState.voiceMessageRecordingFileName,
           let recordingTime = voiceMessageRecordingTime {
            preview = .voicePreview(recordingFileName: recordingFileName, duration: Int(recordingTime.rounded()))
        }
        composeState = composeState.copy(
            preview: preview,
            voiceMessageRecordingState: .finished
        )
    }

    private func cancelCurrentVoiceRecording() {
        if let fileName = composeState.voiceMessageRecordingFileName {
            cancelVoiceMessageRecording(fileName)
        }
    }

    // Spec: spec/client/compose.md#cancelVoiceMessageRecording
    private func cancelVoiceMessageRecording(_ fileName: String) {
        stopPlayback.toggle()
        audioRecorder?.stop()
        removeFile(fileName)
    }

    // Spec: spec/client/compose.md#clearState
    private func clearState(live: Bool = false) {
        if live {
            composeState.inProgress = false
        } else {
            composeState = ComposeState()
            resetLinkPreview()
        }
        chosenMedia = []
        audioRecorder = nil
        voiceMessageRecordingTime = nil
        startingRecording = false
    }

    // Spec: spec/client/compose.md#saveCurrentDraft
    private func saveCurrentDraft() {
        chatModel.draft = composeState
        chatModel.draftChatId = draftChatId(chat.id, chat.chatInfo.groupChatScope())
    }

    // Spec: spec/client/compose.md#clearCurrentDraft
    private func clearCurrentDraft() {
        if chatModel.draftChatId == draftChatId(chat.id, chat.chatInfo.groupChatScope()) {
            chatModel.draft = nil
            chatModel.draftChatId = nil
        }
    }

    // Spec: spec/client/compose.md#showLinkPreview
    private func showLinkPreview(_ parsedMsg: [FormattedText]?) {
        prevLinkUrl = linkUrl
        (linkUrl, hasPopopxLink) = getMessageLinks(parsedMsg)
        if let url = linkUrl {
            if url != composeState.linkPreview?.uri && url != pendingLinkUrl {
                pendingLinkUrl = url
                if prevLinkUrl == url {
                    loadLinkPreview(url)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        loadLinkPreview(url)
                    }
                }
            }
        } else {
            composeState = composeState.copy(preview: .noPreview)
        }
    }

    // Spec: spec/client/compose.md#getMessageLinks
    private func getMessageLinks(_ parsedMsg: [FormattedText]?) -> (url: String?, hasPopopxLink: Bool) {
        guard let parsedMsg else { return (nil, false) }
        let popopxLink = parsedMsgHasPopopxLink(parsedMsg)
        for ft in parsedMsg {
            if let link = ft.linkUri, !cancelledLinks.contains(link) && !isPopopxLink(link) {
                return (link, popopxLink)
            }
        }
        return (nil, popopxLink)
    }

    private func isPopopxLink(_ link: String) -> Bool {
        link.starts(with: "https://popopx.chat") || link.starts(with: "http://popopx.chat") || link.starts(with: "popopx:/")
    }

    private func cancelLinkPreview() {
        if let pendingLink = pendingLinkUrl {
            cancelledLinks.insert(pendingLink)
        }
        if let uri = composeState.linkPreview?.uri {
            cancelledLinks.insert(uri)
        }
        pendingLinkUrl = nil
        composeState = composeState.copy(preview: .noPreview)
    }

    // Spec: spec/client/compose.md#loadLinkPreview
    private func loadLinkPreview(_ urlStr: String) {
        if pendingLinkUrl == urlStr, let url = URL(string: urlStr) {
            if linkPreviewsShowAlert {
                showLinkPreviewsConfirmAlert { enable in
                    if let enable {
                        linkPreviewsShowAlert = false
                        useLinkPreviews = enable
                        UserDefaults.standard.set(enable, forKey: DEFAULT_PRIVACY_LINK_PREVIEWS)
                        if enable {
                            fetchLinkPreview(url, urlStr: urlStr)
                        } else {
                            pendingLinkUrl = nil
                            composeState = composeState.copy(preview: .noPreview)
                        }
                    } else {
                        cancelLinkPreview()
                    }
                }
                return
            }
            fetchLinkPreview(url, urlStr: urlStr)
        }
    }

    private func fetchLinkPreview(_ url: URL, urlStr: String) {
        composeState = composeState.copy(preview: .linkPreview(linkPreview: nil))
        getLinkPreview(url: url) { linkPreview in
            if let linkPreview, pendingLinkUrl == urlStr {
                composeState = composeState.copy(preview: .linkPreview(linkPreview: linkPreview))
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    composeState = composeState.copy(preview: .noPreview)
                }
            }
            pendingLinkUrl = nil
        }
    }

    private func showLinkPreviewsConfirmAlert(onChoice: @escaping (Bool?) -> Void) {
        showAlert(
            NSLocalizedString("Enable link previews?", comment: "alert title"),
            message: NSLocalizedString("Sending a link preview may reveal your IP address to the website. You can change this in Privacy settings later.", comment: "alert message"),
            actions: {
                [
                    UIAlertAction(title: NSLocalizedString("Disable", comment: "alert button"), style: .destructive) { _ in onChoice(false) },
                    UIAlertAction(title: NSLocalizedString("Enable", comment: "alert button"), style: .default) { _ in onChoice(true) }
                ]
            }
        )
    }

    private func resetLinkPreview() {
        linkUrl = nil
        prevLinkUrl = nil
        pendingLinkUrl = nil
        cancelledLinks = []
    }
}

func sanitizeMessage(_ parsedMsg: [FormattedText]) -> (message: String, parsedMsg: [FormattedText], sanitizedPos: Int?) {
    var pos: Int = 0
    var updatedMsg = ""
    var sanitizedPos: Int? = nil
    let updatedParsedMsg = parsedMsg.map { ft in
        var updated = ft
        switch ft.format {
        case .uri:
            if let sanitized = parseSanitizeUri(ft.text, safe: true)?.uriInfo?.sanitized {
                updated = FormattedText(text: sanitized, format: .uri)
                pos += updated.text.count
                sanitizedPos = pos
            }
        case let .hyperLink(text, uri):
            if let sanitized = parseSanitizeUri(uri, safe: true)?.uriInfo?.sanitized {
                let updatedText = if let text { "[\(text)](\(sanitized))" } else { sanitized }
                updated = FormattedText(text: updatedText, format: .hyperLink(showText: text, linkUri: sanitized))
                pos += updated.text.count
                sanitizedPos = pos
            }
        default:
            pos += ft.text.count
        }
        updatedMsg += updated.text
        return updated
    }
    return (message: updatedMsg, parsedMsg: updatedParsedMsg, sanitizedPos: sanitizedPos)
}
