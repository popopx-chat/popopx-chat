//
//  PopopxAddFriendView.swift
//  POPOPX (iOS)
//
//  第三阶段 2. — 类微信「添加朋友」页面。顶部一个会实时判类的链接输入框，下面并排两个快捷
//  按钮（粘贴加友 / 面对面加友）、我的加密名片条，再下面是厢语广场、扫一扫、分享邀请链接三行。
//
//  路由只有一条规矩：`popopx:/`（含手打的 `popopx://` 与分享形式 `https://popopx.chat/`）走
//  `PopopxMeshRuntime.shared.bridge` 的离线门 —— 模块 2 的 `normalizedInviteLink` 是唯一的前缀
//  闸口，命令行安全字符检查在它里面，所以贴进来的字符串永远不会不打招呼就进到 `/_connect`；
//  `simplex:/` 一类在线/遗留链接交回 app 原有的 `planAndConnect`。链接本身永不伪造：名片二维码
//  与分享都用 `PopopxInviteLink.mintOneTime` 现生成的真链接，拿到 nil 就报失败。
//
//  守的红线：不碰 project.pbxproj（本文件由人手工拖进 target）；颜色/间距/字体/材质/弹簧只取
//  PopopxTheme 的 token；控件只用 Shared/Components 里已有的原子库，不新造第二个按钮或输入框；
//  面对面入口在 iOS 17 之下给出真实降级页而不是一句"稍后再试"。
//

import SwiftUI
import UIKit
import AVFoundation
import CodeScanner
import POPOPXChat
import PopopxMeshKit
import PopopxMeshUI

// MARK: - Link classification

/// 输入框、剪贴板、扫一扫三个入口共用同一份判类结果 —— 三处的路由因此不可能各说各话。
private enum PopopxAddFriendLink: Hashable {
    /// 离线门收的形式。`normalizedInviteLink` 顺手把 `popopx://` 与分享形式规范化成 `popopx:/`。
    case offline
    /// 核心认识的旧 scheme，交回 `planAndConnect` 的在线路径。
    case online
    /// 其余一切：不添加。
    case unknown

    /// 在线/遗留链接的前缀。这是协议字符串判断，不是界面文案 —— 界面上永远不出现这两个词。
    private static let onlinePrefixes = [
        "simplex:/",
        "simplex://",
        "https://simplex.chat/",
        "http://simplex.chat/",
    ]

    static func classify(_ raw: String) -> PopopxAddFriendLink {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return .unknown }
        if PopopxOfflineBridge.normalizedInviteLink(link) != nil { return .offline }
        if onlinePrefixes.contains(where: { link.hasPrefix($0) }) { return .online }
        return .unknown
    }

    var canAdd: Bool { self != .unknown }

    /// 去掉首尾空白后的链接本体；发往门里和在线路径的都是这一个值。
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Page

