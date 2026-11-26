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
    /// The local media engine, observed by the composer so the processing strip
    /// appears while an attachment is being shrunk.
    @State private var popopxMediaInterceptor = PopopxOutgoingMediaInterceptor.shared
    /// What the engine produced for each picked file, keyed by the URL the picker handed over. The
    /// composer reads it twice: once to label the preview, and once at send time so that the bytes
    /// leaving the device are the same ones the label describes.
    @State private var popopxPreparedMedia: [URL: PopopxOutgoingAttachment] = [:]
    @State private var showLocationPicker = false
    /// The this-send confirmation form shown after pressing "Personal profile" in the "+" panel (mode + duration apply to this one send only).
    @State private var showProfileSendSheet = false
    // The switches for the red packet and gift card cells in the "+" panel.
    //
    // The destination is snapshotted into `packetDestination` / `giftCardContactId` at the moment of the press, rather than letting the Sheet
    // re-read the current chat on every refresh: "deduct credits -> post visible line -> post machine line" is three steps inside the panel, and reading another chat midway would send the red packet into
    // a place that was never previewed. The empty cell only appears when the Sheet is collapsed.
    @State private var showRedPacketSheet = false
    @State private var packetDestination: PopopxPacketDestination?
    @State private var showGiftCardSheet = false
    @State private var giftCardContactId: Int64?
    /// The compute-credit gift card cell. It shares `giftCardContactId` with the badge card: both snapshots are taken in the same press
    /// handler, both mean "the contact this draft is addressed to", and sheets cannot overlap, so one value cannot be read by two panels.
    @State private var showCreditsGiftSheet = false

    /// The store behind the service account menu row. Held as state (the house precedent is `BotMenuBarView.swift:81`) so a
    /// `menu_config` frame re-renders this composer, and read through `menus` rather than `liveMenu(for:)`: that public reader
    /// calls `loadIfNeeded()`, and writing store state during `body` is precisely the fault this app documents at
    /// `BotMenuBarView.swift:27-31`. Nothing here needs that load: `loadIfNeeded()` restores cards only — menus are keyed by a
    /// local row id and are therefore rebuilt from inbound frames and never persisted (`PopopxEcoRouterAndDeepLink.swift:99-102`).
    @State private var ecoStore = PopopxEcoStore.shared
    /// Folded = the row shows only the expand key. One value per composer, and a composer exists per open chat, so folding a
    /// menu in one service account cannot fold another.
    @State private var popopxEcoMenuFolded = false

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

    // [B6] The three below are host state that grew when `PopopxInputBar` was mounted at the bottom of the chat page; all are private + with default values,
    // so the synthesized memberwise init's parameter list is untouched (its only call site at `ChatView.swift:237`-`:245` carries on as usual).
    /// The view-once truth lives in the host: the input bar only reads and reports (`PopopxInputBar.swift:21`). The old `SendMessageView`
    /// hid it in the send key menu's `@State` (`SendMessageView.swift:48`-`:52`), so after the reskin there must be somewhere to catch it.
    @State private var popopxTTLSeconds: Int? = nil
    /// The top-secret tier's truth is likewise in the host, and it is **mutually independent** of the cell above: `ttlSeconds` governs how long it stays on the SMP side,
    /// while this cell governs how long the plaintext stays on the peer's screen. Both being non-nil at once is a legal combination (online view-once plus view-once).
    /// These are also all private + with default values, for the same reason as the three above: do not touch the memberwise init's parameter list.
    @State private var popopxSecureTTLSeconds: Int? = nil
    @FocusState private var popopxComposerFocused: Bool
    /// Uses the same UserDefaults key as `SendMessageView.swift:51`: the fact that the reminder pops only once should not have two sources of truth.
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

                // The service account's menu row, mounted once for every conversation rather than inside one composer branch: which
                // branch the composer itself takes depends on the chat's state, and `popopxBarEligible` deliberately excludes a contact
                // that still carries SMP commands — while a service account with commands is still a service account. The row renders
                // nothing unless this contact's `menu_config` is in the store, so an ordinary chat pays one dictionary lookup.
                popopxEcoMenuStrip
                    .padding(.horizontal, 12)

                // Above the input bar. The strip is absent rather than hidden when
                // idle, so the composer does not jump while the engine works.
                if popopxMediaInterceptor.isProcessing {
                    PopopxMediaProcessingCapsule(text: popopxMediaInterceptor.statusText)
                        .padding(.horizontal, 12)
                        .padding(.bottom, PopopxMetrics.space2XS)
                        .transition(.opacity)
                }

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
                    // [B6] Bottom input bar reskin: the quote bar (`contextItemView()`) and the attachment preview bar (`previewView()`)
                    // render above exactly as before, and this branch only swaps out the bottom-most strip. For why not every chat is reskinned, see
                    // the comment on `popopxBarEligible`.
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
            // The picker only picks coordinates; whether to send and which channel to take belong here: it does not even know `chat`.
            // The host closes the switch, and `onSend` closes first then sends, so the form is not left hanging when the send fails.
            PopopxLocationPickerSheet { payload in
                showLocationPicker = false
                Task { await popopxSendLocation(payload) }
            }
            .presentationDetents([.fraction(0.8)])
        }
        .sheet(isPresented: $showProfileSendSheet) {
            // The form only decides "how to send this time" (mode + duration); it does not change a single word of the saved profile draft;
            // the timing of the switch-off copies the branch above: close first, then send, so the form is not still hanging when the send fails.
            ProfileSendModeSheet { manifest in
                showProfileSendSheet = false
                Task { await popopxSendProfile(manifest) }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showRedPacketSheet, onDismiss: { packetDestination = nil }) {
            // Deducting credits, posting the visible line and posting the machine line are all three completed inside the panel (`PopopxSendRedPacketSheet.send()`),
            // and the host here only supplies the destination. The `if let` layer is not decoration: presenting an empty panel when destination is nil
            // would leave the user looking at a page that cannot send a red packet.
            if let packetDestination {
                PopopxSendRedPacketSheet(destination: packetDestination)
                    .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showGiftCardSheet, onDismiss: { giftCardContactId = nil }) {
            // Minting the code, sending the card and sending the signalling also all happen inside the panel (it holds its own `PopopxSilentSignalingRouter`).
            // `contactId` is optional: the panel uses it to decide whether to draw the "Send to contact" button.
            PopopxGiftBadgeCardSheet(contactId: giftCardContactId)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showCreditsGiftSheet, onDismiss: { giftCardContactId = nil }) {
            // The compute-credit twin of the sheet above, and it reuses the credits page rather than adding a picker: with a `contactId`
            // the page opens on its gift segment, and the card face it presents grows the "send in this conversation" button.
            PopopxCreditsStoreView(contactId: giftCardContactId)
                .presentationDetents([.large])
        }
        .onChange(of: chosenMedia) { _, selected in
            Task {
                var media: [(String, UploadContent)] = []
                var prepared: [URL: PopopxOutgoingAttachment] = [:]
                let memberCount = popopxAttachmentMemberCount
                for content in selected {
                    // Prepared as it is picked, not when the send button is pressed: the badge under the
                    // preview has to describe the file that will actually go out, and there is no
                    // honest version of a caption written before the engine has run.
                    if let url = popopxAttachmentURL(content) {
                        prepared[url] = await popopxMediaInterceptor.prepareOne(url, groupMemberCount: memberCount)
                    }
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
                await MainActor.run {
                    popopxDropPreparedMedia(replacing: prepared)
                    popopxPreparedMedia = prepared
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
                        // Prepared at the moment of picking, in the background, so the file row can say
                        // what was actually done to it before the send is pressed. The send reuses this
                        // result instead of running the engine a second time.
                        Task {
                            let memberCount = popopxAttachmentMemberCount
                            let prepared = await popopxMediaInterceptor.prepareOne(fileURL, groupMemberCount: memberCount)
                            await MainActor.run { popopxPreparedMedia[fileURL] = prepared }
                        }
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
        if chat.chatInfo.contact?.profile.peerType != .bot {
            locationButton()
                .padding(.trailing, 3)
        }
    }

    /// The entry for the input bar that did **not** enter the reshaped form (groups, channels, command-menu conversations, contacts awaiting acceptance).
    ///
    /// It only opens the same `PopopxLocationPickerSheet` as the 1:1 `+` panel: the send chain `popopxSendLocation` reads `chat.chatInfo.contact?.contactId`, and
    /// in a group it is nil, which lands in `.outsideDirectContact` and therefore in `.hostShouldSend`, i.e. `popopxSendPlainViaSMP` - that function takes
    /// `chatType` / `apiId` / `groupChatScope()` / `sendAsGroup` itself, so it does not need the 1:1 conditions at all.
    /// **Here it is only the entry that was missing, never the sending capability.**
    ///
    /// Hidden for a bot peer, which is the paperclip's own first condition (`peerType != .bot`): a bot cannot receive a location message, and in another client the card is only one line of plain text.
    private func locationButton() -> some View {
        Button {
            showLocationPicker = true
        } label: {
            Image(systemName: "location.fill")
                .resizable()
        }
        .disabled(!chat.chatInfo.sendMsgEnabled)
        .frame(width: 25, height: 25)
        .tint(theme.colors.primary)
        .accessibilityLabel(Text("Location"))
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

    // MARK: - [B6] `PopopxInputBar` mount (chat page bottom input bar)
    //
    //  The approach matches B5's bubbles exactly: whatever the new component can express fully is reskinned, and what it cannot express stays wholesale in the old view tree,
    //  with both sides sharing the same set of host state (`composeState`, `chosenMedia`, `audioRecorder`, `showCommandsMenu`).
    //  The old chain's `sendMessageView()` is untouched; in `attachmentAndCommandsButtons()` only `locationButton()` was added, and it shares one sheet and one send path with the new bar.
    //  and so are the quote bar `contextItemView()` and the attachment preview bar `previewView()` - they were above the input bar to begin with.

    /// Three boundaries define the reskin scope, and all of them are **functional** boundaries, not aesthetic ones:
    /// - Only active 1:1 contacts: the Cabin routing recognizes only the contactId of `.direct` (`PopopxRouteTarget`),
    ///   and `PopopxComposerContext` also requires active (`Contact.active`). Groups / channels / contacts awaiting acceptance stay in the old tree.
    /// - Chats with a command menu stay in the old tree: the only entry point for commands is `commandsButton()` in the old tree (the "//" key),
    ///   and `CommandsMenuView` still relies on `selectedRange` to insert a command at the cursor, while `TextField` does not write the cursor back.
    /// - Group @mentions are the same: `GroupMentionsView` uses `selectedRange` for string splicing (`insertMention`),
    ///   so as long as groups stay in the old tree that field remains the truth.
    /// The cadence of live messages, the same value as `liveMsgInterval` in `SendMessageView.swift:13`.
    private static let popopxLiveMsgInterval: UInt64 = 3_000_000_000

    private var popopxBarEligible: Bool {
        chat.chatInfo.contact?.active == true && !chat.chatInfo.useCommands
    }

    /// `ComposeState` → `PopopxComposerContext`. The input bar deliberately does not know `ComposeState`,
    /// so the host must perform this conversion step, and not one of the nine preconditions may be dropped: dropping one is the "silently loses view-once / quote / attachment" class of accident.
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

    /// Whether the send key lights up copies the condition from `SendMessageView.swift:186`-`:192` (the old send key's `.disabled`).
    /// The "draft is not empty" half is judged by the input bar itself (it also allows sending when an attachment is attached; see `PopopxComposerRouting.dispatch`).
    private func popopxSendEnabled(_ disableSendButton: Bool) -> Bool {
        chat.chatInfo.sendMsgEnabled
        && composeState.sendEnabled
        && !composeState.inProgress
        && !(composeState.voicePreview && !chat.chatInfo.featureEnabled(.voice))
        && !composeState.endLiveDisabled
        && !disableSendButton
    }

    /// A service account whose menu this device actually has: an active 1:1 with a stored `menu_config`.
    ///
    /// An eco session without a menu is deliberately not enough. `BotMenuBarView` would then render its unavailable row and spend a
    /// strip of the composer to say nothing the user can act on, and the store is the one place that knows whether a menu exists.
    /// `menus` is read directly for the reason given on `ecoStore`: not through `liveMenu(for:)`, which loads as a side effect.
    @MainActor private var popopxEcoServiceRoom: (contactId: Int64, menu: PopopxEcoMenu)? {
        guard case let .direct(contact) = chat.chatInfo, contact.active else { return nil }
        guard let menu = ecoStore.menus[contact.contactId] else { return nil }
        return (contact.contactId, menu)
    }

    /// The row above the input line: the service account's own menu, or the key that brings it back.
    ///
    /// The collapse half belongs to `BotMenuBarView` — its trailing keyboard key calls `collapse` — so this host supplies only the
    /// expand half, because a folded row has nothing of its own left on screen to carry a button. `PopopxInputBar` is untouched on
    /// purpose: its "+" cell and its pill width ledger serve the keyboard, while a service account's menu is a second row rather
    /// than a third panel competing for the same slot.
    @MainActor @ViewBuilder private var popopxEcoMenuStrip: some View {
        if let room = popopxEcoServiceRoom {
            if popopxEcoMenuFolded {
                Button {
                    PopopxHaptics.impact(.light)
                    popopxEcoMenuFolded = false
                } label: {
                    HStack(spacing: PopopxMetrics.space2XS) {
                        Image(systemName: "line.3.horizontal")
                            .font(PopopxType.sectionHeader)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                        Text(verbatim: PopopxEcoCopy.menuBarLabel)
                            .font(PopopxType.meta)
                            .foregroundStyle(PopopxPalette.labelHint)
                        Spacer(minLength: PopopxMetrics.spaceXS)
                    }
                    .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PopopxPressButtonStyle(feedback: nil))
                .accessibilityLabel(Text(verbatim: PopopxEcoCopy.menuBarLabel))
                .accessibilityIdentifier("popopx.botMenuBar.expand")
            } else {
                BotMenuBarView(
                    menu: room.menu,
                    contactId: room.contactId,
                    // The hop is a `Task` for the same reason the menu bar's own channel fallback hops: `onOpenURL` is a plain
                    // function type, and everything on this side of it is main-actor isolated.
                    onOpenURL: { urlString in
                        let contactId = room.contactId
                        Task { @MainActor in popopxOpenEcoH5(urlString, contactId: contactId) }
                    },
                    collapse: { popopxEcoMenuFolded = true }
                )
            }
        }
    }

    /// The menu's `open_url` path: sign against this contact's pairwise session and hand the page to the launcher. The sheet itself
    /// is mounted once at `MainTabView`'s root rather than here, because this view exists once per open chat and two live mounts
    /// would each try to present the same request. Refusions are logged by the launcher and left unannounced: `.alreadyPresenting`
    /// is a second tap on a page that is already up, and the others mean this device cannot sign at all.
    @MainActor private func popopxOpenEcoH5(_ urlString: String, contactId: Int64) {
        _ = PopopxH5Launcher.shared.open(urlString: urlString, contactId: contactId)
    }

    /// Deliberately a separate function rather than expanded in place: the chat page's `if/else` chain already sits right against Swift type checking's
    /// expression budget (B5 hit `unable to type-check in reasonable time` 5 times in `ChatView` because of it),
    /// and the opaque `some View` return type gives this branch its own budget.
    @ViewBuilder private func popopxComposerBar(disableSendButton: Bool) -> some View {
        let bar = ZStack(alignment: .leading) {
            PopopxInputBar(
                text: $composeState.message,
                context: popopxComposerContext,
                ttlSeconds: popopxTTLSeconds,
                secureTTLSeconds: popopxSecureTTLSeconds,
                isSendEnabled: popopxSendEnabled(disableSendButton),
                // The placeholder copy passes the Key itself (the English source sentence is the Key): the input bar side treats it as
                // a `LocalizedStringKey` and looks it up, so writing Chinese here again would produce a key missing in all 16 languages.
                placeholder: disabledText == nil ? "Message…" : "",
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

    /// The send key's landing point: who owns the send was already decided by `PopopxComposerRouting.dispatch`; here only the two branches' side effects run.
    /// - `.routeViaMesh`: handed to module 5, which decides public network / Bluetooth / fallback queue; the draft is cleared by the input bar itself.
    /// - `.hostShouldSend`: goes through the old chain `sendMessage(ttl:)` as is, with the draft cleared at the end of `sendMessageAsync`;
    ///   view-once is a one-shot send option (the old menu re-picks it on every press), so the tier goes back to nil after sending.
    private func popopxComposerSend(_ send: PopopxComposerSend) {
        if let secureTTL = send.secureTTLSeconds {
            // The top-secret branch does not go through the switch below: `send.dispatch` is **a conclusion computed from the plaintext**,
            // while what actually has to go out is the ciphertext line, and the decision table must receive the bytes that will finally be on the wire.
            // So here the plaintext is handed to the payload layer to be recast (`PopopxSecurePayload.make`), then the channel is decided again against the ciphertext
            // - the same shape as `popopxSendLocation`: that one also carries its own text and recomputes dispatch itself.
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

    /// "Hold to talk" is a single **press-triggers-callback** in the new bar (`PopopxInputBar`'s `holdToTalkBar`),
    /// so it is bridged into tap-to-start / tap-to-end. The `audioRecorder` and `voiceMessageRecordingState`
    /// state machine itself is untouched, and the timing is still pushed by `AudioRecorder.onTimer`.
    private func popopxHoldToTalk() {
        if case .recording = composeState.voiceMessageRecordingState {
            finishVoiceMessageRecording()
        } else {
            Task { await startVoiceMessageRecording() }
        }
    }

    /// The cells the "+" panel can really use in the current chat. The criterion has a single source: `popopxPacketDestination`.
    /// The reason for filtering rather than drawing them and blocking afterwards - see the comment on `PopopxInputBar.plusActions`.
    private var popopxPlusActions: [PopopxPlusAction] {
        PopopxPlusAction.allCases.filter { action in
            switch action {
            case .redPacket: popopxPacketDestination != nil && chat.chatInfo.sendMsgEnabled
            // The gift card's redemption receipt has only one destination, `PopopxCommerceTarget.contact` (the router has no group branch),
            // so this cell appears only in one-to-one chats; in a group, if you want the badge, have the peer copy their code over to the other side, or go straight to Me - Redemption code.
            case .giftCard, .creditsGiftCard: chat.chatInfo.contact != nil && chat.chatInfo.sendMsgEnabled
            case .photo, .camera, .file, .location, .secure, .personalProfile: true
            }
        }
    }

    /// Red packet destination: **1:1 one-to-one chats only**. The criterion has a single source, and the cell in `popopxPlusActions` filters by it.
    ///
    /// Ruling record (2026-11-19): no red packets in groups. One red packet in a group gets "opened" separately by N people,
    /// and this layer has no server-side ledger - de-duplication exists only in **each device's own** transaction log
    /// (`PopopxCreditsManager.claimRedPacket` keeps one copy per packetId, `recordClaim` books per member),
    /// so with concurrent opens more can land at worst. A one-to-one chat has no such shape: only one device can open it, and the receipt only returns its own copy.
    /// Channels, private notes, connecting and requests - these four kinds of chat also return nil (the last three have no counterpart person at all).
    private var popopxPacketDestination: PopopxPacketDestination? {
        if let contact = chat.chatInfo.contact {
            return .contact(id: contact.contactId, name: contact.displayName)
        }
        return nil
    }

    /// Each cell of the "+" panel wires back into an existing chain: album / camera / file are the three switches `showMediaPicker` / `showTakePhoto` /
    /// `showFileImporter`; location and personal profile each open a confirmation Sheet, and the top-secret cell only flips the arm switch.
    /// The disable condition copies `attachmentButton()`: no opening when there is already an attachment or during edit / forward / live / report, and the same notice is given when this chat forbids files.
    /// Red packet and gift card are the last two branches: they do not share that gate - the cells themselves appear only in chats that have a destination (`popopxPlusActions`),
    /// so the `guard` in those two places is slack kept for "the chat changed between filtering the cells and the press": better not to send than to send a red packet into a chat with no destination.
    private func popopxPlusAction(_ action: PopopxPlusAction) {
        switch action {
        case .location:
            // Location is not one chain with album / camera / file: on the wire it is just one plain text line, so the group's "disable files and media"
            // restriction should not block it; but an edit / forward / live / report draft, or one with an attachment attached, would make this standalone message and the draft
            // say different things (what goes out is the location, what stays in the box is still the draft), so it reuses the ready-made gate from the old chain.
            if composeState.attachmentDisabled {
                AlertManager.shared.showAlertMsg(
                    title: "Cannot send a location right now",
                    message: "A location message cannot be added while the draft is being rewritten, forwarded, recorded as a live message or already has an attachment."
                )
            } else if !chat.chatInfo.sendMsgEnabled {
                AlertManager.shared.showAlertMsg(title: "Chat not ready", message: "This chat does not allow sending messages right now.")
            } else {
                showLocationPicker = true
            }
        case .personalProfile:
            // The same gate as `.location`: on the wire a profile is first one index text line, and the media originals each become their own lines afterwards,
            // so the "disable files and media in groups" restriction (the `.photo/.camera/.file` branch) should not block it -
            // but an edit / forward / live / report draft, or one with an attachment attached, would make the profile and the draft say different things, so it is still blocked.
            if composeState.attachmentDisabled {
                AlertManager.shared.showAlertMsg(
                    title: "Cannot send your profile right now",
                    message: "A separate profile card cannot be sent while the draft is being rewritten, forwarded, recorded as a live message or already has an attachment."
                )
            } else if !chat.chatInfo.sendMsgEnabled {
                AlertManager.shared.showAlertMsg(title: "Chat not ready", message: "This chat does not allow sending messages right now.")
            } else {
                showProfileSendSheet = true
            }
        case .secure:
            // The cell in the "+" panel is an **arm switch**, not a picker: it only flips the host's truth cell, and the input bar keeps no copy.
            // The refusal here just says it in human words up front; the real gate is inside `popopxSendSecure`,
            // because the checkbox on that panel writes through another path, and blocking it here would not hold.
            if composeState.attachmentDisabled {
                AlertManager.shared.showAlertMsg(
                    title: "Cannot send a secure message right now",
                    message: "This draft cannot be marked secure while it is being rewritten, forwarded, recorded as a live message or already has an attachment."
                )
            } else if !chat.chatInfo.sendMsgEnabled {
                AlertManager.shared.showAlertMsg(title: "Chat not ready", message: "This chat does not allow sending messages right now.")
            } else {
                PopopxHaptics.impact(.light)
                popopxSecureTTLSeconds = popopxSecureTTLSeconds == nil
                    ? PopopxSecureCopy.defaultTTLSeconds
                    : nil
            }
        case .redPacket:
            // The panel already filtered this cell per chat (`popopxPlusActions`), so reaching here means the destination must exist;
            // this branch only backs the extremely narrow window of "the chat turned into one that cannot send messages while the panel was open" - better not to send than to send into a chat with no destination.
            guard let destination = popopxPacketDestination else { return }
            packetDestination = destination
            showRedPacketSheet = true
        case .giftCard:
            guard let contactId = chat.chatInfo.contact?.contactId else { return }
            giftCardContactId = contactId
            showGiftCardSheet = true
        case .creditsGiftCard:
            // Same snapshot rule as the badge card above: the credits page opens on its gift segment, and the card face it presents
            // decides whether to draw "send in this conversation" from this id alone.
            guard let contactId = chat.chatInfo.contact?.contactId else { return }
            giftCardContactId = contactId
            showCreditsGiftSheet = true
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
                // These cells are unreachable in the `.photo/.camera/.file` branch: the outer switch has already split them off.
                // Writing `break` instead of deleting them keeps this switch exhaustive - when a new cell is added
                // this fails to compile, which reminds you that both places need changing.
                case .location, .secure, .personalProfile, .redPacket, .giftCard, .creditsGiftCard: break
                }
            }
        }
    }

    /// The destination of "Send location". On the wire a location is just one plain text line, so it shares **the same decision table** with ordinary text in the input bar
    /// (`PopopxComposerRouting.dispatch`): already bound + radio on + a neighbour reachable means hand it to module 5, otherwise it goes back to the host's SMP.
    /// So the decision table needs no new cell for location - what it judges is "does this message carry anything the routing cannot carry", and location has none of that.
    ///
    /// Deliberately bypasses `sendMessageAsync`: that chain sends the draft along with it (the six branches of `composeState.preview`) and at the end also
    /// calls `clearState`, wiping the user's unfinished draft and link preview. A location is a standalone message, so the draft should stay exactly as it is.
    ///
    /// Likewise it does not enter `checkComposeLinksAsync`: `popopx://loc` and one-time invite links share the same scheme,
    /// and being treated as a connection link would turn a location message into adding a friend (`PopopxLocation.swift:17`-`:21`).
    @MainActor private func popopxSendLocation(_ payload: PopopxLocationPayload) async {
        let contactId = chat.chatInfo.contact?.contactId
        // This message's only precondition is "a direct chat contact": the attachment, quote, @mention and live hanging in the draft do not belong to it,
        // and counting them in would make an already-picked location bypass Bluetooth just because the box holds an image. View-once is a real tier and still takes part in the decision.
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
            // The tier is one-shot as in the old chain: it goes back to nil after sending, and the next message returns to "not view-once".
            let ttl = popopxTTLSeconds
            popopxTTLSeconds = nil
            await popopxSendPlainViaSMP(payload.messageContent, ttl: ttl)
        case .ignoreEmptyDraft:
            break
        }
    }

    /// The destination of "Send personal profile". Unlike the two branches above, this one **does not decide the channel in this file**: one profile simultaneously drags along one
    /// index text line and N media originals, the originals can never go over Bluetooth (the decision table's `.richContent`), and downgrading to plain text is a product
    /// requirement too - the ordering of the two things (the index lands on the public network first, the originals queue behind, and offline the whole thing goes through a Cabin projection) belongs to the sender,
    /// and putting it here would make `ComposeView` a second source of truth. So this function only does three things: hand it over, tell the user the conclusion,
    /// and clear that live dummy (the criterion copies `popopxSendPlainViaSMP`, only after genuine public-network delivery).
    ///
    /// It likewise does not enter `checkComposeLinksAsync` and does not go through `sendMessageAsync`: both reasons are exactly the same as the location one's
    /// (`popopx://profile` shares its scheme with one-time invite links; the draft must stay in the box untouched).
    @MainActor private func popopxSendProfile(_ manifest: PopopxProfileManifest) async {
        let outcome = await ProfileAutoSender.shared.send(manifest, to: chat)
        switch outcome {
        case let .sentFullMedia(indexSent, mediaQueued):
            if indexSent { chatModel.removeLiveDummy(animated: false) }
            logger.notice("POPOPX profile: manual local send went over the public network (\(mediaQueued, privacy: .public) media items queued)")
        case let .sentMeshTextOnly(omitted):
            logger.notice("POPOPX profile: manual local send went over the offline mesh as text only (\(omitted, privacy: .public) media items omitted)")
        case let .refused(refusal):
            PopopxHaptics.notice(.warning)
            AlertManager.shared.showAlertMsg(
                title: "Cannot send your profile",
                // Interpolation rather than passing it directly: `showAlertMsg` takes a `LocalizedStringKey` (ContentView.swift:559),
                // so a refusal reason only computed at runtime can only land through interpolation.
                message: "\(refusal.explanation ?? refusal.description)"
            )
        case let .failed(reason):
            PopopxHaptics.notice(.error)
            AlertManager.shared.showAlertMsg(title: "Sending failed", message: "\(reason)")
        }
    }

    /// The branch back to the host copies the nested `send(_ msgs:)` inside `sendMessageAsync`: `apiSendMessages` +
    /// `removeLiveDummy` + `addChatItem`, not one more - neither location nor top-secret has a file to reclaim, and the failure notice is also
    /// popped by `apiSendMessages` on its own side (`POPOPXAPI.swift:640`), so no second layer is stacked here.
    ///
    /// The name changed from `...LocationViaSMP` to `...PlainViaSMP`: this chain is responsible for "one plain text line on the wire",
    /// location is its first user and the top-secret payload is the second (those two text lines are completely isomorphic in shape, see
    /// `PopopxSecurePayload.swift:9`-`:14`). Keeping the Location name would make the next person copy it all over again.
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

    /// The destination of "Send top-secret message". Minting the payload comes **before any decision**: the decision table, SMP and the Bluetooth relay queue all receive
    /// nothing but the ciphertext line (`payload.messageContent`). Letting plaintext pass through any one of those stations means "never expose plaintext in the list"
    /// is already broken on the send side.
    ///
    /// As with location it **does not go through** `sendMessageAsync`: that chain would send the draft out together with the link preview and the quote,
    /// and also `clearState` at the end; and `popopx://sec` shares its scheme with one-time invite links, so entering
    /// `checkComposeLinksAsync` means adding a friend by mistake (`PopopxSecurePayload.swift:37`-`:41`).
    ///
    /// But top-secret **must** differ from location in one place: location's content comes from the map picker, while top-secret's plaintext sits right in the input box,
    /// so it must be cleared once the send succeeds - see `popopxAfterSecureSend()`.
    @MainActor private func popopxSendSecure(
        plaintext: String,
        smpTTLSeconds: Int?,
        secureTTLSeconds: Int
    ) async {
        // The gate is here, not in the "+" panel cell: the checkbox on that panel writes through another path,
        // and blocking only the button would leave the silent failure of "can arm, cannot send, and no reason given".
        guard !composeState.attachmentDisabled else {
            popopxSecureBlocked()
            return
        }
        guard chat.chatInfo.sendMsgEnabled else {
            AlertManager.shared.showAlertMsg(title: "Chat not ready", message: "This chat does not allow sending messages right now.")
            return
        }
        let payload: PopopxSecurePayload
        do {
            payload = try PopopxSecurePayload.make(plaintext: plaintext, ttlSeconds: secureTTLSeconds)
        } catch let error as PopopxSecureError {
            // This sentence goes through `Text(verbatim:)` instead of `showAlertMsg`: the latter's parameter is a `LocalizedStringKey`
            // (ContentView.swift:559), a String assembled at runtime simply cannot convert, and it carries a byte count, so
            // treating it as a format string to look up the localization table hands the wording over to luck.
            AlertManager.shared.showAlert(
                Alert(title: Text(NSLocalizedString("Secure message not sent", comment: "")),
                      message: Text(verbatim: Self.popopxSecureSendReason(error)))
            )
            return
        } catch {
            AlertManager.shared.showAlertMsg(
                title: "Secure message not sent",
                message: "Sealing failed on this device; not one byte of this content left it."
            )
            return
        }

        let contactId = chat.chatInfo.contact?.contactId
        // The same judgement as the location one: this message's only precondition is "a direct chat contact", and the attachment/quote/live hanging in the box do not belong to it.
        // View-once (the SMP tier) is a real tier and still takes part in the decision.
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
            // The draft is cleared only when it really went out: when `apiSendMessages` returns nil it has already popped its own notice,
            // and clearing the plaintext then would make the user lose a message for nothing.
            if await popopxSendPlainViaSMP(payload.messageContent, ttl: smpTTLSeconds) {
                popopxAfterSecureSend()
            }
        case .ignoreEmptyDraft:
            break
        }
    }

    /// The wrap-up after a successful top-secret send. The three things each have their own reason:
    /// 1. **Clear the draft**: the plaintext the user typed is still in `composeState.message`, and not clearing it means this message
    ///    stays on the sender's own screen permanently - the only "send side" plaintext residue in the whole feature.
    /// 2. **Turn off the link preview**: `composeState.preview` is the plaintext's second way of being stored (it copies exactly this draft's text).
    /// 3. **Both tiers back to nil**: top-secret and view-once are both "one send, one choice", the same semantics as the old send key menu;
    ///    leaving a tier set would make the next ordinary message be mislabelled as top-secret, and that is worse than the other way round.
    private func popopxAfterSecureSend() {
        composeState.message = ""
        resetLinkPreview()
        popopxSecureTTLSeconds = nil
        popopxTTLSeconds = nil
    }

    private func popopxSecureBlocked() {
        AlertManager.shared.showAlertMsg(
            title: "Cannot send a secure message right now",
            message: "This draft cannot be marked secure while it is being rewritten, forwarded, recorded as a live message or already has an attachment."
        )
    }

    /// Turns payload-layer errors into a human sentence. This only maps, it adds no new judgement: the length-limit number is taken from the contract side,
    /// so that this notice and `maximumPlainBytes` do not grow into two versions.
    private static func popopxSecureSendReason(_ error: PopopxSecureError) -> String {
        switch error {
        case .emptyPlaintext:
            return NSLocalizedString("The content is empty.", comment: "")
        case let .plaintextTooLong(bytes):
            return String(format: NSLocalizedString("Secure messages are at most %1$lld KiB; this one is %2$lld bytes.", comment: ""), PopopxSecurePayload.maximumPlainBytes / 1024, bytes)
        case .sealingFailed:
            return NSLocalizedString("Sealing failed on this device; not one byte of this content left it.", comment: "")
        case .unusablePlaintext, .wrongKeyLength, .wrongSealedLength, .decryptionFailed:
            // These three can only appear when the receiving side can decode them, and the send side never reaches them; they are written out to keep this switch exhaustive,
            // and so that if someone later calls `open()` on this path, it will not fall into the vague `default` sentence.
            return NSLocalizedString("The payload was not usable, so nothing was sent.", comment: "")
        case .authenticationFailed, .biometricsUnavailable, .screenIsCaptured:
            return NSLocalizedString("This device does not allow opening secure messages right now.", comment: "")
        }
    }

    /// In the old chain the live message entry grew only on the send key's long-press menu (`SendMessageView.swift:194`-`:241`),
    /// and the new bar has no send key to hang a menu on, so the whole composer attaches that same menu, whose content is only this one item:
    /// view-once belongs to the "+" panel, the signing branch was commented out upstream, and it belongs only to groups / channels, so it is outside the reskin scope.
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

    /// The same chain as `SendMessageView.startLiveMessage`: send one live message first, then `updateLiveMessage` on the same cadence.
    /// The cadence constant `liveMsgInterval` is a file-level `private let` in `SendMessageView.swift:13`, so it cannot be imported,
    /// and the same 3 seconds is hard-coded here; the pop-once-only reminder uses that same UserDefaults key, it is not a second switch.
    /// The old key's pulse animation (`sendButtonSize` / `sendButtonOpacity`) is the old send key's own skin and does not come along.
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

    /// Member count for the large-group flow control: the members held by the
    /// model plus this device's own membership. A chat that is not a group has no
    /// member set, so strict mode never applies to it.
    private var popopxAttachmentMemberCount: Int {
        guard chat.chatInfo.groupInfo != nil else { return 0 }
        return chatModel.groupMembers.count + 1
    }

    /// Rewrites the attachment branches that carry a file URL to the local copy the engine produced,
    /// before the core is asked to encrypt anything. An image that exists only as a `UIImage` keeps its
    /// existing path, and an engine failure leaves the attachment untouched rather than dropping the
    /// send. The results prepared at pick time are reused, not recomputed.
    private func popopxCompressedUploads(_ items: [(String, UploadContent?)]) async -> [(String, UploadContent?)] {
        let memberCount = popopxAttachmentMemberCount
        var prepared: [(String, UploadContent?)] = []
        prepared.reserveCapacity(items.count)
        for item in items {
            guard let content = item.1 else {
                prepared.append(item)
                continue
            }
            switch content {
            case let .imageFile(image, url):
                let result = await popopxPreparedAttachment(url, memberCount: memberCount)
                prepared.append((item.0, .imageFile(image: image, url: result.url)))
            case let .video(image, url, duration):
                let result = await popopxPreparedAttachment(url, memberCount: memberCount)
                prepared.append((item.0, .video(image: image, url: result.url, duration: duration)))
            default:
                prepared.append(item)
            }
        }
        return prepared
    }

    /// The file a picked item carries, for the two kinds the engine can rewrite. A `UIImage`-only
    /// attachment has no file to hand over, and an animated GIF is excluded by the engine itself.
    private func popopxAttachmentURL(_ content: UploadContent) -> URL? {
        switch content {
        case let .imageFile(_, url): url
        case let .video(_, url, _): url
        default: nil
        }
    }

    /// Cache first. The engine already ran over this file when it was picked; running it again would
    /// create a second plaintext copy and let the badge describe a different file from the one sent. A
    /// miss — a draft restored from disk — prepares it here and records the result.
    private func popopxPreparedAttachment(_ url: URL, memberCount: Int) async -> PopopxOutgoingAttachment {
        if let cached = popopxPreparedMedia[url] { return cached }
        let prepared = await popopxMediaInterceptor.prepareOne(url, groupMemberCount: memberCount)
        await MainActor.run { popopxPreparedMedia[url] = prepared }
        return prepared
    }

    /// The caption under the preview. Items the engine has not finished with contribute nothing, so the
    /// row is never ahead of the truth; the processing capsule already covers that moment.
    private func popopxMediaStatus(for content: UploadContent) -> PopopxMediaStatus? {
        switch content {
        case .simpleImage:
            // No file to compress, but `mediaContent` below encodes the image through ImageIO on the
            // way out, which discards the metadata dictionaries.
            .reencoded
        case .animatedImage:
            PopopxMediaStatusResolver.resolve(kind: .animatedImage, engineRan: false, compressed: false, blocked: false)
        case let .imageFile(_, url), let .video(_, url, _):
            popopxPreparedMedia[url]?.popopxStatus
        }
    }

    private func popopxMediaStatus(file url: URL) -> PopopxMediaStatus? {
        popopxPreparedMedia[url]?.popopxStatus
    }

    /// One pill when the batch shares an outcome — four identical pills would read as decoration, not
    /// as evidence — and one per item when it does not, in the order the thumbnails are drawn.
    @ViewBuilder private func popopxMediaStatusRow(_ contents: [UploadContent]) -> some View {
        let statuses = contents.compactMap { popopxMediaStatus(for: $0) }
        if let only = statuses.first, Set(statuses).count == 1 {
            PopopxMediaStatusBadge(status: only)
                .padding(.horizontal, PopopxMetrics.gutter)
                .padding(.bottom, PopopxMetrics.space2XS)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if statuses.count > 1 {
            HStack(spacing: PopopxMetrics.space2XS) {
                ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                    PopopxMediaStatusBadge(status: status)
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.space2XS)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A refusal, if this batch holds one. The composer treats `blocked` as a stop, never as a warning.
    private func popopxBlockedAttachment(in contents: [UploadContent]) -> PopopxOutgoingAttachment? {
        for content in contents {
            guard let url = popopxAttachmentURL(content), let prepared = popopxPreparedMedia[url], prepared.blocked
            else { continue }
            return prepared
        }
        return nil
    }

    /// The engine's copies live in the temporary media directory. Anything prepared and then taken back
    /// by the user is deleted here, because a plaintext duplicate of a file the sender rejected should
    /// not wait for the next panic wipe or the next purge to disappear.
    private func popopxDropPreparedMedia(replacing next: [URL: PopopxOutgoingAttachment]) {
        guard !composeState.inProgress else { return }
        let kept = Set(next.values.map(\.url))
        for attachment in popopxPreparedMedia.values where attachment.compressed && !kept.contains(attachment.url) {
            removeFile(attachment.url)
        }
    }

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
                    popopxDropPreparedMedia(replacing: [:])
                    popopxPreparedMedia = [:]
                },
                cancelEnabled: !composeState.editing && !composeState.inProgress)
            popopxMediaStatusRow(media.compactMap { $0.1 })
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
        case let .filePreview(fileName, file):
            ComposeFileView(
                fileName: fileName,
                cancelFile: {
                    composeState = composeState.copy(preview: .noPreview)
                    popopxDropPreparedMedia(replacing: [:])
                    popopxPreparedMedia = [:]
                },
                cancelEnabled: !composeState.editing && !composeState.inProgress)
            if let status = popopxMediaStatus(file: file) {
                PopopxMediaStatusBadge(status: status)
                    .padding(.horizontal, PopopxMetrics.gutter)
                    .padding(.bottom, PopopxMetrics.space2XS)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                // Every attachment is compressed before the first send is issued, so
                // a batch does not start going out while a later item is still being
                // shrunk. The engine hands back the source URL when it cannot help.
                let uploads = await popopxCompressedUploads(media)
                if popopxBlockedAttachment(in: media.compactMap { $0.1 }) != nil {
                    // The large-group ceiling refuses part of the batch, so the whole message stops: a
                    // half-sent album is the one outcome the composer must not produce, and the text and
                    // the picked media stay in place, exactly as they do for a refused file.
                    await MainActor.run {
                        composeState.inProgress = false
                        showAlert(NSLocalizedString("Large file!", comment: "file alert title"),
                                  message: PopopxOutgoingMediaInterceptor.shared.blockedMessage)
                    }
                    return nil
                }
                let last = uploads.count - 1
                var msgs: [ComposedMessage] = []
                if last >= 0 {
                    for i in 0..<last {
                        if i > 0 {
                            // Sleep to allow `progressByTimeout` update be rendered
                            try? await Task.sleep(nanoseconds: 100_000000)
                        }
                        if let (fileSource, msgContent) = mediaContent(uploads[i], text: "") {
                            msgs.append(ComposedMessage(fileSource: fileSource, msgContent: msgContent))
                        }
                    }
                    if let (fileSource, msgContent) = mediaContent(uploads[last], text: msgText) {
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
                let prepared = await popopxPreparedAttachment(file, memberCount: popopxAttachmentMemberCount)
                if prepared.blocked {
                    // Nothing is sent, so the composer must not be cleared: only the
                    // in-progress flag set by `sending()` is released, which leaves the
                    // text and the picked file in place for another route.
                    await MainActor.run {
                        composeState.inProgress = false
                        showAlert(NSLocalizedString("Large file!", comment: "file alert title"),
                                  message: PopopxOutgoingMediaInterceptor.shared.blockedMessage)
                    }
                    return nil
                }
                if let savedFile = saveFileFromURL(prepared.url) {
                    sent = await send(.file(msgText), quoted: quoted, file: savedFile, live: live, ttl: ttl, mentions: mentions, sign: sign)
                    // `saveFileFromURL` copies into the app's own file store, so the engine's plaintext
                    // intermediate has no reason to outlive this call. A refused or untouched file keeps
                    // its URL — that one is the user's, and the existing cleanup owns it.
                    if prepared.compressed { removeFile(prepared.url) }
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
        popopxPreparedMedia = [:]
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
