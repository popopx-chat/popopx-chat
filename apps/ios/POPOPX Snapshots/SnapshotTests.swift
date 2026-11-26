import XCTest
import SwiftUI
import UIKit
import AVFoundation
@testable import POPOPX
@testable import POPOPXChat

final class SnapshotTests: XCTestCase {
    private var fixedQRCode: UIImage?

    override func setUp() async throws {
        fixedQRCode = await generateImage(previewQRLink, tintColor: UIColor(red: 0.023, green: 0.176, blue: 0.337, alpha: 1), errorLevel: "M")
        // previewScenes() builds every preview eagerly and WebRTCClient.swift:22 calls getChatCtrl()
        // while initializing, so the harness needs a controller before it can render anything.
        if !hasChatCtrl() { _ = chatMigrateInit() }
    }

    @MainActor
    // The 376 baselines under References/ are our own renders (regenerated 2026-11-12), which is what
    // References/ASSETS_LICENSE.md requires: SimpleX's screenshots are proprietary and allowed only in
    // an unmodified distribution. This target renders, it does not compare, so a green run says nothing
    // about them. SNAPSHOT_SIZE only picks the scenes and names the file - the scale itself comes from
    // the simulator's content size, so a run that does not set it first re-renders "large" 112 times.
    func testPreviews() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: env["SNAPSHOT_DIR"] ?? NSTemporaryDirectory() + "snapshots", isDirectory: true)
        let size = env["SNAPSHOT_SIZE"] ?? "large"
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        ChatModel.shared.currentUser = User.sampleData
        BadgeModel.shared.set(userId: User.sampleData.userId, badgeState: nil)
        var index: [[String: Any]] = []
        for dark in [false, true] {
            let theme = snapshotTheme(dark)
            CurrentColors = theme
            for scene in previewScenes() where scene.allSizes || size == "large" {
                let themeName = dark ? "dark" : "light"
                let file = "\(scene.name)-\(themeName)-\(size).png"
                let image = try renderScene(scene, theme.toAppTheme(), dark: dark, fixedQRCode: fixedQRCode, in: windowScene)
                try XCTUnwrap(image.pngData()).write(to: dir.appendingPathComponent(file))
                index.append([
                    "scene": scene.name,
                    "theme": themeName,
                    "size": size,
                    "file": file,
                    "width": Int((image.size.width * image.scale).rounded()),
                    "height": Int((image.size.height * image.scale).rounded()),
                    "scale": image.scale,
                    "contentSizeCategory": UIApplication.shared.preferredContentSizeCategory.rawValue
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("index-\(size).json"))
    }

    @MainActor
    func testFirstLayout() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let env = ProcessInfo.processInfo.environment
        let size = env["SNAPSHOT_SIZE"] ?? "large"
        let dir = layoutCheckDir(env)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        ChatModel.shared.currentUser = User.sampleData
        let theme = snapshotTheme(false)
        CurrentColors = theme
        let appTheme = theme.toAppTheme()
        let fixtures = SnapshotFixtures()
        var index: [[String: Any]] = []
        for terminal in [true, false] {
            let chats = [("direct", fixtures.overviewDirect(terminal: terminal)), ("group", fixtures.overviewGroup(terminal: terminal)), ("channel", fixtures.overviewChannel(terminal: terminal))]
            for (name, rows) in chats {
                let scene = "\(name)-\(terminal ? "terminal" : "classic")-\(size)"
                let scrollView = EndlessScrollView<MergedItem>(frame: .zero)
                let host = UIHostingController(rootView: ScrollRepresentable(scrollView: scrollView) { (i: Int, item: MergedItem) in
                    rows.row(i, item)
                        .environmentObject(ChatModel.shared)
                        .environmentObject(appTheme)
                })
                let window = UIWindow(windowScene: windowScene)
                window.overrideUserInterfaceStyle = .light
                window.rootViewController = host
                window.frame = windowScene.screen.bounds
                window.isHidden = false
                settle()
                scrollView.updateItems(rows.mergedItems.items)
                settle()
                let first = scrollView.listState.visibleItems.map { $0.view.frame.height }
                try XCTUnwrap(windowImage(window).pngData()).write(to: dir.appendingPathComponent("\(scene)-first.png"))
                scrollView.updateItems(rows.mergedItems.items, true)
                settle()
                let reloaded = scrollView.listState.visibleItems.map { $0.view.frame.height }
                try XCTUnwrap(windowImage(window).pngData()).write(to: dir.appendingPathComponent("\(scene)-reloaded.png"))
                window.isHidden = true
                window.rootViewController = nil
                index.append(["scene": scene, "first": first, "reloaded": reloaded])
                print("first layout \(scene): first \(first), reloaded \(reloaded)")
                XCTAssertEqual(first.count, reloaded.count, scene)
                for (a, b) in zip(first, reloaded) {
                    XCTAssertEqual(a, b, accuracy: 0.5, scene)
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("first-layout-\(size).json"))
    }

    @MainActor
    func testLayoutSwitch() throws {
        let env = ProcessInfo.processInfo.environment
        guard (env["SNAPSHOT_SIZE"] ?? "large") == "large" else { return }
        let dir = layoutCheckDir(env)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        ChatModel.shared.currentUser = User.sampleData
        let theme = snapshotTheme(false)
        CurrentColors = theme
        let appTheme = theme.toAppTheme()
        let sceneDelegate = SceneDelegate()
        let appearance = {
            UIHostingController(rootView: AppearanceSettings()
                .environmentObject(ChatModel.shared)
                .environmentObject(sceneDelegate)
                .environmentObject(appTheme))
        }
        chatLayoutDefault.set(.classic)
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = appearance()
        window.frame = windowScene.screen.bounds
        window.isHidden = false
        settle()
        try XCTUnwrap(windowImage(window).pngData()).write(to: dir.appendingPathComponent("appearance-1-classic.png"))
        chatLayoutDefault.set(.terminal)
        settle()
        try XCTUnwrap(windowImage(window).pngData()).write(to: dir.appendingPathComponent("appearance-2-terminal-switched.png"))
        window.rootViewController = appearance()
        settle()
        try XCTUnwrap(windowImage(window).pngData()).write(to: dir.appendingPathComponent("appearance-3-terminal-reopened.png"))
        chatLayoutDefault.set(.classic)
        settle()
        try XCTUnwrap(windowImage(window).pngData()).write(to: dir.appendingPathComponent("appearance-4-classic-switched.png"))
        window.isHidden = true
        window.rootViewController = nil
    }

    @MainActor
    func testTerminalSpacing() {
        let items = SnapshotFixtures().spacingItems()
        let p = terminalParagraphGap
        let rows = zip(items.dropFirst(), items).map { item, older in
            let sender = terminalItemShowsSender(item, older)
            let largeGap = !item.chatDir.sameDirection(older.chatDir) || item.meta.itemTs.timeIntervalSince(older.meta.itemTs) > 60
            return (sender: sender, gap: terminalRowGap(item, older, separated: false, largeGap: largeGap, hasSenderRow: sender), card: terminalItemStartsWithCard(item, revealed: true))
        }
        XCTAssertEqual(items.map(\.isOneLine), [false, true, true, true, true, true, true, false, true, true, false, true, false, false])
        XCTAssertEqual(rows.map { $0.sender }, [true, true, false, false, true, false, true, false, true, true, true, false, true])
        XCTAssertEqual(rows.map { $0.gap }, [p, p, 0, p, p, 0, p, p, p, p, p, p, p])
        XCTAssertEqual(rows.map { $0.card }, [false, false, false, false, false, false, false, false, false, true, true, true, false])
        XCTAssertEqual(items.suffix(2).map(terminalTextTopGap), [p, 0])
        let edges = SnapshotFixtures().spacingEdgeItems()
        XCTAssertEqual(edges.map { terminalItemStartsWithCard($0, revealed: true) }, [true, false, true, true])
        XCTAssertEqual(edges.suffix(3).map(terminalTextTopGap), [0, 0, 0])
        var unreacted = items[3]
        unreacted.reactions = []
        let rowHash = { (older: ChatItem) in ListItem(item: items[4], prevItem: items[5], nextItem: older, unreadBefore: 0).genHash(false, false) }
        XCTAssertNotEqual(rowHash(items[3]), rowHash(unreacted))
    }

    func testVoiceMessageTimeFormatting() {
        XCTAssertEqual(voiceMessageTime(90), "01:30")
        XCTAssertEqual(voiceMessageTime(3600), "01:00:00")
        XCTAssertEqual(voiceMessageTime(TimeInterval(Int.max)), "00:00")
        XCTAssertEqual(voiceMessageTime(.nan), "00:00")
        XCTAssertEqual(voiceMessageTime_(nil), "00:00")
        XCTAssertEqual(voiceMessageTime_(TimeInterval(Int.max)), "00:00")
    }
}

private func layoutCheckDir(_ env: [String: String]) -> URL {
    URL(fileURLWithPath: env["SNAPSHOT_DIR"] ?? NSTemporaryDirectory() + "snapshots", isDirectory: true)
        .deletingLastPathComponent()
        .appendingPathComponent("layout-checks", isDirectory: true)
}

private func windowImage(_ window: UIWindow) -> UIImage {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.preferredRange = .standard
    format.opaque = true
    return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
        _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
}

private struct SnapshotScene {
    var name: String
    var height: CGFloat? = nil
    var allSizes: Bool
    var device: Bool
    var view: AnyView

    init<P: PreviewProvider>(_ preview: P.Type, allSizes: Bool = false, device: Bool = false) {
        name = String(describing: preview).replacingOccurrences(of: "_Previews", with: "")
        self.allSizes = allSizes
        self.device = device
        view = AnyView(preview.previews)
    }
}

private func previewScenes() -> [SnapshotScene] {
    [
        SnapshotScene(ActiveCallOverlay_Previews.self),
        SnapshotScene(AddChannelView_Previews.self, device: true),
        SnapshotScene(AddContactLearnMore_Previews.self),
        SnapshotScene(AddGroupMembersView_Previews.self),
        SnapshotScene(AddGroupView_Previews.self, device: true),
        SnapshotScene(AdvancedNetworkSettings_Previews.self, device: true),
        SnapshotScene(BadgesCheckOrderView_Previews.self),
        SnapshotScene(BadgesHowItWorksView_Previews.self),
        SnapshotScene(BadgesHowLongView_Previews.self),
        SnapshotScene(BadgesRedeemCodeView_Previews.self, device: true),
        SnapshotScene(BadgesSupportPopopxView_Previews.self, device: true),
        SnapshotScene(CallSettings_Previews.self, device: true),
        SnapshotScene(ChannelMembersView_Previews.self),
        SnapshotScene(ChannelRelaysView_Previews.self),
        SnapshotScene(ChatHelp_Previews.self),
        SnapshotScene(ChatInfoImage_Previews.self),
        SnapshotScene(ChatInfoToolbar_Previews.self),
        SnapshotScene(ChatInfoView_Previews.self, device: true),
        SnapshotScene(ChatItemForwardingView_Previews.self),
        SnapshotScene(ChatItemInfoView_Previews.self),
        SnapshotScene(ChatItemView_NonMsgContentDeleted_Previews.self, allSizes: true),
        SnapshotScene(ChatItemView_Previews.self, allSizes: true),
        SnapshotScene(ChatListNavLink_Previews.self),
        SnapshotScene(ChatListView_Previews.self),
        SnapshotScene(ChatPreviewView_Previews.self),
        SnapshotScene(ChatView_Previews.self, device: true),
        SnapshotScene(CIChatFeatureView_Previews.self, allSizes: true),
        SnapshotScene(CIEventView_Previews.self, allSizes: true),
        SnapshotScene(CIFeaturePreferenceView_Previews.self, allSizes: true),
        SnapshotScene(CIFileView_Previews.self, allSizes: true),
        SnapshotScene(CIGroupInvitationView_Previews.self, allSizes: true),
        SnapshotScene(CIInvalidJSONView_Previews.self, allSizes: true),
        SnapshotScene(CIMemberCreatedContactView_Previews.self, allSizes: true),
        SnapshotScene(CIMetaView_Previews.self, allSizes: true),
        SnapshotScene(CIVoiceView_Previews.self, allSizes: true),
        SnapshotScene(ClassicAvatars_Previews.self, allSizes: true),
        SnapshotScene(ClassicOverviewChannel_Previews.self),
        SnapshotScene(ClassicOverviewDirect_Previews.self),
        SnapshotScene(ClassicOverviewGroup_Previews.self),
        SnapshotScene(ClassicParagraphs_Previews.self, allSizes: true),
        SnapshotScene(ComposeVoiceView_Previews.self),
        SnapshotScene(ConnectDesktopView_Previews.self, device: true),
        SnapshotScene(ContactConnectionInfo_Previews.self),
        SnapshotScene(ContactConnectionView_Previews.self),
        SnapshotScene(ContactPreferencesView_Previews.self, device: true),
        SnapshotScene(ContactRequestView_Previews.self),
        SnapshotScene(ContextContactRequestActionsView_Previews.self),
        SnapshotScene(ContextItemView_Previews.self),
        SnapshotScene(ContextMemberContactActionsView_Previews.self),
        SnapshotScene(ContextPendingMemberActionsView_Previews.self),
        SnapshotScene(ContextProfilePickerView_Previews.self),
        SnapshotScene(CreateProfile_Previews.self, device: true),
        SnapshotScene(CreatePOPOPXAddress_Previews.self),
        SnapshotScene(CustomTimePicker_Previews.self),
        SnapshotScene(DatabaseEncryptionView_Previews.self, device: true),
        SnapshotScene(DatabaseErrorView_Previews.self),
        SnapshotScene(DatabaseView_Previews.self, device: true),
        SnapshotScene(DeletedItemView_Previews.self, allSizes: true),
        SnapshotScene(DetermineWidth_Previews.self),
        SnapshotScene(DeveloperView_Previews.self),
        SnapshotScene(EmojiItemView_Previews.self, allSizes: true),
        SnapshotScene(FramedCIVoiceView_Previews.self, allSizes: true),
        SnapshotScene(FramedItemView_Deleted_Previews.self, allSizes: true),
        SnapshotScene(FramedItemView_Edited_Previews.self, allSizes: true),
        SnapshotScene(FramedItemView_Previews.self, allSizes: true),
        SnapshotScene(GroupChatInfoView_Previews.self, device: true),
        SnapshotScene(GroupLinkView_Previews.self),
        SnapshotScene(GroupMemberInfoView_Previews.self, device: true),
        SnapshotScene(GroupPreferencesView_Previews.self, device: true),
        SnapshotScene(GroupProfileView_Previews.self, device: true),
        SnapshotScene(GroupWelcomeView_Previews.self),
        SnapshotScene(IncognitoHelp_Previews.self),
        SnapshotScene(IncomingCallView_Previews.self),
        SnapshotScene(IntegrityErrorItemView_Previews.self, allSizes: true),
        SnapshotScene(LargeLinkPreview_Previews.self, allSizes: true),
        SnapshotScene(LocalAuthView_Previews.self),
        SnapshotScene(MarkdownHelp_Previews.self),
        SnapshotScene(MarkedDeletedItemView_Previews.self, allSizes: true),
        SnapshotScene(MemberAdmissionView_Previews.self),
        SnapshotScene(MemberSupportChatToolbar_Previews.self),
        SnapshotScene(MemberSupportView_Previews.self),
        SnapshotScene(MigrateToDevice_Previews.self, device: true),
        SnapshotScene(MigrateToGroupView_Previews.self),
        SnapshotScene(MsgContentView_Previews.self, allSizes: true),
        SnapshotScene(NativeTextEditor_Previews.self),
        SnapshotScene(NetworkServersView_Previews.self),
        SnapshotScene(NewChatMenuButton_Previews.self),
        SnapshotScene(NewFeaturesView_Previews.self),
        SnapshotScene(NewServerView_Previews.self),
        SnapshotScene(NotificationsModeView_Previews.self, device: true),
        SnapshotScene(NotificationsView_Previews.self),
        SnapshotScene(OnboardingConditionsView_Previews.self),
        SnapshotScene(OnboardingStepsView_Previews.self),
        SnapshotScene(OneHandUICard_Previews.self),
        SnapshotScene(OperatorView_Previews.self),
        SnapshotScene(PasscodeEntry_Previews.self),
        SnapshotScene(PasscodeViewView_Previews.self),
        SnapshotScene(PreferencesView_Previews.self),
        SnapshotScene(PrivacySettings_Previews.self),
        SnapshotScene(ProfileImage_Previews.self),
        SnapshotScene(ProfilePrivacyView_Previews.self, device: true),
        SnapshotScene(ProtocolServerView_Previews.self),
        SnapshotScene(QRCode_Previews.self),
        SnapshotScene(RTCServers_Previews.self),
        SnapshotScene(ScanCodeView_Previews.self),
        SnapshotScene(ScanProtocolServer_Previews.self),
        SnapshotScene(SecondaryChatView_Previews.self),
        SnapshotScene(SendMessageView_Previews.self),
        SnapshotScene(SetAppPasscodeView_Previews.self),
        SnapshotScene(SetDeliveryReceiptsView_Previews.self),
        SnapshotScene(SettingsView_Previews.self, device: true),
        SnapshotScene(POPOPXInfo_Previews.self, device: true),
        SnapshotScene(SmallLinkPreview_Previews.self),
        SnapshotScene(SupportPOPOPXBanner_Previews.self),
        SnapshotScene(TerminalAvatars_Previews.self, allSizes: true),
        SnapshotScene(TerminalMedia_Previews.self),
        SnapshotScene(TerminalNames_Previews.self, allSizes: true),
        SnapshotScene(TerminalOverviewChannel_Previews.self),
        SnapshotScene(TerminalOverviewDirect_Previews.self),
        SnapshotScene(TerminalOverviewGroup_Previews.self),
        SnapshotScene(TerminalQuoteThumbnail_Previews.self, allSizes: true),
        SnapshotScene(TerminalRightToLeft_Previews.self),
        SnapshotScene(TerminalRuleOnly_Previews.self, allSizes: true),
        SnapshotScene(TerminalSpacing_Previews.self, allSizes: true),
        SnapshotScene(UserAddressLearnMore_Previews.self),
        SnapshotScene(UserAddressView_Previews.self),
        SnapshotScene(UserPicker_Previews.self),
        SnapshotScene(VerifyCodeView_Previews.self, device: true),
        SnapshotScene(VersionView_Previews.self),
        SnapshotScene(WhyPOPOPX_Previews.self),
        SnapshotScene(YourServersView_Previews.self)
    ]
}

private func snapshotTheme(_ dark: Bool) -> ThemeManager.ActiveTheme {
    let base: DefaultTheme = dark ? .DARK : .LIGHT
    return ThemeManager.ActiveTheme(
        name: base.themeName,
        base: base,
        colors: (dark ? DarkColorPalette : LightColorPalette).clone(),
        appColors: (dark ? DarkColorPaletteApp : LightColorPaletteApp).clone(),
        wallpaper: AppWallpaper(background: nil, tint: nil, type: .empty)
    )
}

private let previewQRLink = "https://smp1.popopx.im/a#preview-contact-key-for-snapshot-tests"

@MainActor
private func renderScene(_ scene: SnapshotScene, _ theme: AppTheme, dark: Bool, fixedQRCode: UIImage?, in windowScene: UIWindowScene) throws -> UIImage {
    let screen = windowScene.screen
    let width = screen.bounds.width
    let root = VStack(spacing: 0) { scene.view }
        .environmentObject(ChatModel.shared)
        .environmentObject(theme)
        .environment(\.fixedQRCode, fixedQRCode)
        .frame(width: width, height: scene.height)
    let host = UIHostingController(rootView: AnyView(root))
    if #available(iOS 16.4, *) {
        host.safeAreaRegions = scene.device ? .container : []
    }
    let window = UIWindow(windowScene: windowScene)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.rootViewController = host
    window.frame = CGRect(x: 0, y: 0, width: width, height: scene.height ?? screen.bounds.height)
    window.isHidden = false
    settle()
    if scene.height == nil && !scene.device {
        for _ in 0..<2 {
            let fit = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            let fill = host.sizeThatFits(in: screen.bounds.size)
            window.frame = CGRect(x: 0, y: 0, width: width, height: ceil(max(fit.height, fill.height)))
            settle()
        }
    }
    window.endEditing(true)
    removeAnimations(window.layer)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.preferredRange = .standard
    format.opaque = true
    let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
        _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        if scene.device {
            drawStatusBar(dark: dark)
        }
    }
    window.isHidden = true
    window.rootViewController = nil
    return image
}