struct PopopxAddFriendView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    /// 熔断开关的真值要在厢语那一行说出来，所以观察 runtime 而不是在按下时读一次。
    @ObservedObject private var meshRuntime: PopopxMeshRuntime

    @State private var toast = PopopxToastModel()
    @State private var linkText = ""
    /// nil = 剪贴板里没有能判成链接的内容；非 nil 已是去掉空白的规范化字符串。
    @State private var clipboardLink: String?
    @State private var showsScanner = false
    @State private var showsFaceToFace = false
    @State private var showsIdentityPicker = false
    @State private var showsQRCard = false
    @State private var mintingInvite = false
    @State private var qrInvite: PopopxMintedInvite?
    @State private var path: [PopopxAddFriendRoute] = []

    @MainActor init() {
        _meshRuntime = ObservedObject(wrappedValue: PopopxMeshRuntime.shared)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    PopopxAddFriendHeader()
                    PopopxLinkSearchBlock(text: $linkText, submit: { raw in await submit(raw) })
                    PopopxQuickActionsBlock(
                        clipboardLink: $clipboardLink,
                        onPaste: { await pasteAndConnect() },
                        onFaceToFace: { showsFaceToFace = true }
                    )
                    PopopxNameCardBar(
                        identityName: identityName,
                        minting: mintingInvite,
                        onSwitchIdentity: { showsIdentityPicker = true },
                        onShowQRCard: { Task { @MainActor in await presentQRCard() } }
                    )
                    PopopxFeatureRows(
                        fuseOn: meshRuntime.isFuseOn,
                        onPlaza: { path.append(.meshPlaza) },
                        onScan: { showsScanner = true },
                        onShare: { Task { @MainActor in await shareMyLink() } }
                    )
                }
                .padding(.bottom, PopopxMetrics.space2XL)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PopopxPalette.base)
            .navigationDestination(for: PopopxAddFriendRoute.self) { route in
                switch route {
                case .meshPlaza:
                    // 挂载方式照抄 SettingsView 那一行：三个对象全部来自 runtime，页面自己在熔断
                    // 关闭时渲染"已关闭"状态，所以这一行永远可以点。
                    MeshPlazaView(
                        outbound: meshRuntime.engineBackend,
                        source: meshRuntime.stateSource,
                        killSwitch: meshRuntime.killSwitch
                    )
                    .navigationTitle(Copy.plazaNavigationTitle)
                    .modifier(ThemedBackground(grouped: true))
                }
            }
            .toolbar {
                if isPresented {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Copy.close) { dismiss() }
                            .font(PopopxType.emphasis)
                            .foregroundStyle(PopopxPalette.brand)
                            .frame(minHeight: PopopxMetrics.minHitTarget)
                            .buttonStyle(PopopxPressButtonStyle())
                    }
                }
            }
        }
        .background(PopopxPalette.base)
        .environmentObject(AppTheme.shared)
        .popopxToast(toast)
        .sheet(isPresented: $showsScanner) {
            PopopxScannerSheet(onScan: { scanned in
                linkText = scanned
                Task { @MainActor in await submit(scanned) }
            })
        }
        .sheet(isPresented: $showsFaceToFace) {
            if #available(iOS 17.0, *) {
                PopopxProximityAddContactView(nickname: nil)
            } else {
                PopopxFaceToFaceUnsupportedSheet()
            }
        }
        .sheet(isPresented: $showsIdentityPicker) {
            PopopxIdentityPickerSheet(showsPicker: $showsIdentityPicker)
        }
        .sheet(isPresented: $showsQRCard, onDismiss: { qrInvite = nil }) {
            if let invite = qrInvite {
                PopopxQRCardSheet(uri: invite.uri, identityName: identityName)
            }
        }
        .onAppear { refreshClipboard() }
        // 用户很可能在别的 app 里复制完再切回来，只有回前台那一刻的剪贴板才算数。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshClipboard()
        }
    }

    /// 名片条与二维码卡片共用的身份名：空昵称不猜，直接落到「未命名身份」。
    private var identityName: String {
        let name = PopopxAddFriendLink.normalized(chatModel.currentUser?.displayName ?? "")
        return name.isEmpty ? Copy.unnamedIdentity : name
    }

    // MARK: Routing

    /// 唯一的加友入口：输入框、粘贴、扫一扫三条路都汇到这里。
    @MainActor private func submit(_ raw: String) async {
        let link = PopopxAddFriendLink.normalized(raw)
        switch PopopxAddFriendLink.classify(link) {
        case .offline:
            await acceptOffline(link)
        case .online:
            planAndConnect(link, theme: AppTheme.shared, dismiss: false)
            toast.show(Copy.onlineHandoffToast, kind: .encrypted)
        case .unknown:
            PopopxHaptics.notice(.error)
            toast.show(Copy.unrecognizedToast, kind: .danger)
        }
    }

    @MainActor private func acceptOffline(_ link: String) async {
        do {
            let acceptance = try await meshRuntime.bridge.acceptOfflineInviteLink(link)
            linkText = ""
            PopopxHaptics.notice(.success)
            switch acceptance.kind {
            case .confirmation:
                // 我们吃下的是对方的邀请：这一侧现在等对方通过。
                toast.show(Copy.offlineConfirmationToast, kind: .mesh)
            case .invitation:
                // 我们带着邀请走到对方的联系人地址上：连接由对方那边确认。
                toast.show(Copy.offlineInvitationToast, kind: .mesh)
            }
        } catch let bridgeError {
            // `acceptOfflineInviteLink` 是类型化抛出（`throws(PopopxOfflineBridgeError)`），
            // 这里拿到的就是它本身，不再下转。
            if case .inviteLinkRejected = bridgeError {
                // 门里拒绝的一律不是我们铸的链接，交回在线路径而不是就地报错。
                planAndConnect(link, theme: AppTheme.shared, dismiss: false)
                toast.show(Copy.onlineHandoffToast, kind: .encrypted)
            } else {
                logger.error("popopx add friend: offline accept failed: \(String(describing: bridgeError))")
                PopopxHaptics.notice(.error)
                toast.show(Copy.offlineFailedToast, kind: .danger)
            }
        }
    }

    @MainActor private func pasteAndConnect() async {
        // 按下这一刻再读一次：剪贴板可能在亮起点之后就被改掉了。
        refreshClipboard()
        guard let link = clipboardLink else {
            PopopxHaptics.notice(.warning)
            toast.show(Copy.clipboardEmptyToast, kind: .danger)
            return
        }
        linkText = link
        await submit(link)
    }

    @MainActor private func refreshClipboard() {
        guard UIPasteboard.general.hasStrings, let raw = UIPasteboard.general.string else {
            clipboardLink = nil
            return
        }
        let link = PopopxAddFriendLink.normalized(raw)
        clipboardLink = PopopxAddFriendLink.classify(link).canAdd ? link : nil
    }

    // MARK: Minting

    /// 现用现铸：一次性链接被复用就没有意义，所以名片和分享各自 mint 一次，拿不到就是失败。
    @MainActor private func mintInvite() async -> PopopxMintedInvite? {
        guard !mintingInvite else { return nil }
        mintingInvite = true
        let invite = await PopopxInviteLink.mintOneTime(incognito: false)
        mintingInvite = false
        if invite == nil {
            PopopxHaptics.notice(.error)
            toast.show(Copy.mintFailedToast, kind: .danger)
        }
        return invite
    }

    @MainActor private func presentQRCard() async {
        guard let invite = await mintInvite() else { return }
        qrInvite = invite
        showsQRCard = true
    }

    @MainActor private func shareMyLink() async {
        guard let invite = await mintInvite() else { return }
        showShareSheet(items: [invite.uri])
    }
}

