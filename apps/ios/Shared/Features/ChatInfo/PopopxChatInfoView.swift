//
//  PopopxChatInfoView.swift
//  POPOPX (iOS)
//
//  [phase five] The 1:1 contact conversation info page rewrite, replacing Shared/Views/Chat/ChatInfoView.swift:94.
//  Mounting method: changing `ChatInfoView(` at Shared/Views/Chat/ChatView.swift:481 into
//  `PopopxChatInfoView(` is enough —— the six external parameter labels, their types and their order are character-identical to the old page,
//  （chat / contact / localAlias / featuresAllowed / currentFeaturesAllowed / onSearch），
//  and the environment dependencies are declared as before: ChatModel, AppTheme, \.dismiss.
//
//  The AppTheme line keeps only the declaration and reads none of its colours (ruling B: colours come only from PopopxTheme):
//  the old destinations this page pushes to each have their own `@EnvironmentObject var theme: AppTheme`
//  （VerifyCodeView.swift:14、ContactPreferencesView.swift:17、ChatInfoView.swift:931、
//  (ChatInfoView.swift:1291), the environment is injected at the root (Shared/POPOPXApp.swift:44) and flows down automatically,
//  and keeping the declaration is only so that this input surface stays exactly the same shape as the old page.
//
//  Layout: one contact card at the top (avatar + verification shield + name/full name + popopx name + bio + connection state +
//  a local note-name field), and below it in a ScrollView six groups of PopopxSectionCard: connection and security / chat /
//  auto-delete / addresses / server / dangerous operations. The old page was a List + 8 sections; here it becomes the same family of card-scroll layout
//  as the new brand's other pages (PopopxMeView, PopopxContactsView).
//
//  Every piece of data comes from existing functions, and this page writes no second path:
//  · on entering the page three facts are read once —— apiContactInfo (Shared/Model/POPOPXAPI.swift:947) gives
//    the ConnectionStats and the random identity this connection uses, apiGetContactCode (:1013) gives the verification code and the latest
//    Contact; where the two facts disagree the latter is written back into chat.chatInfo.
//  · note name apiSetContactAlias (:1448), preferences apiSetContactPrefs (:1442), verification code
//    apiVerifyContact (:1025), switch / abort switching the receiving address apiSwitchContact (:977) /
//    apiAbortSwitchContact (:989), clear history clearChat (:1363), muting and receipts
//    toggleNotifications / updateChatSettings（Shared/Views/Chat/ChatView.swift:3366 / :3373）；
//  · repairing the connection goes through syncContactConnection (Shared/Views/Chat/ChatInfoView.swift:726),
//    deleting a contact goes through deleteContactDialog (:1139, two-step confirmation, the second step being DeleteActiveContactDialog :1289);
//  · subscription state only reads ChatModel.chatSubStatus (Shared/Model/ChatModel.swift:413), and server addresses read
//    the rcv/sndQueuesInfo of ConnectionStats (POPOPXChat/APITypes.swift:568), host names go through
//    serverHost（Shared/Views/Chat/ChatInfoView.swift:54）；
//  · the avatar and bio reuse ProfileImage (Shared/Views/Helpers/ProfileImage.swift:13),
//    NameWithBadge (Shared/Views/Helpers/NameBadge.swift:23), contactPopopxNameView and
//    ProfileDescriptionView（Shared/Views/Chat/ChatItem/MsgContentView.swift:382）。
//
//  Colour discipline (§1.1): this page speaks only of online SMP channels, and indigo-violet is "online encrypted", so no teal appears anywhere on the page;
//  green carries no standing state (§1.4 item 4), so "connected" uses brand and errors use dangerInk.
//  Destructive rows (clear history / delete contact) always use a dangerInk title + a danger badge, and each keeps its real confirmation:
//  clear = a second Alert confirmation; delete = an ActionSheet + a second form page, and not one step is silent.
//  Signature detail (§2.4 one per screen): the verification shield at the avatar's bottom-right corner only appears when contact.verified is true,
//  a solid brand fill + ink onBrand (§1.4 item 1), with a ring of card-coloured stroke that peels it out of the photo; static, no animation.
//
//  The old rows that were not brought over (all of them debug branches behind the developer tools gate, itemised in the delivery notes):
//  the whole "For console" block (old :274-293, including Local name / Database ID / Debug delivery),
//  force re-negotiating encryption (old :532-539 with its alert branches :335-343 and :1114-1121),
//  the queue debug info (old :281-291 and :1123-1137), and one dead state declared but never read or written,
//  showConnectContactViaAddressDialog (old :111).
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand —— the iron rule forbids scripts from touching project.pbxproj.
//

import Foundation
import SwiftUI
import UIKit
import POPOPXChat

// MARK: - In-page prompts

/// The five things this page can pop up. The delete-contact path requires `SomeAlert`, so it is taken in unchanged as one of its branches.
private enum PopopxChatInfoAlert: Identifiable {
    case clearChat
    case networkStatus(SubscriptionStatus)
    case switchAddress
    case abortSwitchAddress
    case someAlert(SomeAlert)

    var id: String {
        switch self {
        case .clearChat: return "popopxChatInfo.clearChat"
        case let .networkStatus(status): return "popopxChatInfo.networkStatus \(status)"
        case .switchAddress: return "popopxChatInfo.switchAddress"
        case .abortSwitchAddress: return "popopxChatInfo.abortSwitchAddress"
        case let .someAlert(alert): return "popopxChatInfo.someAlert \(alert.id)"
        }
    }
}

// MARK: - Page

@MainActor
struct PopopxChatInfoView: View {
    // MARK: Input surface (same shape as ChatInfoView, one word is enough to mount)