private func drawStatusBar(dark: Bool) {
    let color: UIColor = dark ? .white : .black
    let time = NSAttributedString(string: "9:41", attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: color])
    let timeSize = time.size()
    time.draw(at: CGPoint(x: 74 - timeSize.width / 2, y: 32.5 - timeSize.height / 2))
    let icons = [
        ("cellularbars", CGRect(x: 288.5, y: 26.5, width: 19, height: 12)),
        ("wifi", CGRect(x: 315, y: 26.5, width: 17, height: 12)),
        ("battery.100", CGRect(x: 339.5, y: 26, width: 27, height: 13))
    ]
    for (symbol, box) in icons {
        let icon = UIImage(systemName: symbol)!.withTintColor(color, renderingMode: .alwaysOriginal)
        icon.draw(in: AVMakeRect(aspectRatio: icon.size, insideRect: box))
    }
}

private func removeAnimations(_ layer: CALayer) {
    layer.removeAllAnimations()
    layer.sublayers?.forEach(removeAnimations)
}

private func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
}

struct TerminalNames_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().names()
    }
}

struct TerminalQuoteThumbnail_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().quoteThumbnail()
    }
}

struct TerminalMedia_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().media()
    }
}

struct TerminalRightToLeft_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().rightToLeft()
    }
}

struct TerminalRuleOnly_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().ruleOnly()
    }
}

struct TerminalSpacing_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().spacing()
    }
}

struct TerminalAvatars_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().avatars(terminal: true)
    }
}

struct ClassicAvatars_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().avatars(terminal: false)
    }
}

struct TerminalOverviewDirect_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().overviewDirect(terminal: true)
    }
}

struct ClassicOverviewDirect_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().overviewDirect(terminal: false)
    }
}

struct TerminalOverviewGroup_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().overviewGroup(terminal: true)
    }
}

struct ClassicOverviewGroup_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().overviewGroup(terminal: false)
    }
}

struct TerminalOverviewChannel_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().overviewChannel(terminal: true)
    }
}

struct ClassicOverviewChannel_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().overviewChannel(terminal: false)
    }
}

struct ClassicParagraphs_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().paragraphs()
    }
}

private struct ChatRows: View {
    @EnvironmentObject var theme: AppTheme
    let chat: Chat
    let im: ItemsModel
    let mergedItems: MergedItems
    let terminal: Bool
    var selected: Set<Int64>? = nil

    private var width: CGFloat {
        UIScreen.main.bounds.width
    }