// MARK: - Push routes

private enum PopopxAddFriendRoute: Hashable {
    case meshPlaza
}

// MARK: - Header

private struct PopopxAddFriendHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(Copy.pageTitle)
                .font(PopopxType.title)
                .foregroundStyle(PopopxPalette.label)
            Text(Copy.pageExplainer)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Search block

private struct PopopxLinkSearchBlock: View {
    @Binding var text: String
    let submit: (String) async -> Void

    private var link: PopopxAddFriendLink { PopopxAddFriendLink.classify(text) }

    var body: some View {
        PopopxSectionCard(Copy.searchTitle, footnote: Copy.searchFootnote) {
            PopopxTextField(
                Copy.linkHint,
                prompt: Copy.linkHint,
                text: $text,
                systemImage: "link",
                keyboard: .URL,
                onSubmit: { raw in Task { @MainActor in await submit(raw) } }
            )
            HStack(spacing: PopopxMetrics.spaceXS) {
                verdict
                    .frame(maxWidth: .infinity, alignment: .leading)
                PopopxButton(Copy.add, systemImage: "arrow.right.circle.fill", role: .primary, fullWidth: false) {
                    await submit(text)
                }
                .disabled(!link.canAdd)
            }
            .font(PopopxType.meta)
            .padding(.top, PopopxMetrics.spaceS)
        }
    }

    /// 判类结果同时是"能不能添加"的说明，所以三档各有各的颜色，不给灰色兜底。
    @ViewBuilder private var verdict: some View {
        switch link {
        case .offline:
            Label(Copy.addableVerdict, systemImage: "checkmark.seal.fill")
                .foregroundStyle(PopopxPalette.brand)
        case .online:
            Label(Copy.onlineVerdict, systemImage: "cloud.fill")
                .foregroundStyle(PopopxPalette.labelSecondary)
        case .unknown:
            Text(Copy.linkHint)
                .foregroundStyle(PopopxPalette.labelHint)
        }
    }
}

// MARK: - Quick actions

private struct PopopxQuickActionsBlock: View {
    @Binding var clipboardLink: String?
    let onPaste: () async -> Void
    let onFaceToFace: () -> Void