    @EnvironmentObject var chatModel: ChatModel
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss: DismissAction
    @ObservedObject var chat: Chat
    @State var contact: Contact
    @State var localAlias: String
    @State var featuresAllowed: ContactFeaturesAllowed
    @State var currentFeaturesAllowed: ContactFeaturesAllowed
    var onSearch: () -> Void

    // MARK: This page's own state

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var connectionStats: ConnectionStats? = nil
    @State private var customUserProfile: Profile? = nil
    @State private var connectionCode: String? = nil
    @State private var alert: PopopxChatInfoAlert? = nil
    @State private var actionSheet: SomeActionSheet? = nil
    @State private var sheet: SomeSheet<AnyView>? = nil
    @State private var sendReceipts = SendReceipts.userDefault(true)
    @State private var sendReceiptsUserDefault = true
    @State private var progressIndicator = false
    @State private var toast = PopopxToastModel()
    @FocusState private var aliasFocused: Bool

    /// The avatar side length takes one step on the 4pt grid: space2XL × 2 = 96.
    private static let avatarSide: CGFloat = PopopxMetrics.space2XL * 2

    /// These rows can only talk about taking effect when the connection is usable (the same gate as old page :207).
    private var connectionUsable: Bool { contact.ready && contact.active }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    headerCard
                    quickActionsCard
                    securityCard
                    chatCard
                    ttlCard
                    if let contactLink = contact.contactLink {
                        addressCard(contactLink)
                    }
                    if contact.ready && contact.active {
                        serversCard
                    }
                    dangerCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, PopopxMetrics.spaceS)
                .padding(.bottom, PopopxMetrics.space2XL)
            }
            .background(PopopxPalette.base)
            .popopxAnimation(PopopxSpring.snappy, value: progressIndicator, reduceMotion: reduceMotion)
            .opacity(progressIndicator ? 0.6 : 1)
            .disabled(progressIndicator)
            .overlay(alignment: .center) {
                if progressIndicator {
                    ProgressView()
                        .controlSize(.large)
                        .tint(PopopxPalette.brand)
                        .padding(PopopxMetrics.spaceM)
                        .background(PopopxMaterial.bar, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
                        .accessibilityLabel(Text(verbatim: Copy.working))
                }
            }
            .navigationTitle(Copy.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.close) { dismiss() }
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.brand)
                }
            }
        }
        .onAppear {
            loadContactInfo()
        }
        .alert(item: $alert) { item in
            switch item {
            case .clearChat: return clearChatAlert()
            case let .networkStatus(status): return networkStatusAlert(status)
            case .switchAddress: return switchAddressAlert(switchContactAddress)
            case .abortSwitchAddress: return abortSwitchAddressAlert(abortSwitchContactAddress)
            case let .someAlert(a): return a.alert
            }
        }
        .actionSheet(item: $actionSheet) { $0.actionSheet }
        .sheet(item: $sheet) { someSheet in
            someSheet.content
                .presentationDetents([.fraction(someSheet.fraction)])
        }
        .onDisappear {
            if currentFeaturesAllowed != featuresAllowed {
                showAlert(
                    title: Copy.savePrefsTitle,
                    message: Copy.savePrefsMessage,
                    buttonTitle: Copy.savePrefsButton,
                    buttonAction: { saveContactPreferences() },
                    cancelButton: true
                )
            }
        }
        .popopxToast(toast)
    }

    // MARK: Top contact card

    private var headerCard: some View {
        PopopxSectionCard {
            VStack(spacing: PopopxMetrics.spaceS) {
                avatar
                nameBlock
                ProfileDescriptionView(
                    shortDescr: chat.chatInfo.shortDescr,
                    description: chat.chatInfo.profileDescription
                )
                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, PopopxMetrics.spaceXS)

            PopopxChatInfoDivider()
            aliasField
        }
    }

    /// The avatar. With base64 it goes through the existing `ProfileImage`, without it falls back to the brand mark; the verification shield is attached outside the has-image case only
    /// and it always hangs at the bottom-right corner, because what it speaks of is the connection, not the photo.
    private var avatar: some View {
        PopopxChatInfoAvatar(image: chat.chatInfo.image, side: Self.avatarSide)
            .overlay(alignment: .bottomTrailing) {
                if contact.verified {
                    verifiedChip
                }
            }
    }

    private var verifiedChip: some View {
        Image(systemName: "checkmark.shield.fill")
            .font(PopopxType.microTag)
            .imageScale(.medium)
            .foregroundStyle(PopopxIconTint.brand.ink)
            .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
            .background(PopopxIconTint.brand.fill, in: Circle())
            .overlay(Circle().strokeBorder(PopopxPalette.card, lineWidth: PopopxMetrics.divider))
            .padding(PopopxMetrics.space2XS)
            .accessibilityLabel(Text(verbatim: Copy.verifiedShieldHint))
    }

    private var nameBlock: some View {
        let badge = chat.chatInfo.nameBadge
        let shownName = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: PopopxMetrics.space2XS) {
            NameWithBadge(
                Text(shownName)
                    .font(PopopxType.title)
                    .foregroundStyle(PopopxPalette.label),
                badge,
                .title2
            ) {
                if let badge {
                    showBadgeInfoAlert(shownName, badge)
                }
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)

            if showsFullName {
                Text(chat.chatInfo.fullName)
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            contactPopopxNameView(contact) { contact = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var showsFullName: Bool {
        let fullName = chat.chatInfo.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !fullName.isEmpty
            && fullName != contact.displayName
            && fullName != contact.profile.displayName
    }

    /// The connection state. The wording only states facts this Contact genuinely has: `ready`/`sndReady` come from activeConn's
    /// connStatus (POPOPXChat/ChatTypes.swift:2657-2660), failure comes from connFailedErr (:2813).
    private var statusLine: some View {
        let state = connectionState
        return HStack(spacing: PopopxMetrics.space2XS) {
            Circle()
                .fill(state.dot)
                .frame(width: PopopxMetrics.space2XS, height: PopopxMetrics.space2XS)
            Text(state.words)
                .font(PopopxType.microTag)
                .foregroundStyle(state.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private var connectionState: (words: String, ink: Color, dot: Color) {
        if !contact.active {
            return (Copy.stateDeleted, PopopxPalette.dangerInk, PopopxPalette.dangerFill)
        }
        if contact.activeConn?.connFailedErr != nil {
            return (Copy.stateFailed, PopopxPalette.dangerInk, PopopxPalette.danger)
        }
        if contact.ready {
            return (Copy.stateReady, PopopxPalette.brand, PopopxPalette.brand)
        }
        if contact.sndReady {
            return (Copy.stateSndReady, PopopxPalette.brand, PopopxPalette.brand)
        }
        if contact.activeConn == nil {
            return (Copy.stateNoConnection, PopopxPalette.labelSecondary, PopopxPalette.labelHint)
        }
        return (Copy.stateConnecting, PopopxPalette.labelSecondary, PopopxPalette.labelHint)
    }

    /// The local note name. Written back as soon as focus is lost, the same store timing as old page :408-415 (no focus change, no request sent).
    private var aliasField: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "pencil")
                .font(PopopxType.body)
                .foregroundStyle(aliasFocused ? PopopxPalette.brand : PopopxPalette.labelSecondary)
                .frame(width: PopopxMetrics.spaceXL)
                .accessibilityHidden(true)
            TextField(Copy.aliasPrompt, text: $localAlias)
                .font(PopopxType.body)
                .foregroundStyle(PopopxPalette.label)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .disableAutocorrection(true)
                .focused($aliasFocused)
                .onSubmit {
                    setContactAlias()
                }
        }
        .padding(.horizontal, PopopxMetrics.spaceS)
        .frame(minHeight: PopopxMetrics.minHitTarget)
        .background(PopopxPalette.base, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                .strokeBorder(
                    aliasFocused ? PopopxPalette.brand : PopopxPalette.labelHint,
                    lineWidth: aliasFocused ? PopopxMetrics.stroke : PopopxMetrics.divider
                )
        )
        .onChange(of: aliasFocused) { _, focused in
            if !focused {
                setContactAlias()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: Copy.aliasLabel))
    }

    // MARK: Quick actions

    private var quickActionsCard: some View {
        PopopxSectionCard {
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxChatInfoTile(
                    title: Copy.search,
                    systemImage: "magnifyingglass",
                    tint: .brand,
                    enabled: contact.ready && !chat.chatItems.isEmpty
                ) {
                    dismiss()
                    onSearch()
                }

                PopopxChatInfoCallTile(
                    chat: chat,
                    contact: contact,
                    connectionStats: $connectionStats,
                    media: .audio,
                    showAlert: { alert = .someAlert($0) }
                )

                PopopxChatInfoCallTile(
                    chat: chat,
                    contact: contact,
                    connectionStats: $connectionStats,
                    media: .video,
                    showAlert: { alert = .someAlert($0) }
                )

                if let nextNtfMode = chat.chatInfo.nextNtfMode {
                    PopopxChatInfoTile(
                        title: nextNtfMode == .all ? Copy.unmute : Copy.mute,
                        systemImage: nextNtfMode.iconFilled,
                        tint: .neutral,
                        enabled: connectionUsable
                    ) {
                        toggleNotifications(chat, enableNtfs: nextNtfMode)
                    }
                }
            }
        }
    }

    // MARK: Connection and security

    private var securityCard: some View {
        PopopxSectionCard(Copy.groupSecurity, footnote: Copy.securityFootnote) {
            if let code = connectionCode {
                PopopxChatInfoRowLink(
                    title: contact.verified ? Copy.viewCode : Copy.verifyCode,
                    value: contact.verified ? Copy.verifiedOn : nil,
                    systemImage: contact.verified ? "checkmark.shield.fill" : "shield.lefthalf.filled",
                    tint: .brand
                ) {
                    VerifyCodeView(
                        displayName: contact.displayName,
                        connectionCode: code,
                        connectionVerified: contact.verified,
                        verify: { codeToCheck in
                            verifyConnectionCode(codeToCheck)
                        }
                    )
                    .navigationTitle(Copy.securityCodePage)
                    .navigationBarTitleDisplayMode(.inline)
                }
                PopopxChatInfoDivider()
            }

            if contact.activeConn != nil {
                PopopxChatInfoRow(
                    title: Copy.e2e,
                    value: contact.activeConn?.connPQEnabled == true ? Copy.pqResistant : Copy.pqStandard,
                    systemImage: "lock.shield.fill",
                    tint: .brand
                )
                PopopxChatInfoDivider()
            }

            if let profile = customUserProfile {
                PopopxChatInfoRow(
                    title: Copy.incognitoProfile,
                    value: profile.chatViewName,
                    note: Copy.incognitoNote,
                    systemImage: "person.crop.circle.badge.questionmark"
                )
                PopopxChatInfoDivider()
            }

            if connectionStats?.ratchetSyncAllowed == true {
                PopopxChatInfoRow(
                    title: Copy.fixConnection,
                    note: Copy.fixConnectionNote,
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                    tint: .brand,
                    action: {
                        syncConnection()
                    }
                )
            }
        }
        .disabled(!connectionUsable)
        .opacity(connectionUsable ? 1 : 0.45)
    }

    // MARK: Chat

    private var chatCard: some View {
        PopopxSectionCard(Copy.groupChat) {
            PopopxChatInfoRowLink(title: Copy.contactPreferences, systemImage: "switch.2", tint: .brand) {
                ContactPreferencesView(
                    contact: $contact,
                    featuresAllowed: $featuresAllowed,
                    currentFeaturesAllowed: $currentFeaturesAllowed,
                    savePreferences: { saveContactPreferences() }
                )
                .navigationTitle(Copy.contactPreferences)
                .navigationBarTitleDisplayMode(.large)
            }

            PopopxChatInfoDivider()
            receiptsBlock
            PopopxChatInfoDivider()

            PopopxChatInfoRowLink(title: Copy.wallpaper, systemImage: "photo.on.rectangle", tint: .brand) {
                ChatWallpaperEditorSheet(chat: chat)
            }
        }
        .disabled(!connectionUsable)
        .opacity(connectionUsable ? 1 : 0.45)
    }

    /// The three read-receipt tiers. The options are `SendReceipts` itself (Shared/Views/Chat/ChatInfoView.swift:62),
    /// and the third tier's default reads the current identity's `sendRcptsContacts` (POPOPXChat/ChatTypes.swift:48),
    /// so what it shows is "which default is being followed", not a guess.
    private var receiptsBlock: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxChatInfoRowBadge(systemName: "checkmark.message", tint: .brand)
                Text(Copy.sendReceipts)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            Text(Copy.sendReceiptsNote)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PopopxSegmentedControl(
                [
                    .init(selection: SendReceipts.yes, title: receiptWords(.yes)),
                    .init(selection: SendReceipts.no, title: receiptWords(.no)),
                    .init(
                        selection: SendReceipts.userDefault(sendReceiptsUserDefault),
                        title: receiptWords(.userDefault(sendReceiptsUserDefault))
                    )
                ],
                title: receiptWords,
                selection: $sendReceipts
            )
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .onChange(of: sendReceipts) { _, choice in
            setSendReceipts(choice)
        }
    }

    private func receiptWords(_ choice: SendReceipts) -> String {
        switch choice {
        case .yes: return Copy.receiptYes
        case .no: return Copy.receiptNo
        case let .userDefault(on): return on ? Copy.receiptDefaultOn : Copy.receiptDefaultOff
        }
    }

    // MARK: Auto-delete

    /// This row's control and confirmation logic is the old page's `ChatTTLOption` (Shared/Views/Chat/ChatInfoView.swift:664):
    /// It pops its own confirmation first, then `setChatTTL` + reloads the conversation, and rolls back on failure. The Chinese explanation is given by this page's footnote.
    private var ttlCard: some View {
        PopopxSectionCard(Copy.groupTTL, footnote: Copy.ttlFootnote) {
            ChatTTLOption(chat: chat, progressIndicator: $progressIndicator)
                .padding(.vertical, PopopxMetrics.space2XS)
        }
    }

    // MARK: Addresses

    private func addressCard(_ contactLink: String) -> some View {
        PopopxSectionCard(Copy.groupAddress, footnote: Copy.addressFootnote(contact.displayName)) {
            // One sealed string for the QR and the share: the stored address names its SMP host.
            let sharedLink = popopxSharedLink(contactLink)
            VStack(spacing: PopopxMetrics.spaceS) {
                POPOPXLinkQRCode(uri: sharedLink)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(PopopxMetrics.spaceM)
                    .frame(maxWidth: PopopxMetrics.space2XL * 5)

                PopopxButton(Copy.shareAddress, systemImage: "square.and.arrow.up", role: .secondary) {
                    showShareSheet(items: [sharedLink])
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Server

    private var serversCard: some View {
        PopopxSectionCard(Copy.groupServers, footnote: Copy.serversFootnote) {
            if let status = chatModel.chatSubStatus {
                let words = networkStatusWords(status)
                PopopxChatInfoRow(
                    title: Copy.networkStatus,
                    value: words.text,
                    systemImage: status.imageName,
                    tint: words.tint,
                    action: {
                        alert = .networkStatus(status)
                    }
                )
            }

            if let connStats = connectionStats {
                PopopxChatInfoDivider()
                PopopxChatInfoRow(
                    title: Copy.switchAddress,
                    note: Copy.switchAddressNote,
                    systemImage: "arrow.triangle.2.circlepath",
                    enabled: switchAddressAllowed(connStats),
                    action: {
                        alert = .switchAddress
                    }
                )

                if connStats.rcvQueuesInfo.contains(where: { $0.rcvSwitchStatus != nil }) {
                    PopopxChatInfoDivider()
                    PopopxChatInfoRow(
                        title: Copy.abortSwitch,
                        systemImage: "arrow.counterclockwise",
                        enabled: abortSwitchAllowed(connStats),
                        action: {
                            alert = .abortSwitchAddress
                        }
                    )
                }

                let receiving = connStats.rcvQueuesInfo.map { $0.rcvServer }
                if !receiving.isEmpty {
                    PopopxChatInfoDivider()
                    serverRow(Copy.receivingVia, receiving, "arrow.down.circle")
                }

                let sending = connStats.sndQueuesInfo.map { $0.sndServer }
                if !sending.isEmpty {
                    PopopxChatInfoDivider()
                    serverRow(Copy.sendingVia, sending, "arrow.up.circle")
                }
            }
        }
    }

    /// The server row: displays the first relay host name, and tapping copies the whole list away (the old page :41-52's `smpServers`
    /// was exactly this action, only the layout changed). Host names go through `serverHost` (old :54), the prefix is not stripped by our own rule.
    private func serverRow(_ title: String, _ servers: [String], _ systemImage: String) -> some View {
        PopopxChatInfoRow(
            title: title,
            value: serverHost(servers[0]),
            note: servers.count > 1 ? String(format: Copy.moreServersFormat, servers.count) : nil,
            systemImage: systemImage,
            action: {
                copyServers(servers.joined(separator: ";"))
            }
        )
    }

    private func networkStatusWords(_ status: SubscriptionStatus) -> (text: String, tint: PopopxIconTint) {
        switch status {
        case .active: return (Copy.netActive, .brand)
        case .pending: return (Copy.netPending, .neutral)
        case .removed(_): return (Copy.netRemoved, .danger)
        case .noSub: return (Copy.netNoSub, .neutral)
        }
    }

    private func switchAddressAllowed(_ stats: ConnectionStats) -> Bool {
        !stats.rcvQueuesInfo.contains { $0.rcvSwitchStatus != nil } && !stats.ratchetSyncSendProhibited
    }

    private func abortSwitchAllowed(_ stats: ConnectionStats) -> Bool {
        !stats.rcvQueuesInfo.contains { $0.rcvSwitchStatus != nil && !$0.canAbortSwitch }
            && !stats.ratchetSyncSendProhibited
    }

    // MARK: Dangerous operations

    private var dangerCard: some View {
        PopopxSectionCard(Copy.groupDanger, footnote: Copy.dangerFootnote) {
            PopopxChatInfoRow(
                title: Copy.clearHistory,
                note: Copy.clearHistoryNote,
                systemImage: "gobackward",
                tint: .danger,
                action: {
                    alert = .clearChat
                }
            )

            PopopxChatInfoDivider()

            PopopxChatInfoRow(
                title: Copy.deleteContact,
                note: Copy.deleteContactNote,
                systemImage: "person.badge.minus",
                tint: .danger,
                action: {
                    deleteContactDialog(
                        chat,
                        contact,
                        dismissToChatList: true,
                        showAlert: { someAlert in alert = .someAlert(someAlert) },
                        showActionSheet: { someActionSheet in actionSheet = someActionSheet },
                        showSheetContent: { someSheet in sheet = someSheet }
                    )
                }
            )
        }
    }

    // MARK: Behaviour

    private func loadContactInfo() {
        if let currentUser = chatModel.currentUser {
            sendReceiptsUserDefault = currentUser.sendRcptsContacts
        }
        sendReceipts = SendReceipts.fromBool(
            contact.chatSettings.sendRcpts,
            userDefault: sendReceiptsUserDefault
        )
        Task {
            do {
                let (stats, profile) = try await apiContactInfo(chat.chatInfo.apiId)
                let (latestContact, code) = try await apiGetContactCode(chat.chatInfo.apiId)
                connectionStats = stats
                customUserProfile = profile
                connectionCode = code
                if contact.activeConn?.connectionCode != latestContact.activeConn?.connectionCode {
                    chat.chatInfo = .direct(contact: latestContact)
                }
            } catch let error {
                logger.error("apiContactInfo or apiGetContactCode error: \(responseError(error))")
            }
        }
    }

    private func setContactAlias() {
        Task {
            do {
                if let updated = try await apiSetContactAlias(
                    contactId: chat.chatInfo.apiId,
                    localAlias: localAlias
                ) {
                    chatModel.updateContact(updated)
                }
            } catch {
                logger.error("setContactAlias error: \(responseError(error))")
            }
        }
    }

    private func verifyConnectionCode(_ code: String?) -> (Bool, String)? {
        guard let result = apiVerifyContact(chat.chatInfo.apiId, connectionCode: code) else { return nil }
        contact.activeConn?.connectionCode = result.0
            ? SecurityCode(securityCode: result.1, verifiedAt: .now)
            : nil
        connectionCode = result.1
        DispatchQueue.main.async {
            chat.chatInfo = .direct(contact: contact)
        }
        return result
    }

    private func setSendReceipts(_ choice: SendReceipts) {
        var chatSettings = chat.chatInfo.chatSettings ?? ChatSettings.defaults
        chatSettings.sendRcpts = choice.bool()
        updateChatSettings(chat, chatSettings: chatSettings)
    }

    private func saveContactPreferences() {
        Task {
            do {
                let prefs = contactFeaturesAllowedToPrefs(featuresAllowed)
                if let updated = try await apiSetContactPrefs(contactId: contact.contactId, preferences: prefs) {
                    contact = updated
                    chatModel.updateContact(updated)
                    currentFeaturesAllowed = featuresAllowed
                }
            } catch {
                logger.error("ContactPreferencesView apiSetContactPrefs error: \(responseError(error))")
            }
        }
    }

    private func syncConnection() {
        Task {
            if let stats = await syncContactConnection(contact, force: false) {
                connectionStats = stats
                dismiss()
            }
        }
    }

    private func switchContactAddress() {
        Task {
            do {
                let stats = try apiSwitchContact(contactId: contact.apiId)
                connectionStats = stats
                chatModel.updateContactConnectionStats(contact, stats)
                dismiss()
            } catch let error {
                logger.error("switchContactAddress apiSwitchContact error: \(responseError(error))")
                showErrorAlert(error, Copy.errorSwitchAddress)
            }
        }
    }

    private func abortSwitchContactAddress() {
        Task {
            do {
                let stats = try apiAbortSwitchContact(contact.apiId)
                connectionStats = stats
                chatModel.updateContactConnectionStats(contact, stats)
            } catch let error {
                logger.error("abortSwitchContactAddress apiAbortSwitchContact error: \(responseError(error))")
                showErrorAlert(error, Copy.errorAbortSwitch)
            }
        }
    }

    private func copyServers(_ text: String) {
        UIPasteboard.general.string = text
        PopopxHaptics.impact(.light)
        toast.show(Copy.copiedServers, kind: .encrypted)
    }

    // MARK: Prompts

    private func clearChatAlert() -> Alert {
        Alert(
            title: Text(Copy.clearConfirmTitle),
            message: Text(Copy.clearConfirmMessage(chat.chatInfo.displayName)),
            primaryButton: .destructive(Text(Copy.clearConfirmButton)) {
                Task {
                    await clearChat(chat)
                    dismiss()
                }
            },
            secondaryButton: .cancel()
        )
    }

    private func networkStatusAlert(_ status: SubscriptionStatus) -> Alert {
        Alert(
            title: Text(Copy.networkStatusTitle),
            message: Text(status.statusExplanation)
        )
    }
}

// MARK: - Rows and the atomic pieces inside a card

/// The divider inside a card. The atom library's namesake only lives in the `#if DEBUG` gallery (Shared/Components/PopopxControls.swift:853).
private struct PopopxChatInfoDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

/// The SF Symbol badge at the head of a row: the solid fill and the ink pressed on top of it are taken as a pair from `PopopxIconTint` (§2.5 item 2),
/// and the same badge in the library is private (PopopxControls.swift:315), so it is assembled here from scratch in the same shape.
private struct PopopxChatInfoRowBadge: View {
    let systemName: String
    let tint: PopopxIconTint

    var body: some View {
        Image(systemName: systemName)
            .font(PopopxType.microTag)
            .imageScale(.medium)
            .foregroundStyle(tint.ink)
            .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
            .background(tint.fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
            .accessibilityHidden(true)
    }
}

/// The ink drawn on the card face: `PopopxIconTint.ink` means "the ink that sits on a solid fill", and the two must not be mixed,
/// otherwise in light mode white pressed on a white card amounts to invisible.
private enum PopopxChatInfoInk {
    static func onCard(_ tint: PopopxIconTint) -> Color {
        switch tint {
        case .brand: return PopopxPalette.brand
        case .mesh: return PopopxPalette.meshInk
        case .danger: return PopopxPalette.dangerInk
        case .success: return PopopxPalette.successInk
        case .neutral: return PopopxPalette.label
        }
    }
}

private struct PopopxChatInfoRowLabel: View {
    let title: String
    var note: String?
    /// A dangerous row's title has to be seen at a glance, so the ink comes from the caller: label for an ordinary row, dangerInk for a dangerous one.
    var titleInk: Color = PopopxPalette.label

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(title)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(titleInk)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row. With an action it is a button, without one it is a pure readout — there is no "tapped and nothing happens" row.
private struct PopopxChatInfoRow: View {
    let title: String
    var value: String?
    var note: String?
    var systemImage: String?
    var tint: PopopxIconTint = .neutral
    var enabled = true
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                label
                    .contentShape(Rectangle())
            }
            .buttonStyle(PopopxPressButtonStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
        } else {
            label
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            if let systemImage {
                PopopxChatInfoRowBadge(systemName: systemImage, tint: tint)
            }
            PopopxChatInfoRowLabel(
                title: title,
                note: note,
                titleInk: tint == .danger ? PopopxPalette.dangerInk : PopopxPalette.label
            )
            Spacer(minLength: PopopxMetrics.spaceXS)
            if let value {
                Text(value)
                    .font(PopopxType.meta)
                    .foregroundStyle(tint == .danger ? PopopxPalette.dangerInk : PopopxPalette.labelSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
    }
}

/// A row that pushes to an existing page. `NavigationLink` owns the navigation, so the whole row is not a Button:
/// the atom library's `PopopxPickerRow` is itself a Button, and nesting it inside a link would swallow the tap.
private struct PopopxChatInfoRowLink<Destination: View>: View {
    let title: String
    var value: String?
    var systemImage: String?
    var tint: PopopxIconTint = .brand
    let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: PopopxMetrics.spaceS) {
                if let systemImage {
                    PopopxChatInfoRowBadge(systemName: systemImage, tint: tint)
                }
                Text(title)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
                if let value {
                    Text(value)
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, PopopxMetrics.spaceXS)
            .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityHint(Text(verbatim: Copy.opensHint))
    }
}

/// The quick-action cell: icon on top, text below, and the whole cell takes off from 44pt.
private struct PopopxChatInfoTile: View {
    let title: String
    let systemImage: String
    let tint: PopopxIconTint
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: systemImage)
                    .font(PopopxType.body)
                    .imageScale(.large)
                Text(title)
                    .font(PopopxType.microTag)
            }
            .foregroundStyle(enabled ? PopopxChatInfoInk.onCard(tint) : PopopxPalette.labelHint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .padding(.vertical, PopopxMetrics.spaceXS)
            .background(PopopxPalette.base, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                    .strokeBorder(PopopxPalette.labelHint, lineWidth: PopopxMetrics.divider)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(Text(verbatim: title))
    }
}

/// The call cell. Its decision tree corresponds item by item to the old page's `CallButton` (Shared/Views/Chat/ChatInfoView.swift:784-899),
/// only the layout becomes a popopx cell: whether a call is possible, why it is not, and whether to repair the connection first are all real judgements.
@MainActor
private struct PopopxChatInfoCallTile: View {
    let chat: Chat
    let contact: Contact
    @Binding var connectionStats: ConnectionStats?
    let media: CallMediaType
    let showAlert: (SomeAlert) -> Void

    var body: some View {
        PopopxChatInfoTile(
            title: words.text,
            systemImage: words.symbol,
            tint: .brand,
            enabled: canCall
        ) {
            fire()
        }
        .disabled(ChatModel.shared.activeCall != nil)
    }

    private var words: (text: String, symbol: String) {
        media == .audio ? (Copy.callAudio, "phone.fill") : (Copy.callVideo, "video.fill")
    }

    private var canCall: Bool {
        contact.ready && contact.active
            && chat.chatInfo.featureEnabled(.calls)
            && ChatModel.shared.activeCall == nil
    }

    private func fire() {
        if canCall {
            callWhenReady()
        } else if contact.sendMsgToConnect {
            notify(Copy.cantCallTitle, Copy.sendMsgToEnable)
        } else if !contact.active {
            notify(Copy.cantCallTitle, Copy.contactDeleted)
        } else if !contact.ready {
            notify(Copy.cantCallTitle, Copy.contactNotReady)
        } else if !chat.chatInfo.featureEnabled(.calls) {
            switch chat.chatInfo.showEnableCallsAlert {
            case .userEnable:
                showAlert(SomeAlert(
                    alert: Alert(
                        title: Text(Copy.allowCallsTitle),
                        message: Text(Copy.allowCallsMessage),
                        primaryButton: .default(Text(Copy.allow)) {
                            allowFeatureToContact(contact, .calls)
                        },
                        secondaryButton: .cancel()
                    ),
                    id: "popopxChatInfo.allowCalls"
                ))
            case .askContact:
                notify(Copy.callsProhibited, Copy.callsAskContact)
            case .other:
                notify(Copy.callsProhibited, Copy.callsCheckBoth)
            }
        } else {
            notify(Copy.cantCallTitle, nil)
        }
    }

    private func callWhenReady() {
        guard let connStats = connectionStats else { return }
        if connStats.ratchetSyncState == .ok {
            if CallController.useCallKit() {
                CallController.shared.startCall(contact, media)
            } else {
                // When not going through CallKit the colour scheme gets changed by the call, so the sheet is dismissed first and the call started after; same reason as old page :804-807.
                dismissAllSheets(animated: true) {
                    CallController.shared.startCall(contact, media)
                }
            }
        } else if connStats.ratchetSyncAllowed {
            showAlert(SomeAlert(
                alert: Alert(
                    title: Text(Copy.fixConnectionTitle),
                    message: Text(Copy.fixConnectionMessage),
                    primaryButton: .default(Text(Copy.fix)) {
                        Task {
                            if let stats = await syncContactConnection(contact, force: false) {
                                connectionStats = stats
                            }
                        }
                    },
                    secondaryButton: .cancel()
                ),
                id: "popopxChatInfo.fixConnection"
            ))
        } else {
            notify(Copy.cantCallTitle, Copy.renegotiationInProgress)
        }
    }

    private func notify(_ title: String, _ message: String?) {
        showAlert(SomeAlert(
            alert: message.map { Alert(title: Text(title), message: Text($0)) } ?? Alert(title: Text(title)),
            id: "popopxChatInfo.\(title)"
        ))
    }
}

/// The avatar. With base64 the existing `ProfileImage` is used, without it falls back to the brand mark — no placeholder silhouette is drawn.
@MainActor
private struct PopopxChatInfoAvatar: View {
    let image: String?
    let side: CGFloat

    var body: some View {
        Group {
            if imageFromBase64(image) != nil {
                // `color:` takes the same value as PopopxMeView.swift:947-949: inside, `ProfileImage` maps
                // this image's lightness on the grouped background via asAnotherColorFromSecondaryVariant.
                ProfileImage(imageStr: image, size: side, color: Color(uiColor: .tertiarySystemGroupedBackground))
            } else {
                Image(PopopxBrandAsset.mark)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Copy

/// Every Chinese sentence on the page appears exactly once, here.
private enum Copy {
    static let pageTitle = NSLocalizedString("Contact", comment: "")
    static let close = NSLocalizedString("Done", comment: "")
    static let working = NSLocalizedString("Working…", comment: "")
    static let opensHint = NSLocalizedString("Open", comment: "")
    static let verifiedOn = NSLocalizedString("Verified", comment: "")

    // Top card
    static let verifiedShieldHint = NSLocalizedString("This connection has been verified by its security code", comment: "")
    static let aliasLabel = NSLocalizedString("Local alias", comment: "")
    static let aliasPrompt = NSLocalizedString("Give this contact a name on this device", comment: "")
    static let stateReady = NSLocalizedString("Connected", comment: "")
    static let stateSndReady = NSLocalizedString("Sending queue ready", comment: "")
    static let stateConnecting = NSLocalizedString("Connecting, check again later", comment: "")
    static let stateNoConnection = NSLocalizedString("No connection yet", comment: "")
    static let stateFailed = NSLocalizedString("Connection failed", comment: "")
    static let stateDeleted = NSLocalizedString("Contact deleted", comment: "")

    // Quick actions
    static let search = NSLocalizedString("Search", comment: "")
    static let callAudio = NSLocalizedString("Audio", comment: "")
    static let callVideo = NSLocalizedString("Video", comment: "")
    static let mute = NSLocalizedString("Mute", comment: "")
    static let unmute = NSLocalizedString("Unmute", comment: "")

    // Connection and security
    static let groupSecurity = NSLocalizedString("Connection & security", comment: "")
    static let securityFootnote = NSLocalizedString("Compare the security codes on both devices in person; the connection counts as verified only when they match.", comment: "")
    static let verifyCode = NSLocalizedString("Verify security code", comment: "")
    static let viewCode = NSLocalizedString("View security code", comment: "")
    static let securityCodePage = NSLocalizedString("Security code", comment: "")
    static let e2e = NSLocalizedString("End-to-end encrypted", comment: "")
    static let pqResistant = NSLocalizedString("Post-quantum", comment: "")
    static let pqStandard = NSLocalizedString("Standard", comment: "")
    static let incognitoProfile = NSLocalizedString("Profile used for this connection", comment: "")
    static let incognitoNote = NSLocalizedString("This connection was not made with your main profile.", comment: "")
    static let fixConnection = NSLocalizedString("Fix connection", comment: "")
    static let fixConnectionNote = NSLocalizedString("Re-negotiates the encryption, then returns you to the chat.", comment: "")

    // Chat
    static let groupChat = NSLocalizedString("Chat", comment: "")
    static let contactPreferences = NSLocalizedString("Contact preferences", comment: "")
    static let wallpaper = NSLocalizedString("Chat wallpaper", comment: "")
    static let sendReceipts = NSLocalizedString("Read receipts", comment: "")
    static let sendReceiptsNote = NSLocalizedString("Applies to this chat only; it does not change the global setting.", comment: "")
    static let receiptYes = NSLocalizedString("Send", comment: "")
    static let receiptNo = NSLocalizedString("Do not send", comment: "")
    static let receiptDefaultOn = NSLocalizedString("Follow default (on)", comment: "")
    static let receiptDefaultOff = NSLocalizedString("Follow default (off)", comment: "")

    // Auto-delete
    static let groupTTL = NSLocalizedString("Automatic deletion", comment: "")
    static let ttlFootnote = NSLocalizedString("Deletes this chat's messages from this device; the chat reloads after the change.", comment: "")

    // Addresses
    static let groupAddress = NSLocalizedString("Connection address", comment: "")
    static func addressFootnote(_ name: String) -> String {
        String(format: NSLocalizedString("Send this address to the other person so they can start a connection with %@", comment: ""), name)
    }
    static let shareAddress = NSLocalizedString("Share address", comment: "")

    // Server
    static let groupServers = NSLocalizedString("Servers", comment: "")
    static let serversFootnote = NSLocalizedString("The relay host names can be copied to troubleshoot connection problems.", comment: "")
    static let networkStatus = NSLocalizedString("Network status", comment: "")
    static let netActive = NSLocalizedString("Subscribed", comment: "")
    static let netPending = NSLocalizedString("Connecting", comment: "")
    static let netRemoved = NSLocalizedString("Error", comment: "")
    static let netNoSub = NSLocalizedString("Not subscribed", comment: "")
    static let networkStatusTitle = NSLocalizedString("Network status", comment: "")
    static let switchAddress = NSLocalizedString("Change receiving address", comment: "")
    static let switchAddressNote = NSLocalizedString("Receives from another server; it completes once your contact is online.", comment: "")
    static let abortSwitch = NSLocalizedString("Abort changing address", comment: "")
    static let receivingVia = NSLocalizedString("Receiving relay", comment: "")
    static let sendingVia = NSLocalizedString("Sending relay", comment: "")
    static let moreServersFormat = NSLocalizedString("%lld total, tap to copy all", comment: "")
    static let copiedServers = NSLocalizedString("Server address copied", comment: "")
    static let errorSwitchAddress = NSLocalizedString("Failed to change the receiving address", comment: "")
    static let errorAbortSwitch = NSLocalizedString("Failed to abort changing the address", comment: "")

    // Dangerous operations
    static let groupDanger = NSLocalizedString("Dangerous actions", comment: "")
    static let dangerFootnote = NSLocalizedString("Deleting and clearing affect only you on this device, unless you chose to notify the other side in the second step.", comment: "")
    static let clearHistory = NSLocalizedString("Clear chat history", comment: "")
    static let clearHistoryNote = NSLocalizedString("Deletes only your side on this device; your contact keeps theirs.", comment: "")
    static let clearConfirmTitle = NSLocalizedString("Clear chat history?", comment: "")
    static func clearConfirmMessage(_ name: String) -> String {
        String(format: NSLocalizedString("Every message with %@ will be deleted from this device and cannot be undone; the copy on your contact's device is not affected.", comment: ""), name)
    }
    static let clearConfirmButton = NSLocalizedString("Clear", comment: "")
    static let deleteContact = NSLocalizedString("Delete contact", comment: "")
    static let deleteContactNote = NSLocalizedString("The next step asks whether to delete only the chat or the contact as well.", comment: "")

    // Preferences left unsaved when leaving this page
    static let savePrefsTitle = NSLocalizedString("Save preferences?", comment: "")
    static let savePrefsMessage = NSLocalizedString("Your changes have not been sent yet; your contact is notified only when they are sent.", comment: "")
    static let savePrefsButton = NSLocalizedString("Save and notify contact", comment: "")

    // Call decision
    static let cantCallTitle = NSLocalizedString("Cannot start a call", comment: "")
    static let sendMsgToEnable = NSLocalizedString("Send your contact a message first; calls stay closed until you do.", comment: "")
    static let contactDeleted = NSLocalizedString("Your contact was deleted.", comment: "")
    static let contactNotReady = NSLocalizedString("The connection is still being made, please try again later.", comment: "")
    static let allowCallsTitle = NSLocalizedString("Allow calls?", comment: "")
    static let allowCallsMessage = NSLocalizedString("Your contact must be allowed to call you before you can call them.", comment: "")
    static let allow = NSLocalizedString("Allow", comment: "")
    static let callsProhibited = NSLocalizedString("Calls prohibited!", comment: "")
    static let callsAskContact = NSLocalizedString("Ask your contact to enable calls first.", comment: "")
    static let callsCheckBoth = NSLocalizedString("Please check yours and your contact preferences.", comment: "")
    static let fixConnectionTitle = NSLocalizedString("Fix connection first?", comment: "")
    static let fixConnectionMessage = NSLocalizedString("The encryption for this connection needs to be re-negotiated.", comment: "")
    static let fix = NSLocalizedString("Fix", comment: "")
    static let renegotiationInProgress = NSLocalizedString("The encryption is being re-negotiated, please try again later.", comment: "")
}

// MARK: - Previews

#if DEBUG
struct PopopxChatInfoView_Previews: PreviewProvider {
    static var previews: some View {
        PopopxChatInfoView(
            chat: Chat(chatInfo: ChatInfo.sampleData.direct, chatItems: []),
            contact: Contact.sampleData,
            localAlias: "",
            featuresAllowed: contactUserPrefsToFeaturesAllowed(Contact.sampleData.mergedPreferences),
            currentFeaturesAllowed: contactUserPrefsToFeaturesAllowed(Contact.sampleData.mergedPreferences),
            onSearch: {}
        )
        .environmentObject(ChatModel.shared)
        .environmentObject(AppTheme.shared)
    }
}
#endif