    var body: some View {
        let wallpaperImage = theme.wallpaper.type.image
        let wallpaperType = theme.wallpaper.type
        let backgroundColor = theme.wallpaper.background ?? wallpaperType.defaultBackgroundColor(theme.base, theme.colors.background)
        let tintColor = theme.wallpaper.tint ?? wallpaperType.defaultTintColor(theme.base)
        let items = mergedItems.items
        VStack(spacing: 0) {
            ForEach(Array(items.indices.reversed()), id: \.self) { index in
                row(index, items[index]).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .frame(width: width)
        .background {
            if terminal {
                backgroundColor
            } else if let wallpaperImage {
                Color.clear.modifier(ChatViewBackground(image: wallpaperImage, imageType: wallpaperType, background: backgroundColor, tint: tintColor))
            } else {
                theme.colors.background
            }
        }
    }

    func row(_ index: Int, _ mergedItem: MergedItem) -> some View {
        let ci = switch mergedItem {
        case let .single(item, _, _): item.item
        case let .grouped(items, _, _, _, _, _, _, _): items.boxedValue.last!.item
        }
        return ChatView.ChatItemWithMenu(
            im: im,
            chat: chat,
            index: index,
            isLastItem: index == mergedItems.items.count - 1,
            chatItem: ci,
            scrollToItem: { _ in },
            scrollToItemId: .constant(nil),
            merged: mergedItem,
            olderRow: mergedItems.items.indices.contains(index + 1) ? mergedItems.items[index + 1] : nil,
            listWidth: width,
            maxWidth: rowMaxWidth(ci, mergedItem, chat.chatInfo, width),
            channelTable: PopopxBubbleChannelTable(channels: [:]),
            composeState: .constant(ComposeState()),
            selectedMember: .constant(nil),
            showChatInfoSheet: .constant(false),
            revealedItems: .constant([]),
            selectedChatItems: .constant(selected),
            forwardedChatItems: .constant([]),
            searchText: .constant(""),
            contentFilter: .constant(nil),
            closeKeyboardAndRun: { $0() }
        )
        .environment(\.terminalLayout, terminal)
    }
}

private func rowMaxWidth(_ ci: ChatItem, _ merged: MergedItem, _ cInfo: ChatInfo, _ width: CGFloat) -> CGFloat {
    let voiceNoFrame = ci.content.msgContent?.isVoice == true && ci.content.text.count == 0 && ci.quotedItem == nil && ci.meta.itemForwarded == nil
    let channelReceived = !ci.chatDir.sent && cInfo.isChannel
    let channelReceivedNoAvatar = channelReceived && !showsAvatar(merged.newest().item, merged.oldest().nextItem)
    let avatarColumn = scaledMemberImageSize(DynamicTypeSize(UIApplication.shared.preferredContentSizeCategory) ?? .large) + 8
    return cInfo.chatType == .group
    ? channelReceivedNoAvatar
    ? width - 26
    : voiceNoFrame || channelReceived
    ? (width - 28) - avatarColumn
    : (width - 28) * 0.84 - avatarColumn
    : voiceNoFrame
    ? (width - 32)
    : (width - 32) * 0.84
}

private func showsAvatar(_ current: ChatItem, _ older: ChatItem?) -> Bool {
    let oldIsGroupRcv = switch older?.chatDir {
    case .groupRcv: true
    case .channelRcv: true
    default: false
    }
    let sameMember = switch (older?.chatDir, current.chatDir) {
    case let (.groupRcv(oldMember), .groupRcv(member)): oldMember.memberId == member.memberId
    case (.channelRcv, .channelRcv): true
    default: false
    }
    return switch current.chatDir {
    case .groupRcv, .channelRcv: older == nil || !oldIsGroupRcv || !sameMember
    default: false
    }
}

private func imageBase64(_ color: UIColor, _ size: CGSize) -> String {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
        color.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        UIColor.white.withAlphaComponent(0.4).setFill()
        ctx.cgContext.fillEllipse(in: CGRect(x: size.width * 0.55, y: size.height * 0.15, width: size.height * 0.4, height: size.height * 0.4))
    }
    return "data:image/jpg;base64," + (image.jpegData(compressionQuality: 0.8)?.base64EncodedString() ?? "")
}

private final class SnapshotFixtures {
    private var nextId: Int64 = 1
    let photo = imageBase64(UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1), CGSize(width: 120, height: 80))
    let landscape = imageBase64(UIColor(red: 0.25, green: 0.55, blue: 0.35, alpha: 1), CGSize(width: 320, height: 200))
    let alice: GroupMember
    let bob: GroupMember
    let carol: GroupMember
    let team: GroupInfo
    let news: GroupInfo
    let contact: Contact
    private let markdown: [String: ParsedMarkdown] = [
        "https://popopx.chat": ParsedMarkdown(formattedText: [
            FormattedText(text: "https://popopx.chat", format: .uri)
        ]),
        "---": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "---", format: .markup(token: .ruleMark))
            ],
            markdownBlocks: [
                .rule(mark: SegmentRange(from: 0, to: 1))
            ]
        ),
        "Hi! Did you see the **new release**?": ParsedMarkdown(formattedText: [
            FormattedText(text: "Hi! Did you see the "),
            FormattedText(text: "new release", format: .bold(singleStar: false)),
            FormattedText(text: "?")
        ]),
        "Yes, *great* changes 🎉": ParsedMarkdown(formattedText: [
            FormattedText(text: "Yes, "),
            FormattedText(text: "great", format: .bold(singleStar: true)),
            FormattedText(text: " changes 🎉")
        ]),
        "# Release notes\n- terminal layout\n- `code` blocks\n\n> quoted line": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "# ", format: .markup(token: .headingMark(level: 1))),
                FormattedText(text: "Release notes"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "- ", format: .markup(token: .listMark(number: nil))),
                FormattedText(text: "terminal layout"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "- ", format: .markup(token: .listMark(number: nil))),
                FormattedText(text: "code", format: .snippet),
                FormattedText(text: " blocks"),
                FormattedText(text: "\n\n", format: .markup(token: .paragraphBreak(lineBreaks: 2))),
                FormattedText(text: "> ", format: .markup(token: .quoteMark)),
                FormattedText(text: "quoted line")
            ],
            markdownBlocks: [
                .heading(level: 1, content: SegmentRange(from: 1, to: 2)),
                .list(items: [
                    ListEntry(number: nil, content: SegmentRange(from: 4, to: 5), items: []),
                    ListEntry(number: nil, content: SegmentRange(from: 7, to: 9), items: [])
                ]),
                .quote(content: SegmentRange(from: 11, to: 12))
            ]
        ),
        "### Gaps\n\none empty line above\n\n\ntwo empty lines above\n\n### After one empty line\n- list entry\n\n- after one empty line\n\n": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "### ", format: .markup(token: .headingMark(level: 3))),
                FormattedText(text: "Gaps"),
                FormattedText(text: "\n\n", format: .markup(token: .paragraphBreak(lineBreaks: 2))),
                FormattedText(text: "one empty line above"),
                FormattedText(text: "\n\n\n", format: .markup(token: .paragraphBreak(lineBreaks: 3))),
                FormattedText(text: "two empty lines above"),
                FormattedText(text: "\n\n", format: .markup(token: .paragraphBreak(lineBreaks: 2))),
                FormattedText(text: "### ", format: .markup(token: .headingMark(level: 3))),
                FormattedText(text: "After one empty line"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "- ", format: .markup(token: .listMark(number: nil))),
                FormattedText(text: "list entry"),
                FormattedText(text: "\n\n", format: .markup(token: .paragraphBreak(lineBreaks: 2))),
                FormattedText(text: "- ", format: .markup(token: .listMark(number: nil))),
                FormattedText(text: "after one empty line"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak))
            ],
            markdownBlocks: [
                .heading(level: 3, content: SegmentRange(from: 1, to: 2)),
                .paragraph(content: SegmentRange(from: 3, to: 4)),
                .paragraph(content: SegmentRange(from: 5, to: 6)),
                .heading(level: 3, content: SegmentRange(from: 8, to: 9)),
                .list(items: [
                    ListEntry(number: nil, content: SegmentRange(from: 11, to: 12), items: []),
                    ListEntry(number: nil, content: SegmentRange(from: 14, to: 15), items: [])
                ])
            ]
        ),
        "first part\n\nafter one empty line\n\n\nafter two empty lines": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "first part"),
                FormattedText(text: "\n\n", format: .markup(token: .paragraphBreak(lineBreaks: 2))),
                FormattedText(text: "after one empty line"),
                FormattedText(text: "\n\n\n", format: .markup(token: .paragraphBreak(lineBreaks: 3))),
                FormattedText(text: "after two empty lines")
            ],
            markdownBlocks: [
                .paragraph(content: SegmentRange(from: 0, to: 1)),
                .paragraph(content: SegmentRange(from: 2, to: 3)),
                .paragraph(content: SegmentRange(from: 4, to: 5))
            ]
        ),
        "\nlinks to a scam site": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "\n", format: .markup(token: .paragraphBreak(lineBreaks: 1))),
                FormattedText(text: "links to a scam site")
            ],
            markdownBlocks: [
                .paragraph(content: SegmentRange(from: 1, to: 2))
            ]
        ),
        "\nafter an empty line": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "\n", format: .markup(token: .paragraphBreak(lineBreaks: 1))),
                FormattedText(text: "after an empty line")
            ],
            markdownBlocks: [
                .paragraph(content: SegmentRange(from: 1, to: 2))
            ]
        ),
        "  \nafter a line of spaces": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "  \n", format: .markup(token: .paragraphBreak(lineBreaks: 1))),
                FormattedText(text: "after a line of spaces")
            ],
            markdownBlocks: [
                .paragraph(content: SegmentRange(from: 1, to: 2))
            ]
        ),
        "Plan for today:\n1. review\n2. **release**": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "Plan for today:"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "1. ", format: .markup(token: .listMark(number: "1."))),
                FormattedText(text: "review"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "2. ", format: .markup(token: .listMark(number: "2."))),
                FormattedText(text: "release", format: .bold(singleStar: false))
            ],
            markdownBlocks: [
                .paragraph(content: SegmentRange(from: 0, to: 1)),
                .list(items: [
                    ListEntry(number: "1.", content: SegmentRange(from: 3, to: 4), items: []),
                    ListEntry(number: "2.", content: SegmentRange(from: 6, to: 7), items: [])
                ])
            ]
        ),
        "**Version 7.1** is out": ParsedMarkdown(formattedText: [
            FormattedText(text: "Version 7.1", format: .bold(singleStar: false)),
            FormattedText(text: " is out")
        ]),
        "## What's new\n- terminal layout\n- faster sync": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "## ", format: .markup(token: .headingMark(level: 2))),
                FormattedText(text: "What's new"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "- ", format: .markup(token: .listMark(number: nil))),
                FormattedText(text: "terminal layout"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "- ", format: .markup(token: .listMark(number: nil))),
                FormattedText(text: "faster sync")
            ],
            markdownBlocks: [
                .heading(level: 2, content: SegmentRange(from: 1, to: 2)),
                .list(items: [
                    ListEntry(number: nil, content: SegmentRange(from: 4, to: 5), items: []),
                    ListEntry(number: nil, content: SegmentRange(from: 7, to: 8), items: [])
                ])
            ]
        ),
        "run this one first:\n```\nnpm run publish\n```": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "run this one first:"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "```", format: .markup(token: .fenceMark(language: nil))),
                FormattedText(text: "\n", format: .markup(token: .hardBreak)),
                FormattedText(text: "npm run publish"),
                FormattedText(text: "\n", format: .markup(token: .hardBreak)),
                FormattedText(text: "```", format: .markup(token: .fenceMark(language: nil)))
            ],
            markdownBlocks: [
                .paragraph(content: SegmentRange(from: 0, to: 1)),
                .codeBlock(language: nil, content: SegmentRange(from: 4, to: 5))
            ]
        ),
        "# מה חדש\nגרסה חדשה של האפליקציה\n## תכונות\n| שינוי |\n|---|": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "# ", format: .markup(token: .headingMark(level: 1))),
                FormattedText(text: "מה חדש"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "גרסה חדשה של האפליקציה"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "## ", format: .markup(token: .headingMark(level: 2))),
                FormattedText(text: "תכונות"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "| ", format: .markup(token: .rowMark)),
                FormattedText(text: "שינוי"),
                FormattedText(text: " |", format: .markup(token: .cellMark)),
                FormattedText(text: "\n", format: .markup(token: .hardBreak)),
                FormattedText(text: "|---|", format: .markup(token: .delimiterRow(columns: [.none])))
            ],
            markdownBlocks: [
                .heading(level: 1, content: SegmentRange(from: 1, to: 2)),
                .paragraph(content: SegmentRange(from: 3, to: 4)),
                .heading(level: 2, content: SegmentRange(from: 6, to: 7)),
                .table(columns: [.none], header: [SegmentRange(from: 9, to: 10)], rows: [])
            ]
        )
    ]

    init() {
        alice = Self.member(2, "alice", .admin, image: imageBase64(UIColor(red: 0.85, green: 0.45, blue: 0.3, alpha: 1), CGSize(width: 64, height: 64)))
        bob = Self.member(3, "bob", .member)
        carol = Self.member(4, "carol", .member, image: imageBase64(UIColor(red: 0.55, green: 0.35, blue: 0.75, alpha: 1), CGSize(width: 64, height: 64)))
        team = Self.group(1, "team", channel: false)
        news = Self.group(2, "SimpleX news", channel: true)
        var c = Contact.sampleData
        c.profile = LocalProfile(profileId: 2, displayName: "bob", fullName: "", localAlias: "")
        c.localDisplayName = "bob"
        contact = c
    }

    private static func member(_ id: Int64, _ name: String, _ role: GroupMemberRole, image: String? = nil) -> GroupMember {
        var m = GroupMember.sampleData
        m.groupMemberId = id
        m.memberId = "member-\(id)"
        m.memberRole = role
        m.localDisplayName = name
        m.memberProfile = LocalProfile(profileId: id, displayName: name, fullName: "", image: image, localAlias: "")
        return m
    }

    private static func group(_ id: Int64, _ name: String, channel: Bool) -> GroupInfo {
        var g = GroupInfo.sampleData
        g.groupId = id
        g.localDisplayName = name
        g.groupProfile = GroupProfile(displayName: name, fullName: "")
        if channel {
            g.useRelays = true
            g.groupProfile.publicGroup = PublicGroupProfile(groupType: .channel, groupLink: "", publicGroupId: "channel-\(id)")
        }
        g.membership = member(99, "me", .member)
        return g
    }

    private func id() -> Int64 {
        nextId += 1
        return nextId
    }

    private func ts(_ minutes: Double) -> Date {
        previewDate.addingTimeInterval(minutes * 60)
    }

    private func msg(_ dir: CIDirection, _ text: String, _ minutes: Double, quote: CIQuote? = nil, reactions: [CIReactionCount] = [], content: MsgContent? = nil, file: CIFile? = nil) -> ChatItem {
        let parsed = markdown[text]
        let mc = content ?? .text(text)
        return ChatItem(
            chatDir: dir,
            meta: CIMeta.getSample(id(), ts(minutes), text, dir.sent ? .sndSent(sndProgress: .complete) : .rcvRead),
            content: dir.sent ? .sndMsgContent(msgContent: mc) : .rcvMsgContent(msgContent: mc),
            formattedText: parsed?.formattedText,
            markdownBlocks: parsed?.markdownBlocks,
            quotedItem: quote,
            reactions: reactions,
            file: file
        )
    }

    private func event(_ dir: CIDirection, _ content: CIContent, _ minutes: Double) -> ChatItem {
        ChatItem(chatDir: dir, meta: CIMeta.getSample(id(), ts(minutes), content.text, .rcvRead), content: content)
    }

    private func quote(_ dir: CIDirection?, _ text: String, image: String? = nil) -> CIQuote {
        let parsed = markdown[text]
        return CIQuote(
            chatDir: dir,
            itemId: 1,
            sentAt: ts(-300),
            content: image.map { .image(text: text, image: $0) } ?? .text(text),
            formattedText: parsed?.formattedText,
            markdownBlocks: parsed?.markdownBlocks
        )
    }

    private func reaction(_ emoji: MREmojiChar, _ count: Int, mine: Bool = false) -> CIReactionCount {
        CIReactionCount(reaction: .emoji(emoji: emoji), userReacted: mine, totalReacted: count)
    }

    private func imageFile(_ name: String) -> CIFile {
        CIFile.getSample(fileId: id(), fileName: name, fileSize: 184_320, filePath: nil, fileStatus: .rcvInvitation)
    }

    private func chatRows(_ chatInfo: ChatInfo, _ items: [ChatItem], terminal: Bool, selected: Set<Int64>? = nil) -> ChatRows {
        let im = ItemsModel(secondaryIMFilter: nil)
        im.reversedChatItems = items.reversed()
        let merged = MergedItems.create(im, [])
        return ChatRows(chat: Chat(chatInfo: chatInfo), im: im, mergedItems: merged, terminal: terminal, selected: selected)
    }

    private var direct: ChatInfo { .direct(contact: contact) }
    private var teamChat: ChatInfo { .group(groupInfo: team, groupChatScope: nil) }
    private var newsChat: ChatInfo { .group(groupInfo: news, groupChatScope: nil) }

    func names() -> some View {
        chatRows(teamChat, [
            msg(.groupRcv(groupMember: alice), "Hi everyone, the build is green.", -30),
            msg(.groupRcv(groupMember: alice), "Release notes are in the channel.", -29),
            msg(.groupRcv(groupMember: bob), "Great, thanks!", -20, quote: quote(.groupRcv(groupMember: alice), "Hi everyone, the build is green.")),
            msg(.groupSnd, "I will check the release notes today.", -10)
        ], terminal: true)
    }

    func quoteThumbnail() -> some View {
        chatRows(direct, [
            msg(.directRcv, "nice", -10, quote: quote(.directSnd, "photo", image: photo)),
            msg(.directRcv, "a longer reply that wraps over two lines in the terminal row below the quote with the image", -9, quote: quote(.directSnd, "a long caption of the quoted image that wraps over more than one line of the quote", image: photo)),
            msg(.directRcv, "ok", -8, quote: quote(.directRcv, "", image: photo)),
            msg(.directRcv, "a reply wider than the quote above it, so that the quote is narrower than the item", -7, quote: quote(.directSnd, "photo", image: photo)),
            msg(.directRcv, "a reply a bit wider than its quote", -6, quote: quote(.directSnd, "photo", image: photo))
        ], terminal: true)
    }

    func media() -> some View {
        let link = MsgContent.link(text: "https://popopx.chat", preview: LinkPreview(uri: "https://popopx.chat", title: "SimpleX Chat: private and secure messenger without any user IDs", image: landscape))
        return VStack(spacing: 0) {
            chatRows(direct, [
                msg(.directRcv, "https://popopx.chat", -20, content: link)
            ], terminal: true)
            chatRows(newsChat, [
                msg(.channelRcv, "Links and videos", -12),
                msg(.channelRcv, "https://popopx.chat", -11, content: link),
                msg(.channelRcv, "", -10, content: .video(text: "", image: landscape, duration: 42), file: CIFile.getSample(fileId: id(), fileName: "video.mp4", fileSize: 1_048_576, filePath: nil, fileStatus: .rcvInvitation))
            ], terminal: true)
            chatRows(newsChat, [
                msg(.channelRcv, "Selected post", -5, content: .image(text: "Selected post", image: landscape), file: imageFile("post.jpg"))
            ], terminal: true, selected: [])
        }
    }

    func rightToLeft() -> some View {
        chatRows(direct, [
            msg(.directRcv, "# מה חדש\nגרסה חדשה של האפליקציה\n## תכונות\n| שינוי |\n|---|", -10)
        ], terminal: true)
    }

    func ruleOnly() -> some View {
        chatRows(direct, [
            msg(.directRcv, "---", -10),
            msg(.directRcv, "---", -9, quote: quote(.directSnd, "a quoted message that is much wider than the rule")),
            msg(.directRcv, "---", -8, content: .report(text: "---", reason: .spam))
        ], terminal: true)
    }

    func avatars(terminal: Bool) -> some View {
        chatRows(teamChat, [
            msg(.groupRcv(groupMember: alice), "Morning! Who is joining the call?", -40),
            msg(.groupRcv(groupMember: bob), "I am", -38),
            msg(.groupRcv(groupMember: bob), "Starting in 5 minutes", -37),
            msg(.groupRcv(groupMember: carol), "Count me in, a bit late", -35),
            msg(.groupSnd, "Great", -30)
        ], terminal: terminal)
    }

    func spacingItems() -> [ChatItem] {
        [
            event(.groupRcv(groupMember: carol), .rcvGroupEvent(rcvGroupEvent: .memberConnected), -130),
            msg(.groupRcv(groupMember: alice), "Welcome, carol!", -120),
            msg(.groupRcv(groupMember: carol), "Thanks! Glad to be here", -118),
            msg(.groupRcv(groupMember: carol), "ok", -118 + 20.0 / 60, reactions: [reaction(.heart, 2)]),
            msg(.groupRcv(groupMember: carol), "one question", -118 + 40.0 / 60),
            msg(.groupRcv(groupMember: bob), "I pushed the release build, please check it on your phones", -105),
            msg(.groupRcv(groupMember: bob), "done", -104.5),
            msg(.groupRcv(groupMember: alice), "first part\n\nafter one empty line\n\n\nafter two empty lines", -90),
            msg(.groupRcv(groupMember: alice), "and one more thing", -89.5),
            msg(.groupRcv(groupMember: alice), "after a pause of eight minutes", -81.5),
            msg(.groupRcv(groupMember: bob), "", -80, reactions: [reaction(.heart, 2)], content: .image(text: "", image: landscape), file: imageFile("view.jpg")),
            msg(.groupSnd, "👍", -79),
            msg(.groupSnd, "nice view", -78.5, quote: quote(.groupRcv(groupMember: bob), "", image: landscape)),
            msg(.groupRcv(groupMember: carol), "run this one first:\n```\nnpm run publish\n```", -70, reactions: [reaction(.thumbsup, 1)])
        ]
    }

    func spacing() -> some View {
        chatRows(teamChat, spacingItems(), terminal: true)
    }

    func paragraphs() -> some View {
        let text = "first part\n\nafter one empty line\n\n\nafter two empty lines"
        var oneText = msg(.directRcv, text, -9)
        oneText.formattedText = nil
        oneText.markdownBlocks = nil
        return chatRows(direct, [msg(.directRcv, text, -10), oneText], terminal: false)
    }

    func spacingEdgeItems() -> [ChatItem] {
        let reported = quote(.groupRcv(groupMember: alice), "Welcome, carol!")
        return [
            msg(.groupRcv(groupMember: bob), "👍", -10, content: .unknown(type: "sticker", text: "👍")),
            msg(.groupSnd, "\nlinks to a scam site", -9, quote: reported, content: .report(text: "\nlinks to a scam site", reason: .spam)),
            msg(.groupSnd, "\nafter an empty line", -8, quote: reported),
            msg(.groupSnd, "  \nafter a line of spaces", -7, quote: reported)
        ]
    }

    func overviewDirect(terminal: Bool) -> ChatRows {
        chatRows(direct, [
            event(.directRcv, .rcvChatFeature(feature: .voice, enabled: FeatureEnabled(forUser: true, forContact: true), param: nil), -120),
            msg(.directRcv, "Hi! Did you see the **new release**?", -60),
            msg(.directSnd, "Yes, *great* changes 🎉", -58, reactions: [reaction(.thumbsup, 1)]),
            msg(.directRcv, "# Release notes\n- terminal layout\n- `code` blocks\n\n> quoted line", -50),
            msg(.directRcv, "### Gaps\n\none empty line above\n\n\ntwo empty lines above\n\n### After one empty line\n- list entry\n\n- after one empty line\n\n", -48),
            msg(.directSnd, "Thanks for the summary", -45, quote: quote(.directRcv, "Release notes")),
            msg(.directRcv, "", -40, content: .image(text: "", image: landscape), file: imageFile("photo.jpg")),
            msg(.directRcv, "", -35, content: .file(""), file: CIFile.getSample(fileId: id(), fileName: "report.pdf", fileSize: 245_760, filePath: nil, fileStatus: .rcvInvitation)),
            msg(.directSnd, "", -30, content: .voice(text: "", duration: 12), file: CIFile.getSample(fileId: id(), fileName: "voice.m4a", fileSize: 20_480, filePath: nil, fileStatus: .sndComplete))
        ], terminal: terminal)
    }

    func overviewGroup(terminal: Bool) -> ChatRows {
        chatRows(teamChat, [
            event(.groupRcv(groupMember: carol), .rcvGroupEvent(rcvGroupEvent: .memberConnected), -130),
            msg(.groupRcv(groupMember: alice), "Welcome, carol!", -120, reactions: [reaction(.heart, 2, mine: true)]),
            msg(.groupRcv(groupMember: carol), "Thanks! Glad to be here", -118),
            msg(.groupRcv(groupMember: bob), "", -100, content: .image(text: "", image: landscape), file: imageFile("view.jpg")),
            msg(.groupSnd, "nice view", -95, quote: quote(.groupRcv(groupMember: bob), "", image: landscape)),
            msg(.groupRcv(groupMember: alice), "Plan for today:\n1. review\n2. **release**", -90),
            msg(.groupRcv(groupMember: bob), "", -80, content: .voice(text: "", duration: 21), file: CIFile.getSample(fileId: id(), fileName: "voice.m4a", fileSize: 30_720, filePath: nil, fileStatus: .rcvInvitation)),
            msg(.groupRcv(groupMember: carol), "", -70, content: .file(""), file: CIFile.getSample(fileId: id(), fileName: "notes.txt", fileSize: 2_048, filePath: nil, fileStatus: .rcvInvitation))
        ], terminal: terminal)
    }

    func overviewChannel(terminal: Bool) -> ChatRows {
        chatRows(newsChat, [
            event(.channelRcv, .rcvGroupEvent(rcvGroupEvent: .groupUpdated(groupProfile: news.groupProfile)), -210),
            msg(.channelRcv, "**Version 7.1** is out", -200, reactions: [reaction(.thumbsup, 12), reaction(.heart, 5, mine: true)]),
            msg(.channelRcv, "## What's new\n- terminal layout\n- faster sync", -190),
            msg(.channelRcv, "Screenshot of the new layout", -180, content: .image(text: "Screenshot of the new layout", image: landscape), file: imageFile("screenshot.jpg"))
        ], terminal: terminal)
    }
}


// MARK: - PopopxLocationPayload

/// Encoding and decoding of the location payload, run against the type the app actually ships.
///
/// **Why this file**: `Tests iOS` is `com.apple.product-type.bundle.ui-testing` (it drives `XCUIApplication`, so it cannot see
/// an internal app type at all), and `POPOPX Snapshots` is the one target in the project that is
/// `com.apple.product-type.bundle.unit-test` with `TEST_HOST`/`BUNDLE_LOADER` pointing at `POPOPX.app` - which is exactly what
/// `@testable import POPOPX` at the top of this file needs. Adding a new test file would mean a `.pbxproj` entry, and that is a
/// red line, so the cases land here, in the file the project already mounts.
///
/// Nothing below touches MapKit, CoreLocation or a view: `wireString` escapes every field through the `.alphanumerics`
/// allowlist, so both directions are pure string arithmetic. Run it with
/// `xcodebuild test -scheme "POPOPX (iOS)" -only-testing:"POPOPX Snapshots/PopopxLocationPayloadTests"`.
final class PopopxLocationPayloadTests: XCTestCase {