    var body: some View {
        PopopxSectionCard(Copy.quickActionsTitle) {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    PopopxButton(Copy.pasteAction, systemImage: "doc.on.clipboard", role: .secondary) {
                        await onPaste()
                    }
                    .disabled(clipboardLink == nil)
                    HStack(spacing: PopopxMetrics.space2XS) {
                        if clipboardLink != nil {
                            PopopxBreathingDot()
                        }
                        Text(clipboardLink == nil ? Copy.pasteNoteEmpty : Copy.pasteNoteReady)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .padding(.leading, PopopxMetrics.space2XS)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    PopopxButton(Copy.faceToFaceAction, systemImage: "dot.radiowaves.left.and.right", role: .primary) {
                        onFaceToFace()
                    }
                    Text(Copy.faceToFaceSubtitle)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, PopopxMetrics.space2XS)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 青绿呼吸光点：剪贴板里确实有一条能加的链接时才亮。Reduce Motion 下画静止点 ——
/// 一个不会动的点仍然是点，一次不会停的呼吸才是问题。
private struct PopopxBreathingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(PopopxPalette.meshInk)
            .frame(width: PopopxMetrics.spaceXS, height: PopopxMetrics.spaceXS)
            .opacity(reduceMotion ? 1 : (expanded ? 0.4 : 1))
            .scaleEffect(reduceMotion ? 1 : (expanded ? 0.65 : 1.1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    expanded = true
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Name card bar

private struct PopopxNameCardBar: View {
    let identityName: String
    let minting: Bool
    let onSwitchIdentity: () -> Void
    let onShowQRCard: () -> Void

    var body: some View {
        PopopxSectionCard(Copy.nameCardTitle) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                circleButton(
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: .neutral,
                    label: Copy.switchIdentityLabel,
                    busy: false,
                    action: onSwitchIdentity
                )
                VStack(spacing: PopopxMetrics.space2XS) {
                    Text(identityName)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(1)
                    Text(Copy.nameCardNote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                }
                .frame(maxWidth: .infinity)
                circleButton(
                    systemImage: "qrcode",
                    tint: .brand,
                    label: Copy.qrCardLabel,
                    busy: minting,
                    action: onShowQRCard
                )
            }
            .frame(minHeight: PopopxMetrics.minHitTarget)
        }
    }

    /// 两个圆钮左右对称，中间的身份名因此是真的居中而不是被推到一边。
    private func circleButton(
        systemImage: String,
        tint: PopopxIconTint,
        label: String,
        busy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(PopopxType.microTag)
                        .imageScale(.large)
                }
            }
            .foregroundStyle(tint.ink)
            .tint(tint.ink)
            .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
            .background(tint.fill, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(busy)
        .accessibilityLabel(label)
    }
}

// MARK: - Feature rows

private struct PopopxFeatureRows: View {
    let fuseOn: Bool
    let onPlaza: () -> Void
    let onScan: () -> Void
    let onShare: () -> Void

    var body: some View {
        PopopxSectionCard(Copy.moreTitle) {
            // 熔断关掉只改变这一行说了什么，不改变它能不能点开：广场页自己会渲染关闭状态。
            PopopxPickerRow(
                Copy.plazaRow,
                value: fuseOn ? nil : Copy.fuseOffValue,
                systemImage: "antenna.radiowaves.left.and.right",
                tint: .mesh,
                action: onPlaza
            )
            rowSeparator
            PopopxPickerRow(Copy.scanRow, systemImage: "qrcode.viewfinder", tint: .neutral, action: onScan)
            rowSeparator
            PopopxPickerRow(Copy.shareRow, systemImage: "square.and.arrow.up", tint: .brand, action: onShare)
        }
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - Scanner sheet

private struct PopopxScannerSheet: View {
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var cameraStatus: AVAuthorizationStatus?
    /// 换一次 id 就是重建 `CodeScannerView`：会话已经结束的失败（badInput 等）只能这样重试。
    @State private var scanAttempt = 0
    @State private var failureNote: String?

    var body: some View {
        PopopxSheetContainer(Copy.scanRow, subtitle: Copy.scannerSubtitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                content
                if let failureNote {
                    Text(failureNote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            PopopxButton(Copy.close, role: .secondary) { dismiss() }
                .padding(PopopxMetrics.spaceM)
        }
        .task { await ensureCameraAccess() }
    }

    @ViewBuilder private var content: some View {
        switch cameraStatus {
        case .authorized:
            CodeScannerView(codeTypes: [.qr], scanMode: .oncePerCode, completion: handleScan)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: PopopxMetrics.radiusCard))
                .id(scanAttempt)
        case .notDetermined:
            // `.task` 已经把系统授权弹窗发出去了，这一格就是弹窗后面的那几帧。
            placeholder(systemImage: "camera", text: Copy.cameraStarting)
        case .denied:
            placeholder(
                systemImage: "video.slash",
                text: Copy.cameraDenied,
                actionTitle: Copy.openSettings,
                action: { UIApplication.shared.open(appSettingsURL) }
            )
        case .restricted:
            placeholder(systemImage: "nosign", text: Copy.cameraRestricted)
        default:
            // 还没读到状态（nil）与系统将来新增的状态都落在这里，而不是留一个空格子。
            placeholder(systemImage: "questionmark", text: Copy.cameraUnknown)
        }
    }

    private func placeholder(
        systemImage: String,
        text: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        PopopxScannerPlaceholder(
            systemImage: systemImage,
            text: text,
            actionTitle: actionTitle,
            action: action
        )
    }

    @MainActor private func ensureCameraAccess() async {
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            status = granted ? .authorized : .denied
        }
        cameraStatus = status
    }

    private func handleScan(_ result: Result<ScanResult, ScanError>) {
        switch result {
        case let .success(scan):
            failureNote = nil
            onScan(scan.string)
            dismiss()
        case let .failure(error):
            failureNote = String(format: Copy.scanFailedFormat, error.localizedDescription)
            switch error {
            case .permissionDenied:
                // 用户在相机会话里拒了权限：交回上面的 switch 说"去系统设置"，重试没有意义。
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            default:
                // badInput / badOutput / initError 都是会话本身没起来，重建一次比报错有用。
                scanAttempt += 1
            }
        }
    }
}

private struct PopopxScannerPlaceholder: View {
    let systemImage: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            Image(systemName: systemImage)
                .font(PopopxType.title)
                .foregroundStyle(PopopxPalette.labelSecondary)
            Text(text)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let run = action {
                PopopxButton(actionTitle, systemImage: "gearshape", role: .secondary, fullWidth: false) {
                    run()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .padding(PopopxMetrics.spaceM)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
    }
}

// MARK: - Face to face, below iOS 17

/// 面对面加友的双引擎（`PopopxProximityAddContactView`）要 iOS 17 的 NearbyInteraction。降级页
/// 给的是能走通的另一条路，不是一句"不支持"。
private struct PopopxFaceToFaceUnsupportedSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PopopxSheetContainer(Copy.faceToFaceAction) {
            Label(Copy.faceToFaceUnsupported, systemImage: "exclamationmark.circle")
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            // 关掉这一张，扫一扫那一行就在页面下面，不用替用户抢一次展示机会。
            PopopxButton(Copy.gotIt, role: .secondary) { dismiss() }
                .padding(PopopxMetrics.spaceM)
        }
    }
}

// MARK: - Identity picker

/// 复用已有的 `UserPicker`：切身份的 `changeActiveUserAsync_` 只活在那一处，这里不重写第二份。
private struct PopopxIdentityPickerSheet: View {
    @Binding var showsPicker: Bool

    @State private var nestedSheet: UserPickerSheet?

    var body: some View {
        UserPicker(userPickerShown: $showsPicker, activeSheet: $nestedSheet)
            .appSheet(item: $nestedSheet) { sheet in
                UserPickerSheetView(sheet: sheet)
            }
    }
}

// MARK: - Copy

/// 页面上每一句中文只在这里出现一次。
private enum Copy {
    static let pageTitle = NSLocalizedString("Add Friend", comment: "")
    static let pageExplainer = NSLocalizedString("An invitation link is a one-time encrypted address: whoever opens it can start a connection with you. Links starting with popopx: reach the other side over the Bluetooth mesh relay when there is no internet.", comment: "")
    static let close = NSLocalizedString("Close", comment: "")
    static let gotIt = NSLocalizedString("Got it", comment: "")

    static let searchTitle = NSLocalizedString("Invitation link", comment: "")
    static let linkHint = NSLocalizedString("Paste or type a POPOPX invitation link", comment: "")
    static let searchFootnote = NSLocalizedString("Addable = this device's offline gate opens the connection directly; online invitation = handed to the encrypted server.", comment: "")
    static let add = NSLocalizedString("Add", comment: "")
    static let addableVerdict = NSLocalizedString("Addable", comment: "")
    static let onlineVerdict = NSLocalizedString("Online invitation", comment: "")

    static let quickActionsTitle = NSLocalizedString("Quick ways to add", comment: "")
    static let pasteAction = NSLocalizedString("Paste to add", comment: "")
    static let pasteNoteReady = NSLocalizedString("The clipboard holds an addable link", comment: "")
    static let pasteNoteEmpty = NSLocalizedString("No invitation link in the clipboard yet", comment: "")
    static let faceToFaceAction = NSLocalizedString("Add face to face", comment: "")
    static let faceToFaceSubtitle = NSLocalizedString("Move close and it senses automatically, or tap the top to connect", comment: "")
    static let faceToFaceUnsupported = NSLocalizedString("This system version does not support face-to-face adding; use Scan QR code instead", comment: "")

    static let nameCardTitle = NSLocalizedString("My encrypted card", comment: "")
    static let nameCardNote = NSLocalizedString("Sent from the current anonymous identity", comment: "")
    static let unnamedIdentity = NSLocalizedString("Unnamed identity", comment: "")
    static let switchIdentityLabel = NSLocalizedString("Switch anonymous identity", comment: "")
    static let qrCardLabel = NSLocalizedString("Show my QR code card", comment: "")

    static let moreTitle = NSLocalizedString("More ways", comment: "")
    static let plazaRow = NSLocalizedString("Find nearby groups and channels over the Bluetooth mesh", comment: "")
    /// 广场页的标题。本文件其余句子仍是中文直写（整页转 Key 另立一轮），这一句先收口：
    /// 厢语左上角现在推的是同一个页面（`PopopxCabinView.swift` 的 `.plaza`），两处共用
    /// Key `Nearby mesh plaza`，16 个译本目录里各有一句，非中文系统下不再漏出中文标题。
    static let plazaNavigationTitle = NSLocalizedString("Nearby mesh plaza", comment: "POPOPX nearby mesh plaza")
    static let fuseOffValue = NSLocalizedString("Closed by the fuse", comment: "")
    static let scanRow = NSLocalizedString("Scan QR code", comment: "")
    static let shareRow = NSLocalizedString("Share my secure invitation link", comment: "")

    static let scannerSubtitle = NSLocalizedString("Only the invitation link inside the code is read; nothing else leaves this device.", comment: "")
    static let cameraStarting = NSLocalizedString("Preparing the camera…", comment: "")
    static let cameraDenied = NSLocalizedString("Camera access is turned off; enable it in the system settings", comment: "")
    static let cameraRestricted = NSLocalizedString("The camera is not available on this device", comment: "")
    static let cameraUnknown = NSLocalizedString("This device's camera status is unknown", comment: "")
    static let openSettings = NSLocalizedString("Open Settings", comment: "")
    static let scanFailedFormat = NSLocalizedString("Nothing read; aim at the QR code and try again: %@", comment: "")

    static let offlineConfirmationToast = NSLocalizedString("Their invitation was accepted; waiting for them to let you in", comment: "")
    static let offlineInvitationToast = NSLocalizedString("A connection has been started; see the contact's details", comment: "")
    static let onlineHandoffToast = NSLocalizedString("Handed to the online encrypted channel to connect", comment: "")
    static let unrecognizedToast = NSLocalizedString("This is neither a POPOPX link nor an online invitation link", comment: "")
    static let offlineFailedToast = NSLocalizedString("The offline connection failed; please try again later", comment: "")
    static let mintFailedToast = NSLocalizedString("Could not create the link", comment: "")
    static let clipboardEmptyToast = NSLocalizedString("No usable link in the clipboard", comment: "")
}

struct PopopxAddFriendView_Previews: PreviewProvider {
    static var previews: some View {
        PopopxAddFriendView()
            .environmentObject(ChatModel.shared)
            .environmentObject(AppTheme.shared)
    }
}