    /// The two directions of one payload have to agree, on the wire line and on the whole two-line message.
    private func assertRoundTrip(
        _ payload: PopopxLocationPayload,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(PopopxLocationPayload.parse(from: payload.wireString),
                       payload as PopopxLocationPayload?,
                       "wire: \(payload.wireString)",
                       file: file, line: line)
        XCTAssertEqual(PopopxLocationPayload.parse(from: payload.messageContent),
                       payload as PopopxLocationPayload?,
                       "message: \(payload.messageContent)",
                       file: file, line: line)
    }

    // MARK: Encoding

    func testEncodeFixedSixDigitsLatitudeFirst() throws {
        XCTAssertEqual(
            PopopxLocationPayload(latitude: 22.543096, longitude: 114.057865).wireString,
            "popopx://loc?lat=22.543096&lon=114.057865"
        )
    }

    func testEncodePadsShorterPrecisionAndKeepsTheSign() throws {
        XCTAssertEqual(
            PopopxLocationPayload(latitude: 22.5, longitude: -114.125, name: "Home").wireString,
            "popopx://loc?lat=22.500000&lon=-114.125000&name=Home"
        )
    }

    func testEncodeFieldOrderIsLatLonNameAddr() throws {
        XCTAssertEqual(
            PopopxLocationPayload(latitude: 1, longitude: 2, name: "n", address: "a").wireString,
            "popopx://loc?lat=1.000000&lon=2.000000&name=n&addr=a"
        )
    }

    func testCoordinateStringAndKeyShareTheWiresSpelling() throws {
        let payload = PopopxLocationPayload(latitude: 22.543096, longitude: 114.057865)
        XCTAssertEqual(payload.coordinateString, "(22.543096, 114.057865)")
        XCTAssertEqual(payload.coordinateKey, "22.543096,114.057865")
        XCTAssertTrue(payload.wireString.contains("lat=22.543096"), payload.wireString)
        XCTAssertTrue(payload.wireString.contains("lon=114.057865"), payload.wireString)
    }

    func testWhitespaceOnlyFieldsBecomeNil() throws {
        let payload = PopopxLocationPayload(latitude: 0, longitude: 0, name: "  \n\t ", address: " x ")
        XCTAssertNil(payload.name)
        XCTAssertEqual(payload.address, "x")
        XCTAssertEqual(payload.wireString, "popopx://loc?lat=0.000000&lon=0.000000&addr=x")
    }

    func testDisplayNameFallsBackToCoordinates() throws {
        XCTAssertEqual(PopopxLocationPayload(latitude: 0, longitude: 0).displayName, "(0.000000, 0.000000)")
        XCTAssertEqual(PopopxLocationPayload(latitude: 0, longitude: 0, name: "Café").displayName, "Café")
    }

    func testMessageContentIsExactlyTwoLines() throws {
        let payload = PopopxLocationPayload(latitude: 22.543096, longitude: 114.057865, name: "Shop")
        let lines = payload.messageContent.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.last, Substring(payload.wireString))
        XCTAssertTrue(lines.first!.hasPrefix("📍"))
        XCTAssertTrue(lines.first!.contains("Shop"))
        XCTAssertTrue(lines.first!.contains(payload.coordinateString))
    }

    func testNewlinesInsideAPlaceNameCannotStretchTheMessage() throws {
        let payload = PopopxLocationPayload(latitude: 1, longitude: 2, name: "Home\n  Road", address: "Block\t7\nAnnex")
        XCTAssertEqual(payload.name, "Home Road")
        XCTAssertEqual(payload.address, "Block 7 Annex")
        XCTAssertEqual(payload.messageContent.split(separator: "\n", omittingEmptySubsequences: false).count, 2)
        assertRoundTrip(payload)
    }

    // MARK: Round trip

    func testRoundTripOfFieldValuesThatCouldBreakTheEncoding() throws {
        let cases: [(name: String?, address: String?)] = [
            ("Shenzhen North Railway Station", nil),
            ("深圳北站", "深圳市南山区"),
            ("Tom & Jerry", nil),
            ("Block #7", nil),
            ("a=b", nil),
            ("+7 380", nil),
            ("He said \"here\"", nil),
            ("Home / Work", nil),
            ("%", nil),
            ("a?b", nil),
            ("10% off", "25% Street & 5th Ave"),
            ("🏠", nil),
            ("Café ⌘", nil),
            ("Münchner Straße 14", "Bruder Str. 14, 10797 Berlin"),
            ("popopx://loc?lat=0&lon=0", nil),
            ("📍 marked", nil),
            ("", nil),
            (nil, "Only an address"),
            (nil, nil)
        ]
        for pair in cases {
            assertRoundTrip(PopopxLocationPayload(latitude: 48.858370, longitude: 2.294481,
                                                  name: pair.name, address: pair.address))
        }
    }

    func testRoundTripOfRangeLimits() throws {
        for coordinate in [(90.0, 180.0), (-90.0, -180.0), (0.0, 0.0), (89.999999, -179.999999)] {
            let payload = PopopxLocationPayload(latitude: coordinate.0, longitude: coordinate.1, name: "Edge")
            assertRoundTrip(payload)
        }
    }

    func testSixDigitsIsTheContractsPrecisionSoAFinerInputRounds() throws {
        // `%.6f` rounds 89.9999999 up to 90.000000: still inside the range, still a valid payload.
        let payload = PopopxLocationPayload(latitude: 89.9999999, longitude: -179.9999999)
        XCTAssertEqual(payload.wireString, "popopx://loc?lat=90.000000&lon=-180.000000")
        let decoded = try XCTUnwrap(PopopxLocationPayload.parse(from: payload.wireString))
        XCTAssertEqual(decoded.latitude, 90.0)
        XCTAssertEqual(decoded.longitude, -180.0)
    }

    func testRecognizesThePayloadEmbeddedInASentence() throws {
        let payload = PopopxLocationPayload(latitude: 48.858370, longitude: 2.294481, name: "Tour Eiffel")
        let wire = payload.wireString
        for text in ["\(wire)", "meet me at \(wire) tonight", "note\n\(wire)\nthanks", "  \(wire)   "] {
            XCTAssertEqual(PopopxLocationPayload.parse(from: text), payload as PopopxLocationPayload?, text)
        }
    }

    func testSeveralCandidatesTakeTheLastOne() throws {
        let decoded = try XCTUnwrap(
            PopopxLocationPayload.parse(from: "popopx://loc?lat=1&lon=2 name popopx://loc?lat=3&lon=4")
        )
        XCTAssertEqual(decoded.latitude, 3)
        XCTAssertEqual(decoded.longitude, 4)
    }

    func testTheMachineLineWinsEvenWhenTheReadableLineCarriesACoordinate() throws {
        let payload = PopopxLocationPayload(latitude: 52.52, longitude: 13.405, name: "popopx://loc?lat=0&lon=0")
        let decoded = try XCTUnwrap(PopopxLocationPayload.parse(from: payload.messageContent))
        XCTAssertEqual(decoded.latitude, 52.52, "taking the first candidate would report the coordinates hidden in the place name")
        XCTAssertEqual(decoded.longitude, 13.405)
        XCTAssertEqual(decoded.name, payload.name)
    }

    func testVoucherLineDoesNotHideTheLocationPayload() throws {
        let payload = PopopxLocationPayload(latitude: 52.52, longitude: 13.405, name: "Shop")
        let text = payload.messageContent + "\npopopx://voucher?id=v1&n=2&sig=ab"
        XCTAssertEqual(PopopxLocationPayload.parse(from: text), payload as PopopxLocationPayload?, text)
    }

    // MARK: Rejection

    func testRejectsOutOfRangeCoordinates() throws {
        let queries = ["lat=91&lon=0", "lat=-91&lon=0", "lat=0&lon=181", "lat=0&lon=-181",
                       "lat=90.000001&lon=0", "lat=0&lon=180.000001", "lat=1e9&lon=0", "lat=0&lon=1e9",
                       "lat=+91&lon=0"]
        for query in queries {
            XCTAssertNil(PopopxLocationPayload.parse(from: "popopx://loc?\(query)"), query)
        }
    }

    func testRejectsNonFiniteCoordinates() throws {
        let queries = ["lat=nan&lon=0", "lat=0&lon=nan", "lat=NaN&lon=0", "lat=inf&lon=0", "lat=-inf&lon=0",
                       "lat=0&lon=inf", "lat=infinity&lon=0", "lat=1e999&lon=0", "lat=-1e999&lon=0"]
        for query in queries {
            XCTAssertNil(PopopxLocationPayload.parse(from: "popopx://loc?\(query)"), query)
        }
    }

    func testRejectsMissingOrUnparsableCoordinates() throws {
        let queries = ["lon=0", "lat=0", "lat=0&lon=", "lat=&lon=0", "lat", "lat=abc&lon=0", "lat=0&lon=x",
                       "addr=Somewhere"]
        for query in queries {
            XCTAssertNil(PopopxLocationPayload.parse(from: "popopx://loc?\(query)"), query)
        }
        XCTAssertNil(PopopxLocationPayload.parse(from: "popopx://loc"), "no query at all")
        XCTAssertNil(PopopxLocationPayload.parse(from: "popopx://loc?"), "empty query")
    }

    func testRejectsForeignSchemeAndHost() throws {
        let tokens = ["popox://loc?lat=0&lon=0", "https://loc?lat=0&lon=0", "http://popopx/loc",
                      "popopx://location?lat=0&lon=0", "popopx://locx?lat=0&lon=0", "popopx://loc2?lat=0&lon=0",
                      "popopx:/loc?lat=0&lon=0", "popopx://sec?lat=0&lon=0", "popopx://voucher?lat=0&lon=0"]
        for token in tokens {
            XCTAssertNil(PopopxLocationPayload.parse(from: token), token)
        }
    }

    func testIgnoresPlainAndEmptyText() throws {
        XCTAssertNil(PopopxLocationPayload.parse(from: ""))
        XCTAssertNil(PopopxLocationPayload.parse(from: "   \n\t "))
        XCTAssertNil(PopopxLocationPayload.parse(from: "no location here"))
        XCTAssertNil(PopopxLocationPayload.parse(from: "📍 [Location] Shenzhen (22.543096, 114.057865)"))
    }

    func testStrayKeysAreDroppedAndThePayloadStaysValid() throws {
        let decoded = try XCTUnwrap(
            PopopxLocationPayload.parse(from: "popopx://loc?lat=1&lon=2&sig=abc&token=xyz&name=n")
        )
        XCTAssertEqual(decoded.latitude, 1)
        XCTAssertEqual(decoded.longitude, 2)
        XCTAssertEqual(decoded.name, "n")
        XCTAssertNil(decoded.address)
    }

    func testEncodedKeyNamesCannotBypassTheWhitelist() throws {
        // `na%6De` decodes to `name`, but the whitelist compares the raw encoded bytes, so it never gets in.
        let decoded = try XCTUnwrap(
            PopopxLocationPayload.parse(from: "popopx://loc?lat=1&lon=2&na%6De=bypass")
        )
        XCTAssertNil(decoded.name)
    }

    func testRejectsSyntacticallyLegalButInvalidUtf8Escapes() throws {
        let queries = ["lat=0&lon=0&name=%C0%80", "lat=0&lon=0&name=%FF", "lat=0&lon=0&addr=%C0%80",
                       "lat=0&lon=0&name=abc%FFdef", "lat=0&lon=0&name=%ED%A0%80"]
        for query in queries {
            XCTAssertNil(PopopxLocationPayload.parse(from: "popopx://loc?\(query)"), query)
        }
    }

    func testAMalformedEscapeIsRepairedByUrlComponentsNotFatal() throws {
        // Documented in the header of PopopxLocation.swift: `%zz` comes back as the literal text, so the payload stays valid.
        let decoded = try XCTUnwrap(
            PopopxLocationPayload.parse(from: "popopx://loc?lat=1&lon=2&name=%zz")
        )
        XCTAssertEqual(decoded.name, "%zz")
    }
}

// MARK: - NODE_CMD silent signalling (round 15)

/// Pure tests for the `PopopxNodeCmd` wire format and the `PopopxNodeResultCard`
/// decoder. They run on the simulator with no device, no network, and no running API —
/// the router that suppresses these lines from chat bubbles is exercised separately.
///
/// Ruling 2026-11-21: written now, committed together with the spec/ anchor sweep
/// after the on-device walkthrough passes.
final class PopopxNodeCmdTests: XCTestCase {

    private let service = PopopxNodeServiceId.edgeComputeMesh

    // MARK: - init?(signalPayload:)

    func testSignalPayloadRoundTrip() throws {
        let cmd = PopopxNodeCmd(serviceId: service, action: "status", payload: "{\"ok\":true}")
        let decoded = try XCTUnwrap(PopopxNodeCmd(signalPayload: cmd.signalPayload))
        XCTAssertEqual(decoded.serviceId, service)
        XCTAssertEqual(decoded.action, "status")
        XCTAssertEqual(decoded.payload, "{\"ok\":true}")
    }

    func testWireStringRoundTrip() throws {
        let cmd = PopopxNodeCmd(serviceId: service, action: "result", payload: "{\"n\":7}")
        let decoded = try XCTUnwrap(PopopxNodeCmd(wireString: cmd.wireString))
        XCTAssertEqual(decoded, cmd)
    }

    func testInitRejectsUnknownServiceId() {
        XCTAssertNil(PopopxNodeCmd(signalPayload: "bogus_service::status::{}"))
    }

    func testInitRejectsEmptyAction() {
        XCTAssertNil(PopopxNodeCmd(signalPayload: "\(service.rawValue)::::{}"))
    }

    func testInitRejectsEmptyPayload() {
        XCTAssertNil(PopopxNodeCmd(signalPayload: "\(service.rawValue)::status::"))
    }

    func testInitRejectsTooFewSegments() {
        XCTAssertNil(PopopxNodeCmd(signalPayload: "\(service.rawValue)::status"))
    }

    func testInitRejectsGarbage() {
        XCTAssertNil(PopopxNodeCmd(signalPayload: ""))
        XCTAssertNil(PopopxNodeCmd(signalPayload: "::::"))
        XCTAssertNil(PopopxNodeCmd(wireString: "not a node command"))
        XCTAssertNil(PopopxNodeCmd(wireString: "\(PopopxNodeWire.commandPrefix)garbage"))
    }

    // MARK: - isAccepted

    func testIsAcceptedBoundary() {
        let good = PopopxNodeCmd(serviceId: service, action: "status", payload: "{\"ok\":true}")
        XCTAssertTrue(PopopxNodeWire.isAccepted(good))

        let noAction = PopopxNodeCmd(serviceId: service, action: "", payload: "{}")
        XCTAssertFalse(PopopxNodeWire.isAccepted(noAction))

        let noPayload = PopopxNodeCmd(serviceId: service, action: "status", payload: "")
        XCTAssertFalse(PopopxNodeWire.isAccepted(noPayload))
    }

    // MARK: - decode(command:now:)

    func testDecodeProducesCardWithServiceIdAndAction() {
        let cmd = PopopxNodeCmd(serviceId: service, action: "status", payload: "{\"n\":1}")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let card = PopopxNodeResultCard.decode(command: cmd, now: now)

        XCTAssertEqual(card.serviceId, service)
        XCTAssertEqual(card.headline, "status")
        XCTAssertEqual(card.detail, "{\"n\":1}")
        XCTAssertEqual(card.status, .succeeded)
        XCTAssertEqual(card.receivedAtMs, Int64(now.timeIntervalSince1970 * 1_000))
        XCTAssertTrue(card.id.hasPrefix("\(service.rawValue)."))
        XCTAssertNil(card.durationMilliseconds)
    }

    func testDecodeCardIsStableAcrossCalls() {
        let cmd = PopopxNodeCmd(serviceId: service, action: "result", payload: "{\"x\":1}")
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let a = PopopxNodeResultCard.decode(command: cmd, now: fixed)
        let b = PopopxNodeResultCard.decode(command: cmd, now: fixed)
        XCTAssertEqual(a, b, "decode is a pure function of (command, now); any drift means a hidden clock")
    }
}

/// Hand-written wire bodies.
///
/// Nothing in the app encodes this format, on purpose: the signature covers the bytes the generator emitted,
/// and a client that re-serialised a payload before comparing it would be testing its own encoder rather than
/// the contract. So the fixtures below are JSON text, the parser is the thing under test, and the order the
/// keys are emitted in is spelled out wherever a leg depends on it.
private enum Cfg {
    /// The kid of the production anchor, which is the only key `PopopxServerConfigTrust` lists. Deriving it is
    /// `PopopxServerConfigTrust.keyId(forPublicKeyHex:)`'s job; it is written out here so a leg that changes
    /// the anchor fails loudly instead of inheriting whatever the anchor happens to be.
    static let kid = "k-ad1dc5463a"
    static let key = "rWq7g9sYtLpQ4nJ3mKvB2xNcZeA8dF1hUiO6yT0sPbk"
    static let onion = "beccx4yfxxbvyhqypaavemqurytl6hozr47wfc7uuecacjqdvwpw2xid.onion"
    /// Fifty-four base32 characters instead of fifty-six: legal in the host field, whose rule is a suffix test,
    /// and illegal as the alternate address, whose rule is an exact length. Two different grammars for two
    /// different questions, recorded rather than smoothed over.
    static let onionShort = "ad6xhxrkmr26oa4xopzq3l7w2vz5pqupgblxhkyt3dhy3l7qfjgdbd.onion"
    static let iat = 1_760_000_000
    static let now = 1_760_086_400
    static let exp = 1_760_604_800
    /// Standard base64 of twenty zero bytes — what coturn recomputes an HMAC-SHA1 to. Padded, unlike everything
    /// else on this wire, because this value is spelled as the TURN server spells it.
    static let credential = "AAAAAAAAAAAAAAAAAAAAAA=="
    static let turn = #"{"t":"turns","h":"turn.simplex.im","p":443,"tr":"tcp","u":"1760000000:abcd","c":"AAAAAAAAAAAAAAAAAAAAAA=="}"#
    static let stun = #"{"t":"stuns","h":"stun.simplex.im","p":5349}"#

    /// A complete frame with a real body and a real signature, made by
    /// `scripts/ios/server-config-mint.swift` against a throwaway seed. The app must refuse it, and refuse it
    /// at the signature; the seed lives nowhere in this repository, so nothing downstream of verification can
    /// be reached from a test. Its own expiry is irrelevant: verification happens first.
    static let forged = "::popopx_sys::SERVER_CFG_V1::POPOPXCFG1-eNpdkMGOgjAURf_lrdGUKZXCzoTIiI5mHBTRmEkVGAsUUVCrxn-fCjt3N-fdexbvARewdQ2q-Ai2qUHGI7Ah65CeYRLGTGKABnGxU_BuqchZrfqmRTDWETHUTZYtsDChL1AJBdZrQOHZv04RCb3gh56ytLDiseek3_vB6DIMIxoZ0qVLfZsP59CsaLfiosxj2eUCNhsNZFK3qojp7BMXU79juTRfmNuAib0snTDydCkCM8Ve6TJnRuZ_0M70d1dRJ41qJMrVZLLki5Unf90P30xnc-EMZLD8wtN-cS7u-Dz2UX3s96FZ4XfTKc7ZTblU5Lu4DeUhB_sBbJepPx2SRE1F1fyVX8HGPYTU7qDAK9S1KveQQRF6Pv8B9UFy5w.xWPSYMMPbnFQvy52_Cvwb5tRiUxUPr7LxjEpM4gk4J7OiAcGFj95hutSCQXc-PLX4F0cp-3tRq9dtjikxDYQDQ"

    /// One body and one stream, both taken from the signing service's own output rather than written to
    /// resemble it: the canonical encoder's bytes for a minimal cluster, and the `zlib` level-9 stream the
    /// generator produces over them. This is the pair the inflater is measured against, so a refusal here is a
    /// refusal of the bytes that actually travel and not of an approximation of them.
    static let canonicalBody =
        #"{"v":1,"seq":7,"kid":"k-ad1dc5463a","enc":"z9","iat":1760000000,"exp":1760604800,"smp":[["rWq7g9sYtLpQ4nJ3mKvB2xNcZeA8dF1hUiO6yT0sPbk","smp8.simplex.im"]],"xftp":[],"ntf":[],"relay":[],"ice":[],"pol":{"ack":"on","ms":1,"iw":3600,"ro":100,"ttl":604800}}"#
    static let canonicalDeflate =
        "eNolj8sOgjAQRf9l1mhAsEB3unChxkeiMWpY1FK1gQLSRkHCvzvYWZ2ceeROB2+gngNavICGDmQyBQrZiKVeyqcB8Rk4IAqO8hsjS"
        + "mZwPiSuLew1lRXEDaJBaIXieoX69AofsT6bdbUPiqWvVu/5pNnwi5hF6cJ7HuWWtAdX724Z/LeisZaqykUzlgqSxIHmboZTSIW5W6"
        + "hFzlqLkgsLVZkD7YDxDEOWBR5T+v+T/AD1yZCpLlEMYAzO2qR9/wM8VEf8"
    /// `sha256(canonicalBody)` in hex, first sixteen characters: the known answer behind `bodyHash(of:)`.
    static let canonicalHash = "cf7fe23c52cda9fd"

    /// One `[key, host]` pair, without the brackets.
    static func pair(_ host: String, key: String = Cfg.key) -> String { "\"\(key)\",\"\(host)\"" }

    /// `[[key, host], …]`.
    static func roster(_ hosts: [String], key: String = Cfg.key) -> String {
        "[" + hosts.map { "[\(pair($0, key: key))]" }.joined(separator: ",") + "]"
    }

    /// `[{…}, …]` for the `ice` roster, which is the only list of objects on this wire.
    static func ice(_ entries: String...) -> String { "[" + entries.joined(separator: ",") + "]" }

    /// `smp1.simplex.im`, `smp2.simplex.im`, … — the spelling the roster caps are measured against.
    static func names(_ count: Int, prefix: String = "smp") -> [String] {
        (1...count).map { "\(prefix)\($0).simplex.im" }
    }

    /// The five policy keys, which the generator emits whether or not the operator set them.
    static func policy(_ overrides: (String, String?)...) -> String {
        var fields = [("ack", #""on""#), ("ms", "1"), ("iw", "3600"), ("ro", "100"), ("ttl", "604800")]
        for (name, value) in overrides {
            guard let index = fields.firstIndex(where: { $0.0 == name }) else { continue }
            if let value { fields[index].1 = value } else { fields.remove(at: index) }
        }
        return "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }

    /// The twelve wire keys, in the order the generator emits them.
    static func body(_ overrides: (String, String?)...) -> String { compose(overrides, reversed: false) }

    /// The same body with the emission order reversed: key order is the signed form, so a decoder that read the
    /// object rather than depended on where each key sat must answer identically.
    static func reversedBody(_ overrides: (String, String?)...) -> String { compose(overrides, reversed: true) }

    private static func compose(_ overrides: [(String, String?)], reversed: Bool) -> String {
        var fields: [(String, String)] = [
            ("v", "1"),
            ("seq", "7"),
            ("kid", "\"\(kid)\""),
            ("enc", #""z9""#),
            ("iat", "\(iat)"),
            ("exp", "\(exp)"),
            ("smp", roster(["smp8.simplex.im"])),
            ("xftp", roster(["xftp1.simplex.im"])),
            ("ntf", roster(["ntf3.simplex.im"])),
            ("relay", "[]"),
            ("ice", "[]"),
            ("pol", policy()),
        ]
        for (name, value) in overrides {
            if let index = fields.firstIndex(where: { $0.0 == name }) {
                if let value { fields[index].1 = value } else { fields.remove(at: index) }
            } else if let value {
                fields.append((name, value))
            }
        }
        if reversed { fields.reverse() }
        return "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }
}

// The signed server-cluster update: the wire grammar, the body rules, the inflate ceiling, the receipt, the
// merge and the decision arithmetic. Every test here needs no key, no network, no database and no view.
//
// What is deliberately NOT tested: that a frame signed by the production key is accepted. The private half of
// that key never enters this repository, so a passing case would have to smuggle a signing key into the test
// target, and an anchor that doubles as a way to mint frames is not an anchor. Every frame leg below therefore
// fails closed at the signature, which is the half worth proving in a suite: a line nobody signed must change
// nothing. The positive leg is minted out of repository by `scripts/ios/server-config-mint.swift`, classified
// there by the signing service's own validator, and walked on a device.
@MainActor
final class PopopxServerConfigTests: XCTestCase {
    /// Spellings the probe matcher dials; the shape is what matters there, not the value.
    private let keyHash = String(repeating: "A", count: 43)
    private let cluster = "smp1.popopx.chat"

    private func parse(_ body: String) -> Result<PopopxServerConfigFrame, PopopxServerConfigRejection> {
        PopopxServerConfigBodyParser.parse(body: Data(body.utf8), now: Cfg.now, keyIndex: 0)
    }

    /// A body the fixtures call legal, or a failure naming the reason it was not. Reading a field off a body
    /// that was actually refused would pass on the wrong evidence, so acceptance is asserted here once.
    private func frame(_ body: String, file: StaticString = #filePath, line: UInt = #line) throws -> PopopxServerConfigFrame {
        switch parse(body) {
        case let .success(value):
            return value
        case let .failure(reason):
            return try XCTUnwrap(
                nil as PopopxServerConfigFrame?,
                "expected this body to be accepted, got \(reason.rawValue): \(body)",
                file: file, line: line
            )
        }
    }

    private func refused(_ body: String, _ expected: PopopxServerConfigRejection, _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
        let context = message.isEmpty ? "" : " (\(message))"
        switch parse(body) {
        case let .failure(reason):
            XCTAssertEqual(reason, expected, "refused for \"\(reason.rawValue)\" instead of \(expected.rawValue): \(body)\(context)",
                           file: file, line: line)
        case .success:
            XCTFail("the body was accepted: \(body)\(context)", file: file, line: line)
        }
    }

    /// The refusal a whole line earns, which is a different question from the refusal a body earns: the frame
    /// path verifies and inflates before it ever reaches the parser.
    private func refusedLine(_ text: String, _ expected: PopopxServerConfigRejection, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        let context = message.isEmpty ? "" : " (\(message))"
        switch PopopxServerConfigWire.decodeConfigFrame(text, now: Cfg.now) {
        case let .failure(reason):
            XCTAssertEqual(reason, expected, "refused for \"\(reason.rawValue)\" instead of \(expected.rawValue)\(context)",
                           file: file, line: line)
        case .success:
            XCTFail("the line was accepted: \(text)\(context)", file: file, line: line)
        }
    }

    // MARK: - Fail closed

    func testAForgedFrameIsRefusedAtTheSignatureAndNowhereLater() {
        // The order is the point. This frame carries a body that satisfies every other rule in this file, a
        // correct signature over the right preimage, and a key this device does not trust; were it refused as
        // `.expired` or `.keyIdMismatch` the test would be proving the validator rather than the verifier.
        refusedLine(Cfg.forged, .signatureNotVerifying)
    }

    func testTheCompressedSegmentIsNeverTouchedBeforeTheSignature() {
        // 382 characters that are not a deflate stream, with a 86-character signature nobody made. If anything
        // downstream of verification could refuse a frame, this leg would come back with a deflate or a JSON
        // reason — which is how an error channel becomes an oracle for probing the parser.
        let line = PopopxServerConfigWire.configPrefix + PopopxServerConfigLimits.tokenPrefix
            + String(repeating: "A", count: 382) + "." + String(repeating: "A", count: 86)
        refusedLine(line, .signatureNotVerifying)
    }

    func testNeitherHalfOfAFrameCanBepickedUpAfterTheOtherIsAltered() {
        // Changing one character of either segment must change the answer, and the answer is a refusal: the
        // signature covers the compressed segment as text, so a payload edited in transit is detected without
        // the device ever reading it.
        let parts = Cfg.forged.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 2, "one dot separates the two segments")
        for index in parts.indices {
            var pieces = parts
            pieces[index] = Substring(String(pieces[index].dropFirst()) + "A")
            let tampered = pieces.joined(separator: ".")
            if tampered == Cfg.forged { continue }
            if case .success = PopopxServerConfigWire.decodeConfigFrame(tampered, now: Cfg.now) {
                XCTFail("segment \(index) was altered and the frame still decoded")
            }
        }
    }

    // MARK: - Wire grammar, before anything is decoded

    func testTheTokenIsRefusedBeforeItsHalvesAreDecoded() {
        let sig = String(repeating: "A", count: PopopxServerConfigLimits.signatureSegmentCharacters)
        let token = PopopxServerConfigWire.configPrefix
        for (label, line, expected) in [
            ("a kind this module does not own", "::popopx_sys::SERVER_CFG_V2::POPOPXCFG1-AAAA.\(sig)", PopopxServerConfigRejection.framePrefixMissing),
            ("a future token tag", token + "POPOPXCFG2-AAAA.\(sig)", .tokenMalformed),
            ("no signature segment", token + "POPOPXCFG1-AAAA", .tokenMalformed),
            ("a third segment", token + "POPOPXCFG1-AAAA.\(sig).BBBB", .tokenMalformed),
            ("an empty compressed segment", token + "POPOPXCFG1-.\(sig)", .tokenMalformed),
            // Padding is outside the alphabet, so it is a structural error rather than a decoding one: the
            // generator emits unpadded base64url and `=` cannot appear anywhere on this wire.
            ("a padded compressed segment", token + "POPOPXCFG1-AAAA=.\(sig)", .tokenMalformed),
            ("a signature one character short", token + "POPOPXCFG1-AAAA.\(sig.dropLast())", .signatureSegmentMalformed),
            ("a signature one character long", token + "POPOPXCFG1-AAAA.\(sig)A", .signatureSegmentMalformed),
        ] {
            refusedLine(line, expected, "the frame with \(label)")
        }
    }

    func testTheSegmentCeilingIsCountedInScalarsNotGraphemes() {
        let ceiling = PopopxServerConfigLimits.maximumSegmentCharacters
        XCTAssertEqual(ceiling, 1_024)
        // Python's `len` counts code points; Swift's `String.count` counts grapheme clusters. The two only
        // diverge off ASCII, and a guard written in clusters would accept a segment the signing side calls too
        // long. These two lines differ by exactly one scalar and one cluster, so which unit the guard uses is
        // the only thing that can decide between them.
        let accent = "e\u{0301}"
        XCTAssertEqual(accent.unicodeScalars.count, 2)
        XCTAssertEqual(accent.count, 1)
        func segment(withScalars scalars: Int) -> String {
            PopopxServerConfigWire.configPrefix + PopopxServerConfigLimits.tokenPrefix
                + String(repeating: "A", count: scalars - PopopxServerConfigLimits.tokenPrefix.unicodeScalars.count - 2)
                + accent
        }
        let at = segment(withScalars: ceiling)
        XCTAssertEqual(at.unicodeScalars.count - PopopxServerConfigWire.configPrefix.unicodeScalars.count, ceiling)
        XCTAssertNotEqual(refusalReason(at), .segmentTooLong, "at the ceiling the length guard is not what stops it")
        XCTAssertEqual(refusalReason(segment(withScalars: ceiling + 1)), .segmentTooLong, "one scalar over is refused on length")
        // The character count this ceiling replaces was a line-length budget shared with the commerce codec;
        // an over-long frame must still be hidden by the shape gate, or it renders as a bubble.
        XCTAssertTrue(PopopxServerConfigWire.isControlText(segment(withScalars: ceiling + 1)))
    }

    private func refusalReason(_ text: String) -> PopopxServerConfigRejection? {
        if case let .failure(reason) = PopopxServerConfigWire.decodeConfigFrame(text, now: Cfg.now) { return reason }
        return nil
    }

    // MARK: - Shape gate, independent of verification

    func testTheGateJudgesShapeAndNotContent() {
        XCTAssertTrue(PopopxServerConfigWire.isControlText("::popopx_sys::SERVER_CFG_V1::nonsense!"))
        XCTAssertTrue(PopopxServerConfigWire.isControlText("::popopx_sys::SERVER_CFG_ACK::"))
        XCTAssertFalse(PopopxServerConfigWire.isControlText("::popopx_sys::SERVER_CFG_V2::eyJ2IjoxfQ"))
        XCTAssertFalse(PopopxServerConfigWire.isControlText("::popopx_sys:: SERVER_CFG_V1::x"), "a space splits the kind off")
        XCTAssertFalse(PopopxServerConfigWire.isControlText("please set my servers"))
        // A frame too long for the ceiling is still hidden, and a frame whose body is not even base64 is still
        // hidden: this gate exists so that a line in our grammar is never a message, whatever it contains.
        XCTAssertTrue(PopopxServerConfigWire.isControlText("::popopx_sys::SERVER_CFG_V1::" + String(repeating: "A", count: 4_000)))
        XCTAssertTrue(PopopxServerConfigWire.isControlText(Cfg.forged))
    }

    func testTheTwoKindsRemainDistinctFromEachOther() {
        XCTAssertEqual(PopopxServerConfigWire.configPrefix, "::popopx_sys::SERVER_CFG_V1::")
        XCTAssertEqual(PopopxServerConfigWire.ackPrefix, "::popopx_sys::SERVER_CFG_ACK::")
        XCTAssertFalse(PopopxServerConfigWire.configPrefix.hasPrefix(PopopxServerConfigWire.ackPrefix))
        XCTAssertFalse(PopopxServerConfigWire.ackPrefix.hasPrefix(PopopxServerConfigWire.configPrefix))
        // The gate is an alternation over both kinds. If one ever became a prefix of the other, a receipt
        // travelling back through this device's own receive path would be read as a configuration frame.
        XCTAssertTrue(PopopxServerConfigWire.isControlText(PopopxServerConfigWire.ackFrame(seq: 7, bodyHash: nil)!))
    }

    // MARK: - Body rules

    func testTheSameValuesArriveWhicheverOrderTheKeysAreEmittedIn() throws {
        // Key order is the signed form and the generator never sorts, so the decoder must read the object. Two
        // bodies that say the same thing in opposite orders must produce the same model — while their hashes
        // differ, which is the reason nothing here is ever re-serialised before it is compared.
        let forward = try frame(Cfg.body())
        let backward = try frame(Cfg.reversedBody())
        XCTAssertEqual(backward.payload, forward.payload, "the values do not depend on emission order")
        XCTAssertNotEqual(backward.bodyHash, forward.bodyHash, "the bytes do: the hash is over what was signed")
        XCTAssertEqual(forward.body, Data(Cfg.body().utf8), "the frame carries the body it was made from")
        XCTAssertEqual(forward.trustedKeyIndex, 0)
    }

    func testTheIdentityBlockFollowsTheGeneratorsGrammar() throws {
        refused(Cfg.body(("v", "2")), .formatVersionUnsupported, "a second format version is not this one")
        refused(Cfg.body(("v", "true")), .formatVersionUnsupported, "a boolean is not a version")
        refused(Cfg.body(("v", nil)), .formatVersionUnsupported)
        refused(Cfg.body(("enc", "\"z8\"")), .encodingUnknown)
        refused(Cfg.body(("enc", nil)), .encodingUnknown)
        // `kid` is checked for shape before it is checked for trust, and the two reasons are different bugs: a
        // malformed id is a hand-edited body, a well-formed wrong id is a frame signed by one key and claiming
        // another.
        refused(Cfg.body(("kid", "\"k-ZZZ\"")), .keyIdMalformed)
        refused(Cfg.body(("kid", "\"k-ad1dc5463a!\"")), .keyIdMalformed)
        refused(Cfg.body(("kid", "\"k-AD1DC5463A\"")), .keyIdMalformed, "the id is lowercase hex")
        refused(Cfg.body(("kid", "7")), .keyIdMalformed)
        refused(Cfg.body(("kid", "\"k-0000000000\"")), .keyIdMismatch, "a well-formed id for a key that did not sign this")
        XCTAssertEqual(try frame(Cfg.body()).payload.keyId, Cfg.kid)
    }

    func testCountersAreIntegersInsideTheCeiling() throws {
        refused(Cfg.body(("seq", nil)), .sequenceMissing)
        refused(Cfg.body(("seq", "0")), .sequenceMissing, "generation zero is the absence of a generation")
        refused(Cfg.body(("seq", "true")), .sequenceMissing, "JSONSerialization bridges true to an NSNumber")
        refused(Cfg.body(("seq", "1.5")), .sequenceMissing)
        refused(Cfg.body(("seq", "1e3")), .sequenceMissing, "an exponent is a different claim, not 1000 spelled oddly")
        refused(Cfg.body(("seq", "-1")), .sequenceMissing)
        refused(Cfg.body(("seq", "\"7\"")), .sequenceMissing)
        // The ceiling is a counter ceiling, so the leg that matters is the value one above it: as a double,
        // 2^53 and 2^53+1 are the same number, and a comparison in floating point lets the larger one through.
        refused(Cfg.body(("seq", "9007199254740993")), .sequenceMissing, "2^53 plus one is not representable as a counter")
        let top = try frame(Cfg.body(("seq", "9007199254740992")))
        XCTAssertEqual(top.payload.seq, PopopxServerConfigLimits.maximumCounterValue, "the ceiling itself is reachable")
        refused(Cfg.body(("iat", nil)), .issuedAtMissing)
        refused(Cfg.body(("exp", nil)), .expiryMissing)
        refused(Cfg.body(("iat", "\(Cfg.exp)")), .expiryNotAfterIssue)
        refused(Cfg.body(("iat", "\(Cfg.exp + 1)"), ("exp", "\(Cfg.exp)")), .expiryNotAfterIssue)
        refused(Cfg.body(("exp", "\(Cfg.iat + 31 * 86_400)")), .validitySpanTooLong)
        XCTAssertEqual(try frame(Cfg.body(("exp", "\(Cfg.iat + 30 * 86_400)"))).payload.expiresAt,
                       Cfg.iat + 30 * 86_400, "thirty days is the ceiling, not a refusal")
        refused(Cfg.body(("exp", "\(Cfg.now)")), .expired, "a frame is dead the second it says it is")
        refused(Cfg.body(("exp", "\(Cfg.now - 1)")), .expired)
    }

    func testRostersAreCappedAndTheFirstOneIsNeverEmpty() throws {
        refused(Cfg.body(("smp", nil)), .smpRosterInvalid, "an absent SMP roster would mean remove every server this device dials")
        refused(Cfg.body(("smp", "[]")), .smpRosterInvalid)
        refused(Cfg.body(("smp", #"{"key":"v","host":"smp8.simplex.im"}"#)), .smpRosterInvalid, "the roster itself is the array")
        refused(Cfg.body(("smp", #"[{"key":"\#(Cfg.key)","host":"smp8.simplex.im"}]"#)), .entryShapeInvalid,
                "one entry written as an object is that entry's error, not the list's")
        for count in 1...10 {
            XCTAssertEqual(try frame(Cfg.body(("smp", Cfg.roster(Cfg.names(count))))).payload.smpServers.count, count)
        }
        refused(Cfg.body(("smp", Cfg.roster(Cfg.names(11)))), .smpRosterTooLarge)
        let xftp = Cfg.names(5, prefix: "xftp")
        XCTAssertEqual(try frame(Cfg.body(("xftp", Cfg.roster(Array(xftp.dropLast()))))).payload.xftpServers.count, 4)
        refused(Cfg.body(("xftp", Cfg.roster(xftp))), .xftpRosterTooLarge)
        let ntf = Cfg.names(5, prefix: "ntf")
        XCTAssertEqual(try frame(Cfg.body(("ntf", Cfg.roster(Array(ntf.dropLast()))))).payload.notificationServers.count, 4)
        refused(Cfg.body(("ntf", Cfg.roster(ntf))), .ntfRosterTooLarge)
        // An absent roster is an empty one for the four lists the generator may legitimately have nothing for.
        let empty = try frame(Cfg.body(("xftp", nil), ("ntf", nil), ("relay", nil), ("ice", nil)))
        XCTAssertEqual(empty.payload.xftpServers.count, 0)
        XCTAssertEqual(empty.payload.relays.count, 0)
        XCTAssertEqual(empty.payload.iceServers.count, 0)
        let relay = #"[["relay.simplex.im","\#(Cfg.key)"]]"#
        XCTAssertEqual(try frame(Cfg.body(("relay", "[\(relay),\(relay)]"))).payload.relays.count, 2)
        refused(Cfg.body(("relay", "[\(relay),\(relay),\(relay)]")), .relayRosterTooLarge)
        let ice = #"{"t":"stun","h":"stun.simplex.im","p":3478}"#
        XCTAssertEqual(try frame(Cfg.body(("ice", "[\(ice),\(ice),\(ice)]"))).payload.iceServers.count, 3)
        refused(Cfg.body(("ice", "[\(ice),\(ice),\(ice),\(ice)]")), .iceRosterTooLarge)
        refused(Cfg.body(("ice", #""stun:simplex.im""#)), .iceRosterInvalid)
    }

    func testServerEntriesAreTwoOrThreeStringsAndNothingElse() throws {
        refused(Cfg.body(("smp", #"[["\#(Cfg.key)"]]"#)), .entryShapeInvalid, "one field is a fingerprint with nowhere to dial")
        refused(Cfg.body(("smp", #"[["\#(Cfg.key)","smp8.simplex.im","a.onion","extra"]]"#)), .entryShapeInvalid)
        // A number where a string belongs is the entry's own shape error, which is what the generator reports:
        // the list is fine and one value inside it is not.
        refused(Cfg.body(("smp", #"[[7,"smp8.simplex.im"]]"#)), .entryShapeInvalid)
        refused(Cfg.body(("smp", Cfg.roster(["smp8.simplex.im"], key: String(Cfg.key.dropLast())))), .entryKeyInvalid)
        refused(Cfg.body(("smp", Cfg.roster(["smp8.simplex.im"], key: Cfg.key + "=="))), .entryKeyInvalid)
        refused(Cfg.body(("smp", Cfg.roster(["smp8.simplex.im"], key: String(Cfg.key.dropLast()) + "+"))), .entryKeyInvalid,
                "a padded-or-url-safe spelling of `+` is not in this alphabet")
        // One trailing `=` is legal to receive because the generator strips it before signing; keeping it would
        // make the device dial a string that is not the one that was authorized.
        let padded = try frame(Cfg.body(("smp", Cfg.roster(["smp8.simplex.im"], key: Cfg.key + "="))))
        XCTAssertEqual(padded.payload.smpServers.first?.key, Cfg.key, "normalized to the forty-three that were signed")
        XCTAssertEqual(padded.payload.smpServers.first?.key.count, 43)
        let withAlt = try frame(Cfg.body(("smp", #"[["\#(Cfg.key)","smp8.simplex.im","\#(Cfg.onion)"]]"#)))
        XCTAssertEqual(withAlt.payload.smpServers.first?.onion, Cfg.onion)
        XCTAssertEqual(withAlt.payload.smpServers.first?.key.count, 43)
        refused(Cfg.body(("smp", #"[["\#(Cfg.key)","smp8.simplex.im","not-an-onion"]]"#)), .entryOnionInvalid)
        refused(Cfg.body(("smp", #"[["\#(Cfg.key)","smp8.simplex.im","\#(Cfg.onionShort)"]]"#)), .entryOnionInvalid)
    }

    func testAHostIsRefusedByGrammarFirstAndByAdmissionSecond() throws {
        for host in ["smp8.simplex.im", "smp1.popopx.chat", "x1.popopx.im", Cfg.onion, "a.b.simplex.im", "smp-1.simplex.im"] {
            _ = try frame(Cfg.body(("smp", Cfg.roster([host]))))
        }
        let grammar: [(String, String)] = [
            ("SMP8.simplex.im", "uppercase"),
            ("smp_8.simplex.im", "an underscore"),
            ("localhost", "one label"),
            (".simplex.im", "a leading dot"),
            ("smp8.simplex.im.", "a trailing dot"),
            ("-smp8.simplex.im", "a leading hyphen"),
            ("smp8.simplex.im:", "a colon with nothing after it"),
            ("smp8.simplex.im:443", "a port, which is not this field"),
            ("https://smp8.simplex.im", "a scheme"),
            ("smp8.simplex.im?ip=1.2.3.4", "a query"),
            ("", "nothing at all"),
            (String(repeating: "a", count: 244) + ".simplex.im", "over 253 characters"),
        ]
        for (host, label) in grammar {
            refused(Cfg.body(("smp", Cfg.roster([host]))), .entryHostInvalid, label)
        }
        let outside: [(String, String)] = [
            ("smp1.example.com", "a domain nobody here operates"),
            ("evilpopopx.im", "a name that ends like ours without being ours"),
            ("popopx.im.evil.example", "a name that starts like ours"),
            ("smp8.simplex.imx", "a suffix match that is not a suffix"),
        ]
        for (host, label) in outside {
            refused(Cfg.body(("smp", Cfg.roster([host]))), .entryHostUnadmitted, label)
        }
    }

    func testAShortOnionIsALegalHostAndAnIllegalAlternateAddress() throws {
        // Two regexes for two different questions. The host field is admitted by suffix, so a name that is not
        // fifty-six characters long still parses — and this is recorded rather than smoothed over, because the
        // client dials the alternate address only when the name fails, and a wrong address there is a silent
        // failure to connect rather than a wrong-looking name.
        _ = try frame(Cfg.body(("smp", Cfg.roster([Cfg.onionShort]))))
        refused(Cfg.body(("smp", #"[["\#(Cfg.key)","smp8.simplex.im","\#(Cfg.onionShort)"]]"#)), .entryOnionInvalid)
        refused(Cfg.body(("smp", Cfg.roster([Cfg.onion.uppercased()]))), .entryHostInvalid)
    }

    func testRelayEntriesAreHostThenKeyAndNeverPadded() throws {
        let relay = try frame(Cfg.body(("relay", #"[["relay.simplex.im","\#(Cfg.key)"]]"#)))
        XCTAssertEqual(relay.payload.relays.first?.host, "relay.simplex.im")
        XCTAssertEqual(relay.payload.relays.first?.key.count, 43)
        refused(Cfg.body(("relay", #"[["relay.simplex.im","\#(Cfg.key)="]]"#)), .relayKeyInvalid,
                "a relay key is exactly forty-three: the generator never carries it padded")
        refused(Cfg.body(("relay", #"[["relay.simplex.im"]]"#)), .relayEntryShapeInvalid)
        refused(Cfg.body(("relay", #"[["relay.simplex.im","\#(Cfg.key)","extra"]]"#)), .relayEntryShapeInvalid)
        refused(Cfg.body(("relay", #"[["relay.example.com","\#(Cfg.key)"]]"#)), .entryHostUnadmitted,
                "the host rules run here too")
        refused(Cfg.body(("relay", #"[{"h":"relay.simplex.im","k":"\#(Cfg.key)"}]"#)), .relayEntryShapeInvalid)
    }

    // MARK: - The anchor, the hash and the receipt

    func testTheAnchorIsTheProductionKeyAndItsKeyIdIsDerivedNotCarried() throws {
        XCTAssertEqual(PopopxServerConfigTrust.signingPublicKeyHexes.count, 1,
                       "one anchor, until a rotation ships beside the key it retires")
        let hex = try XCTUnwrap(PopopxServerConfigTrust.signingPublicKeyHexes.first)
        XCTAssertEqual(hex.count, PopopxServerConfigLimits.signingKeyCharacters)
        XCTAssertEqual(PopopxServerConfigTrust.keyId(forPublicKeyHex: hex), Cfg.kid)
        XCTAssertNotEqual(PopopxServerConfigTrust.keyId(forPublicKeyHex: String(repeating: "0", count: 64)), Cfg.kid,
                          "an id is a fact about a key, so no body can choose it")
        XCTAssertNil(PopopxServerConfigTrust.keyId(forPublicKeyHex: "not a key"))
        XCTAssertEqual(String(decoding: PopopxServerConfigTrust.signatureDomain, as: UTF8.self),
                       "popopx|popx_srv_cfg_v1|")
    }

    func testTheBodyHashIsTheGeneratorsSixteenHexPrefix() {
        XCTAssertEqual(PopopxServerConfigWire.bodyHash(of: Data(Cfg.canonicalBody.utf8)), Cfg.canonicalHash)
        XCTAssertEqual(PopopxServerConfigWire.bodyHash(of: Data()), "e3b0c44298fc1c14",
                       "SHA-256 of nothing, which is what an empty body hashes to")
        XCTAssertEqual(PopopxServerConfigWire.bodyHash(of: Data("popopx".utf8)).count, 16)
        XCTAssertNotEqual(PopopxServerConfigWire.bodyHash(of: Data(Cfg.reversedBody().utf8)), Cfg.canonicalHash,
                          "the hash is over bytes, so a re-ordered body is a different body")
    }

    func testTheReceiptNamesTheGenerationAndOptionallyTheBody() {
        let hash = PopopxServerConfigWire.bodyHash(of: Data(Cfg.canonicalBody.utf8))
        XCTAssertEqual(PopopxServerConfigWire.ackFrame(seq: 7, bodyHash: hash),
                       "::popopx_sys::SERVER_CFG_ACK::7::" + hash)
        XCTAssertEqual(PopopxServerConfigWire.ackFrame(seq: 7, bodyHash: nil), "::popopx_sys::SERVER_CFG_ACK::7",
                       "a generation the device declined to install is acknowledged without claiming its bytes")
        XCTAssertNil(PopopxServerConfigWire.ackFrame(seq: 0, bodyHash: hash), "there is no generation zero")
        XCTAssertNil(PopopxServerConfigWire.ackFrame(seq: 9_007_199_254_740_993, bodyHash: nil))
        for spelling in ["", "abc", hash.uppercased(), String(hash.dropLast()), hash + "0", String(repeating: "g", count: 16)] {
            XCTAssertNil(PopopxServerConfigWire.ackFrame(seq: 7, bodyHash: spelling), "not a body hash: \(spelling)")
        }
        XCTAssertTrue(PopopxServerConfigWire.isControlText(PopopxServerConfigWire.ackFrame(seq: 7, bodyHash: hash)!),
                      "a receipt travelling back through this device is hidden too")
    }

    // MARK: - Inflate

    func testTheGeneratorsStreamInflatesToTheGeneratorsBytes() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Cfg.canonicalDeflate))
        switch PopopxServerConfigInflator.inflate(data) {
        case let .success(body):
            XCTAssertEqual(body, Data(Cfg.canonicalBody.utf8))
            let parsed = try frame(String(decoding: body, as: UTF8.self))
            XCTAssertEqual(parsed.payload.seq, 7)
            XCTAssertEqual(parsed.payload.smpServers.first?.host, "smp8.simplex.im")
            XCTAssertEqual(parsed.bodyHash, Cfg.canonicalHash)
        case let .failure(reason):
            XCTFail("the service's own stream was refused: \(reason.rawValue)")
        }
    }

    func testNoInflatePathHandsBackPartOfABody() throws {
        let stream = try XCTUnwrap(Data(base64Encoded: Cfg.canonicalDeflate))
        func refusal(for bytes: Data, file: StaticString = #filePath, line: UInt = #line) -> PopopxServerConfigRejection? {
            switch PopopxServerConfigInflator.inflate(bytes) {
            case let .success(body):
                XCTFail("accepted \(body.count) bytes that were not offered whole", file: file, line: line)
                return nil
            case let .failure(reason):
                return reason
            }
        }
        // Cut three bytes short, the way a truncated message arrives. Which refusal a cut produces depends on
        // where the cut lands, so the contract under test is "never partial output" rather than one string.
        XCTAssertEqual(refusal(for: stream.dropLast(3)), .deflateTruncated)
        // A flipped byte in the trailer is the case the checksum exists for: the stream ends where it should,
        // the output is the right length, and only the Adler-32 says the bytes are not the ones that were signed.
        var flipped = stream
        flipped[flipped.count - 1] ^= 0xFF
        XCTAssertEqual(refusal(for: flipped), .checksumMismatch)
        // FDICT set means four extra header bytes naming a preset dictionary the generator never uses; a wrong
        // CM nibble means the bytes are not deflate at all. Both are refused before a decoder is handed them.
        var dictionary = stream
        dictionary[1] |= 0x20
        XCTAssertEqual(refusal(for: dictionary), .deflateHeaderInvalid)
        var method = stream
        method[0] |= 0x01
        XCTAssertEqual(refusal(for: method), .deflateHeaderInvalid)
        XCTAssertEqual(refusal(for: Data()), .deflateHeaderInvalid)
        XCTAssertEqual(refusal(for: Data([0x78, 0xDA])), .deflateHeaderInvalid, "a header and nothing else")
        // 200 010 bytes of padding from 231 bytes of stream, refused whole rather than cut to what fits.
        let bomb = "eNrtwTERACAMBDAvL6MbUrhDADtX79XAnuTl7pPKAg"
            + String(repeating: "A", count: 256) + "C+pQc3aWvK"
        XCTAssertEqual(refusal(for: try XCTUnwrap(Data(base64Encoded: bomb))), .deflateOverCap)
        // The controls, because a decoder that always refuses would pass every assertion above: one byte in,
        // one byte out, and the generator's own stream accepted end to end.
        switch PopopxServerConfigInflator.inflate(try XCTUnwrap(Data(base64Encoded: "eNqrAAAAeQB5"))) {
        case let .success(body): XCTAssertEqual(body, Data("x".utf8))
        case let .failure(reason): XCTFail("a one-byte stream is a real stream: \(reason.rawValue)")
        }
        if case let .failure(reason) = PopopxServerConfigInflator.inflate(stream) {
            XCTFail("the control stream was refused: \(reason.rawValue)")
        }
    }

    // MARK: - ICE, the list a call path would otherwise guess at

    /// A legal TURN entry with one field changed, so that each leg below says exactly which claim it tests.
    private func iceEntry(_ overrides: (String, String?)...) -> String {
        var fields: [(String, String)] = [
            ("t", "\"turn\""),
            ("h", "\"turn.simplex.im\""),
            ("p", "3478"),
            ("u", "\"\(Cfg.iat):abcd\""),
            ("c", "\"\(Cfg.credential)\""),
        ]
        for (name, value) in overrides {
            if let index = fields.firstIndex(where: { $0.0 == name }) {
                if let value { fields[index].1 = value } else { fields.remove(at: index) }
            } else if let value {
                fields.append((name, value))
            }
        }
        return "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }

    private func iceBody(_ entries: String...) -> String {
        Cfg.body(("ice", "[" + entries.joined(separator: ",") + "]"))
    }

    func testAStructuredTurnEntryIsReadFieldByField() throws {
        let entry = try XCTUnwrap(frame(iceBody(iceEntry())).payload.iceServers.first)
        XCTAssertEqual(entry.scheme, "turn")
        XCTAssertEqual(entry.host, "turn.simplex.im")
        XCTAssertEqual(entry.port, 3_478)
        XCTAssertEqual(entry.username, "\(Cfg.iat):abcd")
        XCTAssertEqual(entry.credential, Cfg.credential)
        XCTAssertNil(entry.transport)
        XCTAssertNil(entry.expiresAt)
        let secured = try XCTUnwrap(frame(iceBody(iceEntry(("t", "\"turns\""), ("p", "443"), ("tr", "\"tcp\""), ("x", "\(Cfg.exp)")))).payload.iceServers.first)
        XCTAssertEqual(secured.transport, "tcp")
        XCTAssertEqual(secured.expiresAt, Cfg.exp)
        let stun = try XCTUnwrap(frame(iceBody(iceEntry(("t", "\"stun\""), ("u", nil), ("c", nil)))).payload.iceServers.first)
        XCTAssertNil(stun.username, "a stun entry has nowhere to use either half")
        XCTAssertNil(stun.credential)
        XCTAssertNil(stun.expiresAt)
        // An empty transport is read as absent, which is how the generator writes a field the operator left
        // unset; `udp` and `tcp` are the only values it will carry a value for.
        XCTAssertNil(try XCTUnwrap(frame(iceBody(iceEntry(("tr", "\"\"")))).payload.iceServers.first?.transport))
        XCTAssertEqual(try XCTUnwrap(frame(iceBody(iceEntry(("tr", "\"udp\"")))).payload.iceServers.first?.transport), "udp")
    }

    func testAnIceEntryIsRefusedBeforeItCouldBecomeAFallbackAddress() throws {
        // Every leg here exists because the call path behind this list has a hardcoded relay under it: an entry
        // that arrives with its port or its credentials missing must not be repaired into a guess, because a
        // guessed address returns the device to the upstream server while the user believes they are on ours.
        refused(iceBody(iceEntry(("p", nil))), .icePortInvalid, "port is mandatory, never defaulted")
        refused(iceBody(iceEntry(("p", "0"))), .icePortInvalid)
        refused(iceBody(iceEntry(("p", "65536"))), .icePortInvalid)
        refused(iceBody(iceEntry(("p", "\"443\""))), .icePortInvalid, "a port written as text is not a port")
        refused(iceBody(iceEntry(("p", "443.0"))), .icePortInvalid, "an exponent is a different claim")
        refused(iceBody(iceEntry(("t", nil))), .iceSchemeUnknown)
        refused(iceBody(iceEntry(("t", "\"foo\""))), .iceSchemeUnknown)
        refused(iceBody(iceEntry(("t", "7"))), .iceSchemeUnknown, "a number is not a scheme either")
        refused(iceBody("[\"turn\",\"turn.simplex.im\",3478]"), .iceEntryShapeInvalid, "an array is not an entry")
        refused(iceBody("\"turn.simplex.im\""), .iceEntryShapeInvalid)
        refused(iceBody(iceEntry(("h", nil))), .iceEntryShapeInvalid)
        refused(iceBody(iceEntry(("tr", "\"sctp\""))), .iceTransportUnknown)
        refused(iceBody(iceEntry(("u", nil))), .iceCredentialsMissing)
        refused(iceBody(iceEntry(("c", nil))), .iceCredentialsMissing)
        refused(iceBody(iceEntry(("u", nil), ("c", nil))), .iceCredentialsMissing)
        refused(iceBody(iceEntry(("t", "\"stun\""))), .iceCredentialsNotAllowed,
                "credentials on a stun entry mean the two sides disagree about what `t` means")
        refused(iceBody(iceEntry(("u", "\"abcd\""))), .iceUsernameMalformed, "the expiry has to come first")
        refused(iceBody(iceEntry(("u", "\"\(Cfg.iat):abcd:extra\""))), .iceUsernameMalformed)
        refused(iceBody(iceEntry(("u", "\"1234567890123:abcd\""))), .iceUsernameMalformed, "thirteen digits is past the ceiling")
        refused(iceBody(iceEntry(("u", "\":abcd\""))), .iceUsernameMalformed)
        refused(iceBody(iceEntry(("u", "\"\(Cfg.iat):\""))), .iceUsernameMalformed)
        refused(iceBody(iceEntry(("c", "\"AAAAAAAAAAAAAAAAAAAAAAAAAA\""))), .iceCredentialMalformed,
                "url-safe without padding is how this wire carries keys, not how coturn carries this")
        refused(iceBody(iceEntry(("c", "\"AAAAAAAAAAAAAAAAAAAAAA\""))), .iceCredentialMalformed,
                "twenty bytes cannot be spelled without their padding here")
        let nineteen = Data(repeating: 65, count: 19).base64EncodedString()
        refused(iceBody(iceEntry(("c", "\"\(nineteen)\""))), .iceCredentialMalformed, "nineteen bytes is not HMAC-SHA1")
        // An expiry is read for every scheme, including the entry that carries no credentials at all: an
        // `x` of zero is not a missing value but an impossible one, and downstream readers disagree about
        // whether it means "already expired" or "never expires".
        refused(iceBody(iceEntry(("x", "0"))), .iceExpiryInvalid)
        refused(iceBody(iceEntry(("x", "\"1\""))), .iceExpiryInvalid)
        refused(iceBody(iceEntry(("x", "\(PopopxServerConfigLimits.maximumCounterValue + 1)"))), .iceExpiryInvalid)
        refused(iceBody(iceEntry(("t", "\"stun\""), ("u", nil), ("c", nil), ("x", "0"))), .iceExpiryInvalid)
        // The domain rule stops at the rosters a device dials. The generator applies none to `ice`
        // (`models.py:266-365`) and its shipped cluster names `turn.example.net` (`cluster.json:59`), so an
        // admission check here would refuse every real frame over a host this build never contacts — and take
        // the SMP roster signed beside it down with it.
        let offBrand = try XCTUnwrap(
            frame(iceBody(iceEntry(("h", "\"turn.example.net\"")))).payload.iceServers.first
        )
        XCTAssertEqual(offBrand.host, "turn.example.net", "an unbranded TURN host parses and is kept")
        refused(iceBody(iceEntry(("h", "\"turn_example\""))), .entryHostInvalid, "the shape rules still run")
        refused(iceBody(iceEntry(("h", "\".turn.example.net\""))), .entryHostInvalid)
        refused(iceBody(iceEntry(("h", "\"turn\""))), .entryHostInvalid, "one label is not a host")
        refused(iceBody(iceEntry(("h", "\"turn.example.net:443\""))), .entryHostInvalid,
                "a port in the host field would assemble a second server out of one signed value")
    }

    func testTheIceListIsKeptWholeAndNotDialed() throws {
        // Ruling B, recorded rather than smoothed over: an entry parses completely and is kept on the payload,
        // and deliberately no call path reads it in this round. The hardcoded relay it would replace is
        // `WebRTCClient.swift:92-94`, which presets STUN only, and the value chain at
        // `WebRTCClient.swift:144`: `iceServers ?? getWebRTCIceServers() ?? injectedTurnIceServers() ??
        // defaultIceServers`. The injected relay is built only from credentials that arrive through the
        // git-ignored `Local.xcconfig`, never from this repository, so a missing one falls back to STUN.
        // That is why every leg above refuses instead of defaulting.
        let entry = try XCTUnwrap(frame(iceBody(iceEntry(("t", "\"turns\""), ("p", "443"), ("tr", "\"tcp\"")))).payload.iceServers.first)
        XCTAssertEqual(entry.credential, Cfg.credential, "the credential is carried intact or the entry is refused")
        XCTAssertEqual(entry.username, "\(Cfg.iat):abcd")
        XCTAssertEqual(entry.port, 443)
    }

    // MARK: - Policy

    func testThePolicyBlockIsReadAsFiveMandatoryValues() throws {
        let policy = try frame(Cfg.body()).payload.policy
        XCTAssertEqual(policy.ack, true, "the wire spelling of the flag is the string `on`")
        XCTAssertEqual(policy.minSeq, 1)
        XCTAssertEqual(policy.installWindowSeconds, 3_600)
        XCTAssertEqual(policy.rolloutPercent, 100)
        XCTAssertEqual(policy.ttlSeconds, 604_800)
        let off = try frame(Cfg.body(("pol", Cfg.policy(("ack", "\"off\""))))).payload.policy
        XCTAssertEqual(off.ack, false)
        // A JSON boolean is accepted because the generator's own reader accepts it
        // (`models.py:139-144` takes `True`/`False` beside `on`/`off`); a number is not, and neither is prose.
        XCTAssertEqual(try frame(Cfg.body(("pol", Cfg.policy(("ack", "true"))))).payload.policy.ack, true)
        XCTAssertEqual(try frame(Cfg.body(("pol", Cfg.policy(("ack", "false"))))).payload.policy.ack, false)
        refused(Cfg.body(("pol", Cfg.policy(("ack", "1")))), .policyAckInvalid, "a truthy number is a different agreement")
        refused(Cfg.body(("pol", Cfg.policy(("ack", "\"yes\"")))), .policyAckInvalid)
        refused(Cfg.body(("pol", Cfg.policy(("ack", "\"\"")))), .policyAckInvalid)
        for (key, expected) in [
            ("ack", PopopxServerConfigRejection.policyAckInvalid),
            ("ms", .policyMinSeqInvalid),
            ("iw", .policyInstallWindowInvalid),
            ("ro", .policyRolloutInvalid),
            ("ttl", .policyTtlInvalid),
        ] {
            refused(Cfg.body(("pol", Cfg.policy((key, nil)))), expected, "\(key) is not optional")
        }
        refused(Cfg.body(("pol", nil)), .policyMissing)
        refused(Cfg.body(("pol", "\"ack=on\"")), .policyMissing)
        refused(Cfg.body(("pol", "[]")), .policyMissing)
        refused(Cfg.body(("pol", Cfg.policy(("ms", "0")))), .policyMinSeqInvalid)
        refused(Cfg.body(("pol", Cfg.policy(("iw", "0")))), .policyInstallWindowInvalid)
        refused(Cfg.body(("pol", Cfg.policy(("ttl", "0")))), .policyTtlInvalid)
    }

    func testTheRolloutGateIsTheOnlyClientSideBoundAndTheAliasIsTheRealOne() throws {
        refused(Cfg.body(("pol", Cfg.policy(("ro", "0")))), .policyRolloutInvalid)
        refused(Cfg.body(("pol", Cfg.policy(("ro", "101")))), .policyRolloutInvalid, "one percent past the ceiling")
        refused(Cfg.body(("pol", Cfg.policy(("ro", "\"100\"")))), .policyRolloutInvalid)
        // `rollout` is how the operator's prose spells the field and how an earlier draft of this reader
        // accepted it. The wire carries no such key: the generator writes `ro` (`models.py:382`), so tolerating
        // the long form would mean accepting a body the service refuses to sign while reading no gate at all.
        refused(Cfg.body(("pol", Cfg.policy(("ro", nil), ("rollout", "100")))), .policyRolloutInvalid)
        // `install_window` is the one alias the generator actually reads (`models.py:523`), so it is the one
        // tolerance this reader keeps — and it is kept under test, which is what tells us if it stops being real.
        let aliased = try frame(Cfg.body(("pol", Cfg.policy(("iw", nil), ("install_window", "60"), ("ack", "\"off\""))))).payload.policy
        XCTAssertEqual(aliased.installWindowSeconds, 60)
        XCTAssertEqual(aliased.ack, false)
        // Only `ro` gets a client-side bound, because only `ro` is bounded by the generator while decoding:
        // the install window and the ttl ranges are enforced at signing time, and a device that enforced them
        // too could refuse a frame that was legal the moment it was made.
        let wide = try frame(Cfg.body(("pol", Cfg.policy(("iw", "1000000000"), ("ttl", "1000000000"))))).payload.policy
        XCTAssertEqual(wide.installWindowSeconds, 1_000_000_000)
        XCTAssertEqual(wide.ttlSeconds, 1_000_000_000)
    }

    // MARK: - Decision arithmetic, which needs no key

    /// The floor in force is `max(stored, ms - 1)`, so `WIRE.md:929-931` ("a generation below the floor is
    /// refused even if it verifies") is what runs, and the contradictory `:935-938` — which describes the
    /// lever as lowering every floor to `ms - 1` — is deliberately not implemented: lowering is the replay
    /// hole. The legs below are the two directions of that ratchet.
    private func classify(generation seq: Int, atFloor floor: Int?, revokedAbove ms: String? = nil, broken: [String] = []) throws -> PopopxServerConfigSignalHandler.Decision {
        PopopxServerConfigSignalHandler.classify(
            frame: try frame(Cfg.body(("seq", "\(seq)"), ("pol", ms.map { Cfg.policy(("ms", $0)) } ?? Cfg.policy()))),
            state: PopopxServerConfigDecisionState(floors: floor.map { [Cfg.kid: $0] } ?? [:], broken: broken)
        )
    }

    func testAFrameIsMeasuredAgainstTheFloorItsOwnPolicyLeaves() throws {
        // Behind the device: a withdrawal of generation 9 cannot reopen a device that already acted on 12.
        // The corrected roster in that sequence always carries a higher generation, so refusing this frame
        // costs the operator nothing they can do another way.
        switch try classify(generation: 9, atFloor: 12, revokedAbove: "9") {
        case .frame: XCTFail("a withdrawal of generation 9 reopened a device that had already moved to 12")
        case let .stale(refused): XCTAssertEqual(refused.payload.seq, 9)
        case let .refused(reason): XCTFail(reason.rawValue)
        }
        // Ahead of the device: the same lever raises the bar, and the generation that raises it still lands.
        switch try classify(generation: 13, atFloor: 12, revokedAbove: "13") {
        case .frame: break
        case .stale: XCTFail("the corrected generation after a withdrawal was refused by the baseline it declares")
        case let .refused(reason): XCTFail(reason.rawValue)
        }
        // Beyond what the generator can emit — its encoder cannot put `ms` above its own `seq`
        // (`WIRE.md:937-938`) — so this is the tolerance for a hand-edited or foreign signer: a declared
        // baseline binds even when the number arrived inside a frame that contradicts itself.
        switch try classify(generation: 8, atFloor: 5, revokedAbove: "20") {
        case .stale: break
        case .frame: XCTFail("generation 8 installed itself under a baseline of 19")
        case let .refused(reason): XCTFail(reason.rawValue)
        }
        switch try classify(generation: 7, atFloor: 12, revokedAbove: "9") {
        case .stale: break
        case .frame: XCTFail("generation 7 installed itself over a device holding generation 12")
        case let .refused(reason): XCTFail(reason.rawValue)
        }
        // A hole in the numbering is not a downgrade: generations are not consecutive, because the operator
        // reserves numbers and abandons them.
        switch try classify(generation: 11, atFloor: 3) {
        case .frame: break
        case .stale: XCTFail("generation 11 was refused over a device at generation 3")
        case let .refused(reason): XCTFail(reason.rawValue)
        }
        // An unknown key starts at zero, which is what admits its first generation.
        switch try classify(generation: 7, atFloor: nil) {
        case .frame: break
        case .stale: XCTFail("a first generation from a key never seen before was not installed")
        case let .refused(reason): XCTFail(reason.rawValue)
        }
        // The hole this closes, stated because it is the reason the lever only goes one way: the shipped
        // cluster signs `min_seq: 1`, so `ms - 1` is zero and the stored floor is the only thing left
        // standing. Under `min` that comparison returned zero for every frame, which made the floor inert and
        // let the holder of the signing key replay any generation that had not yet expired back onto a device
        // that had already moved past it.
        switch try classify(generation: 7, atFloor: 12) {
        case .frame: XCTFail("an older generation replayed itself onto a device holding generation 12")
        case .stale: break
        case let .refused(reason): XCTFail(reason.rawValue)
        }
    }

    func testABrokenGenerationIsStaleWhileItsSuccessorLands() throws {
        // The breaker suppresses exactly the generation that was applied and then rolled back. Wiping every
        // generation from that key instead would leave the device unable to accept the corrected roster the
        // operator signs next.
        switch try classify(generation: 7, atFloor: 6, broken: ["\(Cfg.kid)|7"]) {
        case .stale: break
        case .frame: XCTFail("a rolled-back generation was offered again and installed")
        case let .refused(reason): XCTFail(reason.rawValue)
        }
        switch try classify(generation: 8, atFloor: 6, broken: ["\(Cfg.kid)|7"]) {
        case .frame: break
        case .stale: XCTFail("the generation after a rollback was refused because of it")
        case let .refused(reason): XCTFail(reason.rawValue)
        }
        // A different key's disaster is not this key's, which is what lets a rotation escape a breaker that
        // was set before the rotation happened.
        switch try classify(generation: 7, atFloor: 6, broken: ["k-0000000000|7"]) {
        case .frame: break
        case .stale: XCTFail("another key's broken generation suppressed this one")
        case let .refused(reason): XCTFail(reason.rawValue)
        }
    }

    func testDecideRefusesOnVerificationBeforeItConsidersAnyFloor() {
        // A forged frame is never classified by the generation it claims, whatever the device holds. The stale
        // and broken legs above go through `classify` because no test target can sign: reaching them through
        // `decide` would require raising a floor, and a floor raised from a test would leave this device
        // refusing every frame that arrived after it.
        switch PopopxServerConfigSignalHandler.decide(text: Cfg.forged, now: Cfg.now, state: .init(floors: [Cfg.kid: 12])) {
        case let .refused(reason):
            XCTAssertEqual(reason, .signatureNotVerifying)
        case .stale, .frame:
            XCTFail("an unsigned frame was classified by its generation rather than by its signature")
        }
    }

    // MARK: - Who may be acknowledged

    func testAGroupOrABroadcastChannelNeverSendsAReceipt() {
        // Item 2 of the brief, stated once instead of four times: a cluster may be delivered to a group or a
        // broadcast channel and installed there, but the receipt only ever goes back down a one-to-one with the
        // config bot. Four call sites are four chances to drift, and a drift in this one is a receipt storm
        // aimed at every member of every group the device is in.
        let asking = PopopxServerConfigPolicy(ack: true, minSeq: 1, installWindowSeconds: 3_600, rolloutPercent: 100, ttlSeconds: 604_800)
        let silent = PopopxServerConfigPolicy(ack: false, minSeq: 1, installWindowSeconds: 3_600, rolloutPercent: 100, ttlSeconds: 604_800)
        let direct = PopopxServerConfigSignalHandler.Source(chatType: .direct, chatId: 1)
        let group = PopopxServerConfigSignalHandler.Source(chatType: .group, chatId: 1)
        XCTAssertTrue(PopopxServerConfigSignalHandler.owesReceipt(policy: asking, source: direct))
        XCTAssertFalse(PopopxServerConfigSignalHandler.owesReceipt(policy: asking, source: group),
                       "a group member's config bot is not this device's contact")
        XCTAssertFalse(PopopxServerConfigSignalHandler.owesReceipt(policy: silent, source: direct))
        XCTAssertFalse(PopopxServerConfigSignalHandler.owesReceipt(policy: silent, source: group))
        // The two halves stay independent, because they are read from different places: `ack` comes from the
        // signed body and the conversation from the row the line arrived in. A group that is also the device's
        // own chat must still be silent, and a one-to-one that the operator never asked must not answer.
        XCTAssertTrue(direct.maySendReceipt)
        XCTAssertFalse(group.maySendReceipt)
        XCTAssertTrue(asking.ack)
        XCTAssertFalse(silent.ack)
        // The staged record carries the kind as well as the number, because a group's `apiId` and a contact's
        // `apiId` are different namespaces that overlap as integers: routing on the bare number can answer in
        // the wrong conversation.
        XCTAssertEqual(PopopxServerConfigStagedFrame(segment: Cfg.forged, chatType: .group, chatId: 1, receivedAt: Date()).chatType, .group)
        XCTAssertNotEqual(
            PopopxServerConfigPendingAck(kid: Cfg.kid, seq: 7, bodyHash: nil, chatType: .direct, chatId: 1).claimKey,
            PopopxServerConfigPendingAck(kid: Cfg.kid, seq: 7, bodyHash: nil, chatType: .group, chatId: 1).claimKey,
            "two conversations with the same number are two receipts"
        )
    }

    // MARK: - Merge, ownership half

    func testReMergingAnInstalledURIKeepsTheTableStableAndDropsOnlyTheOwnedRow() throws {
        // `mergedServers` short-circuits once the URI is already in the table, which is the branch a
        // redelivered frame lands on: without it every retry would rewrite the server table and reopen the
        // probe window. It is also the only branch that needs no core — placing a brand new row asks the agent
        // to parse the URI, and that leg is exercised out of process instead.
        //
        // What this does pin is ownership: a row this device introduced is removed, and everything the user has
        // is copied through, `preset` rows included.
        let installed = "smp://\(keyHash)@\(cluster)"
        let owned = "smp://\(keyHash)@smp0.popopx.chat"
        let kept = "smp://BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB@someone.else"
        // A row the user typed themselves: not preset, not introduced by this mechanism. It is the case
        // that separates "we do not own it" from "the core marked it default", so it needs its own row.
        let manual = "smp://CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC@user.chose.this"
        let row = UserOperatorServers(
            operator: nil,
            smpServers: [
                UserServer(server: installed, preset: false, tested: nil, enabled: true, deleted: false),
                UserServer(server: owned, preset: false, tested: nil, enabled: true, deleted: false),
                UserServer(server: manual, preset: false, tested: nil, enabled: true, deleted: false),
                UserServer(server: kept, preset: true, tested: nil, enabled: true, deleted: false),
            ],
            xftpServers: [],
            chatRelays: []
        )
        let merged = try XCTUnwrap(
            PopopxServerConfigSignalHandler.mergedServers([row], adding: [installed], replacingOwned: [owned])
        )
        let servers = try XCTUnwrap(merged.servers.first?.smpServers)
        XCTAssertEqual(merged.introduced, [], "a redelivered URI is not a new row")
        XCTAssertEqual(servers.map(\.server), [installed, manual, kept], "only the URI this device introduced is dropped")
        XCTAssertTrue(servers.contains(where: { $0.server == manual && !$0.preset && $0.enabled }),
                      "a row the user added is never ours to remove")
        XCTAssertTrue(servers.contains(where: { $0.server == kept && $0.preset }),
                      "the core's own default rows are not ours to clean")
        XCTAssertEqual(merged.servers.first?.xftpServers.count, 0)
        // Ownership is a list this mechanism maintains, not a property of a row: a URI that was neither inserted
        // now nor introduced before stays exactly where the user put it, and saying so again does not make it
        // ours. The row the new roster still names survives the sweep, which is what keeps a rotation from
        // deleting and re-adding the same server — and with it the core's stored test result for that row.
        XCTAssertEqual(
            PopopxServerConfigSignalHandler.ownedURIs(after: merged, requested: [owned, manual, installed], previouslyOwned: [owned]),
            [owned, installed],
            "the manual row was never ours, and the one present now is ours because it was ours before"
        )
    }

    func testAFrameFromTheShippedClusterNamesServersThisDeviceAdmits() throws {
        // The alignment this round exists because the allowlist and the published cluster disagreed: were the
        // admitted suffixes still missing `.simplex.im`, every name below would come back
        // `.entryHostUnadmitted` and coverage would stay at zero forever. Transcribed from the `entry` block of
        // the service's own cluster.json — SMP `:11-32`, XFTP `:37-42`, NTF `:47-52` — which is the roster it
        // broadcasts. The `full` block (`:68` onward) is larger, fourteen SMP names among them, and never
        // becomes a frame: `models.py:548` describes it as "same grammar, no caps, never broadcast", and
        // `wire.py:190` demotes names from `entry` into it precisely to stay under the ceilings asserted here.
        let smp = ["smp8.simplex.im", "smp9.simplex.im", "smp10.simplex.im", "smp11.simplex.im",
                   "smp12.simplex.im", "smp14.simplex.im", "smp15.simplex.im", "smp16.simplex.im",
                   "smp17.simplex.im", "smp18.simplex.im"]
        let xftp = ["xftp1.simplex.im", "xftp2.simplex.im"]
        let ntf = ["ntf3.simplex.im", "ntf4.simplex.im"]
        let cluster = try frame(Cfg.body(("smp", Cfg.roster(smp)), ("xftp", Cfg.roster(xftp)), ("ntf", Cfg.roster(ntf))))
        XCTAssertEqual(cluster.payload.smpServers.map(\.host), smp)
        XCTAssertEqual(cluster.payload.xftpServers.count, 2)
        XCTAssertEqual(cluster.payload.notificationServers.count, 2)
        // The published SMP roster is exactly at the ceiling, so the name the service leaves out of `entry`
        // cannot be added to the same frame — it has to go to `full`, which the generator then refuses to sign.
        refused(Cfg.body(("smp", Cfg.roster(smp + ["smp13.simplex.im"]))), .smpRosterTooLarge,
                "ten SMP names are published, ten are carried, and an eleventh does not fit")
        // The published TURN name is outside every domain this device dials servers in, and it has to survive
        // (`cluster.json:59`): the frame the service signs is this roster plus one filled `ice` entry.
        let withTurn = try frame(Cfg.body(
            ("smp", Cfg.roster(smp)),
            ("ice", iceBody(iceEntry(("t", "\"turns\""), ("h", "\"turn.example.net\""), ("p", "443"), ("tr", "\"tcp\""))))
        ))
        XCTAssertEqual(withTurn.payload.smpServers.count, 10)
        XCTAssertEqual(withTurn.payload.iceServers.first?.host, "turn.example.net")
    }

    // MARK: - Probe matcher

    private func row(_ host: String, connected: Int, errors: Int) -> SMPServerSummary {
        SMPServerSummary(
            smpServer: host,
            known: true,
            sessions: ServerSessions(ssConnected: connected, ssErrors: errors, ssConnecting: 0),
            subs: nil,
            stats: nil
        )
    }

    func testTheProbeReadsOnlyRowsBelongingToTheIntroducedCluster() {
        let uri = "smp://\(keyHash)@\(cluster)"

        // Another host's errors must not decide this cluster's verdict: the table is shared, and a rollback
        // triggered by somebody else's server would restore a configuration that was working.
        XCTAssertEqual(
            PopopxServerConfigSignalHandler.judge(rows: [row("other.popopx.im", connected: 0, errors: 7)], uri: uri),
            .inconclusive
        )
        // Control for the matcher: the same counters on the introduced host do read as unreachable, so the
        // line above is a matching rule and not a function that answers nothing.
        XCTAssertEqual(
            PopopxServerConfigSignalHandler.judge(rows: [row(cluster, connected: 0, errors: 4)], uri: uri),
            .unreachable
        )
        XCTAssertEqual(
            PopopxServerConfigSignalHandler.judge(rows: [row(cluster, connected: 1, errors: 9)], uri: uri),
            .reachable, "a live session outranks the error count, which is what keeps a transient failure from rolling back"
        )
        XCTAssertEqual(
            PopopxServerConfigSignalHandler.judge(rows: [row(cluster, connected: 0, errors: 0)], uri: uri),
            .inconclusive, "silence is not failure"
        )
        XCTAssertEqual(PopopxServerConfigSignalHandler.judge(rows: [], uri: uri), .inconclusive)
        XCTAssertEqual(
            PopopxServerConfigSignalHandler.judge(rows: [row(uri, connected: 3, errors: 0)], uri: uri),
            .reachable, "the exact URI is tried before the hostnames"
        )
    }

    func testTheFirstRowThatCarriesCountersDecidesRatherThanTheWorstRow() {
        // A cluster reached through several names reports one row per name. The rule is the first row with
        // counters, not an aggregate, so a working alias outranks a dead one. Recording it as a test
        // because the alternative — any dead alias forcing a rollback — would make the window depend on
        // which name the agent happened to try first.
        let uri = "smp://\(keyHash)@smp1.popopx.chat,smp2.popopx.chat"
        XCTAssertEqual(
            PopopxServerConfigSignalHandler.judge(
                rows: [row("smp1.popopx.chat", connected: 2, errors: 5), row("smp2.popopx.chat", connected: 0, errors: 9)],
                uri: uri
            ),
            .reachable
        )
        XCTAssertEqual(
            PopopxServerConfigSignalHandler.judge(
                rows: [row("smp2.popopx.chat", connected: 0, errors: 9), row("smp1.popopx.chat", connected: 2, errors: 0)],
                uri: uri
            ),
            .unreachable, "the order the agent reported the rows in is the order that decides — see the comment above"
        )
    }

    func testAHostnameThatOnlyContainsOursDoesNotAnswerForTheCluster() {
        let uri = "smp://\(keyHash)@smp1.popopx.chat"
        // `SMPServerSummary.smpServer` is written by the core and its spelling is not defined anywhere in
        // this repository's Swift sources, which is why the matcher accepts the hostname as well as the
        // whole URI — after the port the core appends is stripped, and compared exactly. It is not
        // `contains`, and this is the row that proves the difference: `smp1.popopx.chat.our` embeds one of
        // our names without being one of ours, so it must not be read as evidence either way. A substring
        // matcher would have let that row answer for the cluster, and the two ways it could answer were
        // both unacceptable — a `reachable` from a server we never installed would leave a broken
        // configuration permanently in place, and an `unreachable` would roll a working one back because
        // somebody else went down. The second was the worse half, since a hostile row can always report
        // success, so what exactness really buys is visible here: an ambiguous read is inconclusive, the
        // window stays open, and a later poll or a relaunch settles it. Rows that do match are covered by
        // `testTheProbeReadsOnlyRowsBelongingToTheIntroducedCluster`.
        XCTAssertEqual(
            PopopxServerConfigSignalHandler.judge(rows: [row("smp1.popopx.chat.our", connected: 0, errors: 3)], uri: uri),
            .inconclusive
        )
    }
}
