//
//  ProfileQRCodeSheet.swift
//  POPOPX (iOS)
//
//  【加密个人主页 · 模块三】专属主页名片码。一张 Wallet 质感的名片：紫色品牌底 + 当前匿名身份 +
//  二维码 + 本张码分发的那一档模式，卡内可直接切换"常驻名片 / 打开后阅后即焚"，并把这一档**武装**
//  给"扫码建连后自动推送"（`ProfileAutoSender.shared`）。
//
//  界面外形全部照 `Shared/Features/AddFriend/PopopxQRCardSheet.swift` 抄（它是本工程唯一一枚
//  pass 卡）：`passCard` / `passSurface` / `passGradient` / `qrPlate` / `qrInk` / `linkPreview` /
//  `securityNote` / `closeButton` / `actionRow` + `private enum Copy`。这里不重发明任何一件视觉规则，
//  只多三样东西：模式分段、武装状态、相册保存。
//
//  ### 红线（本文件必须遵守的那几条）
//  - **本文件必须人工拖入 POPOPX (iOS) target；禁止用脚本修改 project.pbxproj。**
//  - 二维码只用现成的 `POPOPXLinkQRCode`（`Shared/Views/NewChat/QRCode.swift:37`），这里不写一行
//    CIFilter；颜色/间距/字体/材质全部来自 `PopopxTheme`；分享只用 `showShareSheet(items:)`
//    （`Shared/Views/Helpers/ShareSheet.swift:27`），不新建 activityViewController 变体。
//  - Sheet 自己不装导航容器、不自带头部栏；dismiss 归 `PopopxSheetContainer` 的调用方
//    （PopopxQRCardSheet.swift:13-15 那条裁定），但关闭钮由本页给一颗（同 :174-182 的做法）。
//  - 每一句中文只在 `Copy` 里出现一次。
//
//  ### 二维码里装的是"联系地址"，不是主页本身（已实测的结论，WHY 就一行）
//  `POPOPXLinkQRCode` 内部把 `uri` 再过一次 `popopxChatLink()`（QRCode.swift:44 →
//  APITypes.swift:194-198），那个函数只替换 `popopx:/` 前缀；直接把 `popopx://profile?…` 喂进去会被
//  改写成 `https://popopx.chat//profile?…`（多出来的那一个斜杠就是它把 `popopx:/` 换成
//  `https://popopx.chat/` 之后剩下的第二个 `/`），扫出来是一个本 app 路由不到的地址。所以本码承载
//  `PopopxInviteLink.mintOneTime` 铸出的联系地址，主页由 `ProfileAutoSender` 在建连之后另发一条消息。
//  传进去的那一枚已经是 `popopxChatLink` 处理过的形态（PopopxTelemetryHeader.swift:361），再过一次是恒等，
//  这一点是这个复用能成立的前提，不是巧合。
//
//  ### 飞行模式下这张码能做什么、不能做什么（不假装有离线钩子）
//  它仍然是一条真的 `/_connect` 邀请：`PopopxInviteLink.mintOneTime` 底下就是
//  `apiAddContact(incognito:)`（POPOPXAPI.swift:1039），与模块 6 离线配对的第一步同一个命令
//  （`PopopxMeshChatCore.createOfflineInvite`，POPOPXAPI.swift:3430-3434 交回的就是
//  `CreatedConnLink.connFullLink`）。**但它不能把主页从蓝牙递过去**：厢语那一条的邀请串要
//  `PopopxOfflineBridge.generateOfflineInviteLink(meshPublicKeyHex:incognito:)`
//  （PopopxOfflineBridge.swift:138）里的**对方厢语公钥**，而一枚摆在屏幕上等人扫的静态码不可能预先
//  知道来扫的是哪台设备（现网每一个调用点都从一次真实的近场会话里拿到那颗公钥：
//  ManualPairingManager.swift:133/:151、PopopxProximityEngine.swift:638/:643）。桥本身也不对 app 层
//  开放：它只在 `PopopxMeshRuntime` 的私有 init 里被建出来一次（POPOPXAPI.swift:3677）。
//  所以本卡片**不调用**离线桥，只在卡下把这一条如实写明；断网时主页发不出去由
//  `ProfileAutoSender` 的降级分支（纯文字）负责，而不是靠这张码。
//
//  ### 武装状态存在哪里（同一条裁定的另一半）
//  `scene=personal_profile` 不进 URI：`apiAddContact` 交回的串归 Rust 核心、`popopxChatLink` 会改写
//  前缀、离线桥又禁 `$ \` " '`（PopopxOfflineBridge.swift:101），所以它是**本机**的武装元数据，
//  存在 `ProfileAutoSender.shared.armedProfileScene` 里，由 `contactConnected` 那一个既有钩子消费。
//  页面上这一格只是那一份状态的一份**显示镜像**：真值永远在 sender 那一侧，本视图不写第二份。
//

import POPOPXChat
import SwiftUI
import UIKit

/// 主页名片码。标 `@MainActor` 是因为要读写 `ProfileAutoSender`（那是一枚主 actor 单例）——
/// 与同特性的 `ProfileSendModeSheet`（ProfileBuilderView.swift:818）同一个写法。
@MainActor
struct ProfileQRCodeSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var toast = PopopxToastModel()

    private let identityName: String
    private let store: ProfileStorageManager

    /// 铸好的联系地址（`https://popopx.chat/…` 形态）。`nil` = 还没铸好，QR 那一格是占位。
    @State private var invite: String?
    /// 预生成的二维码位图。存在的理由有两个：截图存档时必须有一张扫得开的码（`QRCode` 自己的
    /// `.task` 在 `makeScreenshot` 那条离屏渲染路径上不会跑），以及重铸之后不留旧码的残影。
    @State private var qrBitmap: UIImage?
    /// 铸链的失败原因。`apiAddContact` 吞掉错误只返回 nil（POPOPXAPI.swift:1039），所以这一句
    /// 只能由这里给；它同时是占位那一格里"重试"按钮存在的理由。
    @State private var mintFailure: String?
    @State private var isMinting = false

    /// 本机已保存的主页。决定武装之后那一次自动推送有没有内容可发（没有则 sender 以
    /// `.noSavedProfile` 拒掉），所以这里必须在卡上说清楚。
    @State private var saved: PopopxProfileManifest?
    @State private var isLoadingProfile = true

    /// 本张码分发的那一档。初值取已保存主页自己的那一格（`ProfileSendModeSheet` 同一个来路，
    /// ProfileBuilderView.swift:901-:908），没保存过时停在常驻档。
    @State private var sendMode: PopopxProfileSendMode = .standard
    @State private var ttlSeconds = ProfileBuilderViewModel.defaultEphemeralTTL

    /// `armedProfileScene` 的显示镜像。见文件头那一节。
    @State private var armedScene: PopopxArmedProfileScene?

    init(identityName: String, store: ProfileStorageManager = .shared) {
        self.identityName = identityName
        self.store = store
    }

    var body: some View {
        PopopxSheetContainer(Copy.sheetTitle, subtitle: Copy.sheetSubtitle) {
            closeButton
            passCard
            modeCard
            offlineNote
        } footer: {
            actionRow
        }
        .popopxToast(toast)
        // 打开时才铸链、才读盘：一枚摆在屏幕上的码如果复用上一次打开时的那条链接，
        // 它对应的 `PendingContactConnection` 可能早已被扫掉 —— 一次性链接的"一次性"归核心管，
        // 这里能保证的是"每次打开都是一条新的"。`.task` 随 Sheet 消失自动取消，不需要 onDisappear 收尾。
        .task {
            await loadProfile()
            await mint()
        }
    }

    // MARK: - Pass 卡体

    private var passCard: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(Copy.issuerOverline)
                        .font(PopopxType.microTag)
                        .foregroundStyle(PopopxPalette.onBrand)
                    Text(identityName)
                        .font(PopopxType.title)
                        .foregroundStyle(PopopxPalette.onBrand)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    modeBadge
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: PopopxMetrics.spaceXS)
                Image(PopopxBrandAsset.mark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                    .clipShape(.rect(cornerRadius: PopopxMetrics.radiusChip, style: .continuous))
                    .accessibilityHidden(true)
            }

            qrPlate
        }
        .padding(PopopxMetrics.spaceL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { passSurface }
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusSheet, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .popopxCardElevation(colorScheme: colorScheme)
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    /// 品牌底只用 `brand` 自身与它的暗一档，不画紫→蓝（`PopopxQRCardSheet.swift:93-111` 那一条
    /// 渐变例外的原样照抄：`label` 垫底，`onBrand` 两端都还在 4.5:1 之上）。
    private var passSurface: some View {
        ZStack {
            PopopxPalette.label
            Rectangle().fill(passGradient)
        }
        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusSheet, style: .continuous))
    }

    private var passGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: PopopxPalette.brand, location: 0),
                .init(color: PopopxPalette.brand.opacity(0.92), location: 0.45),
                .init(color: PopopxPalette.brand.opacity(Pass.dimOpacity(for: colorScheme)), location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 卡上的模式标签：这一枚二维码将分发出去的是哪一档。文案取自载荷层
    /// （`PopopxProfileSendMode.cardLabel`，PersonalProfileModel.swift:61），时长取自
    /// `PopopxSecureCopy.duration`（PopopxSecurePayload.swift:357）—— 不在这里抄第二张表。
    private var modeBadge: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: sendMode == .ephemeral ? "hourglass" : "person.badge.plus")
                .font(PopopxType.microTag)
            Text(badgeText)
                .font(PopopxType.microTag)
        }
        .foregroundStyle(PopopxPalette.onBrand)
        .padding(.horizontal, PopopxMetrics.spaceXS)
        .padding(.vertical, PopopxMetrics.space2XS)
        .background(PopopxMaterial.chip, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Copy.badgeAccessibility)
        .accessibilityValue(badgeText)
    }

    private var badgeText: String {
        sendMode == .ephemeral
            ? "\(sendMode.cardLabel) · \(PopopxSecureCopy.duration(effectiveTTLSeconds))"
            : sendMode.cardLabel
    }

    /// 真正会被武装出去的那一个时长。`standard` 档恒为 0（协议那一侧的口径，
    /// PersonalProfileModel.swift:399-406），界面这一格选了也不算。
    private var effectiveTTLSeconds: Int {
        sendMode == .ephemeral ? ttlSeconds : 0
    }

    // MARK: - QR 面板

    private var qrPlate: some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            if let invite {
                POPOPXLinkQRCode(uri: invite, withLogo: true, tintColor: qrInk)
                    .environment(\.fixedQRCode, qrBitmap)
                    .aspectRatio(1, contentMode: .fit)

                Text(linkPreview(invite))
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                qrPlaceholder
            }
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.qrAccessibilityLabel)
        .accessibilityValue(invite ?? Copy.qrNotReadyValue)
    }

    /// 没铸好时那一格。失败与还在铸说两种话（把"网络不通"和"稍等"混成一句会让用户白等一次）。
    private var qrPlaceholder: some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            if let mintFailure {
                Label {
                    Text(mintFailure)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.dangerInk)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PopopxPalette.danger)
                }
                PopopxButton(Copy.retry, systemImage: "arrow.clockwise", role: .secondary) {
                    await mint()
                }
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .tint(PopopxPalette.brand)
                Text(Copy.minting)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: Pass.qrPlaceholderHeight)
    }

    /// 扫码读的是亮度差，不是品牌的抛光：码永远落在 `card` 面上（照抄
    /// PopopxQRCardSheet.swift:115-117 那条结论）。
    private var qrInk: UIColor {
        UIColor(PopopxPalette.brand).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        )
    }

    private func linkPreview(_ uri: String) -> String {
        uri.count > Pass.linkPreviewCharacters
            ? String(uri.prefix(Pass.linkPreviewCharacters)) + "…"
            : uri
    }

    // MARK: - 模式与武装

    private var modeCard: some View {
        PopopxSectionCard(Copy.modeGroup, footnote: Copy.armFootnote) {
            PopopxSegmentedControl(
                [PopopxProfileSendMode.standard, .ephemeral].map {
                    PopopxSegmentedControl<PopopxProfileSendMode>.Option(selection: $0, title: $0.sheetLabel)
                },
                title: \.sheetLabel,
                selection: modeSelection
            )
            .accessibilityIdentifier("popopx.profile.qr.modeSegment")

            if sendMode == .ephemeral {
                inlineDivider
                PopopxSegmentedControl(
                    ProfileBuilderViewModel.ttlChoices.map {
                        PopopxSegmentedControl<Int>.Option(selection: $0, title: PopopxSecureCopy.duration($0))
                    },
                    title: { PopopxSecureCopy.duration($0) },
                    selection: ttlSelection
                )
                .accessibilityIdentifier("popopx.profile.qr.ttlSegment")
            }

            Text(modeNote)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, PopopxMetrics.space2XS)

            if saved == nil && !isLoadingProfile {
                Text(Copy.noSavedProfileNote)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, PopopxMetrics.space2XS)
            }

            inlineDivider

            HStack(spacing: PopopxMetrics.spaceS) {
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(armedScene == nil ? Copy.armIdle : armedSummary)
                        .font(PopopxType.meta)
                        .foregroundStyle(armedScene == nil ? PopopxPalette.labelSecondary : PopopxPalette.brand)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
                if armedScene != nil {
                    PopopxButton(Copy.cancelArmed, systemImage: "xmark.circle", role: .secondary, fullWidth: false) {
                        cancelArming()
                    }
                    .accessibilityIdentifier("popopx.profile.qr.cancelArmed")
                }
            }
            .frame(minHeight: PopopxMetrics.minHitTarget)
        }
    }

    /// 武装状态那一句回显。读的是 sender 的真值快照，不是界面自己猜的：过期时间由那边定
    /// （`ProfileAutoSender.armingWindowSeconds`），这里只把它念出来。
    private var armedSummary: String {
        guard let armedScene else { return Copy.armIdle }
        let remaining = Int(armedScene.expiresAt.timeIntervalSinceNow)
        guard remaining > 0 else { return Copy.armExpired }
        let minutes = remaining / 60 + 1
        guard armedScene.mode == .ephemeral else {
            return String(format: Copy.armActiveStandardFormat, armedScene.mode.cardLabel, minutes)
        }
        return String(
            format: Copy.armActiveEphemeralFormat,
            armedScene.mode.cardLabel,
            minutes,
            PopopxSecureCopy.duration(armedScene.ttlSeconds)
        )
    }

    /// 切换即武装。走 `Binding` 的 setter 而不是 `.onChange`：`.onChange` 会把 `loadProfile()`
    /// 那一次**程序性**赋值也算成一次用户意图，于是打开这枚 Sheet 就静默武装了一次自动推送。
    private var modeSelection: Binding<PopopxProfileSendMode> {
        Binding(get: { sendMode }, set: { arm(mode: $0, ttl: ttlSeconds) })
    }

    private var ttlSelection: Binding<Int> {
        Binding(get: { ttlSeconds }, set: { arm(mode: sendMode, ttl: $0) })
    }

    private func arm(mode: PopopxProfileSendMode, ttl: Int) {
        sendMode = mode
        ttlSeconds = ttl
        // 为什么是 `ttlIsBoundToContact: true`：这张卡面上的那一格时长就是对方拿到的时长。
        // 选了"5 分钟"却按已保存主页自己的 60 秒发出去，是让用户对着一枚码说谎。
        ProfileAutoSender.shared.armProfileScene(mode: mode, ttlSeconds: ttl, ttlIsBoundToContact: true)
        armedScene = ProfileAutoSender.shared.armedProfileScene
        // `.success` 而不是 `.encrypted`/`.mesh`：武装是一次本机状态改动，两条链路都还没动过。
        toast.show(Copy.armToast, kind: .success)
        PopopxHaptics.notice(.success)
    }

    private func cancelArming() {
        ProfileAutoSender.shared.cancelArmedProfileScene()
        armedScene = nil
        toast.show(Copy.cancelArmedToast, kind: .success)
        PopopxHaptics.notice(.warning)
    }

    private var modeNote: String {
        switch sendMode {
        case .standard: return Copy.standardNote
        case .ephemeral: return Copy.ephemeralNote
        }
    }

    private var inlineDivider: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }

    // MARK: - 说明与动作

    private var offlineNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "lock.shield.fill")
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxPalette.brand)
            Text(Copy.securityNote)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    private var closeButton: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Spacer(minLength: PopopxMetrics.spaceXS)
            PopopxButton(Copy.close, systemImage: "xmark", role: .secondary, fullWidth: false) {
                // 关闭**不**取消武装：这枚卡片的用法就是"出示 → 收起 → 等对方扫"。
                // 武装的两次收束只有 `cancelArmedProfileScene()` 和 sender 自己的有效期。
                dismiss()
            }
        }
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    private var actionRow: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            PopopxButton(Copy.share, systemImage: "square.and.arrow.up", role: .primary, isLoading: isMinting) {
                share()
            }
            .accessibilityIdentifier("popopx.profile.qr.share")
            PopopxButton(Copy.saveAlbum, systemImage: "square.and.arrow.down", role: .secondary, fullWidth: false) {
                saveToAlbum()
            }
            .accessibilityIdentifier("popopx.profile.qr.saveAlbum")
            .disabled(invite == nil)
            PopopxButton(Copy.regen, systemImage: "arrow.clockwise", role: .ghost, fullWidth: false) {
                await mint()
            }
            .accessibilityIdentifier("popopx.profile.qr.regen")
        }
        .padding(PopopxMetrics.spaceM)
    }

    // MARK: - 动作实现

    /// 铸一条一次性连接链接。**不自己拼串**：`PopopxInviteLink.mintOneTime` 底下就是
    /// `apiAddContact(incognito:)` + `popopxChatUri(short:)` + `popopxChatLink`
    /// （PopopxTelemetryHeader.swift:359-362），返回的已经是 `https://popopx.chat/…` 形态。
    /// 失败时 `apiAddContact` 不抛只返回 nil（POPOPXAPI.swift:1039），所以这里必须给可见反馈。
    private func mint() async {
        guard !isMinting else { return }
        isMinting = true
        defer { isMinting = false }
        invite = nil
        qrBitmap = nil
        mintFailure = nil
        guard let minted = await PopopxInviteLink.mintOneTime(incognito: incognitoGroupDefault.get()) else {
            mintFailure = Copy.mintFailedNote
            logger.error("POPOPX profile QR: 一次性连接链接铸不出来（apiAddContact 返回 nil）")
            PopopxHaptics.notice(.error)
            return
        }
        invite = minted.uri
        // 与 `POPOPXLinkQRCode` 同一条 errorLevel 规则（QRCode.swift:44 `small: uri.count < 200`
        // → :105 `small ? "M" : "L"`），这样注入的那张位图和视图自己会画的完全是同一枚码。
        qrBitmap = await generateImage(minted.uri, tintColor: qrInk, errorLevel: minted.uri.count < 200 ? "M" : "L")
        PopopxHaptics.notice(.success)
    }

    private func loadProfile() async {
        let loaded = await store.loadEditable()
        saved = loaded
        if let loaded {
            sendMode = loaded.sendMode
            ttlSeconds = loaded.sendMode == .ephemeral
                ? (ProfileBuilderViewModel.ttlChoices.contains(loaded.ttlSeconds)
                    ? loaded.ttlSeconds
                    : ProfileBuilderViewModel.defaultEphemeralTTL)
                : ProfileBuilderViewModel.defaultEphemeralTTL
        }
        armedScene = ProfileAutoSender.shared.armedProfileScene
        isLoadingProfile = false
    }

    /// 名片卡的整张图。`fixedQRCode` 已经注入（:215），所以离屏渲染出来的是一张真码 ——
    /// 没有这一步，`makeScreenshot` 抓到的会是 `QRCode` 那格还没生成的空白（QRCode.swift:105 的
    /// `.task` 不在 UIHostingController 的这条绘制路径上跑）。
    private func cardImage() -> UIImage {
        passCard.makeScreenshot()
    }

    /// 分享的是整张名片卡的图（身份 + 模式 + 码），不是裸链接。`PopopxQRCardSheet.swift:196-198`
    /// 那一枚分享的是 uri 字符串，因为它整个界面就是一行链接；这里分享出去的东西如果转手一次就
    /// 认不出是谁的码，一枚匿名邀请链接在聊天工具里传开比一句话更糟。
    private func share() {
        guard let invite else {
            toast.show(Copy.noLinkToast, kind: .danger)
            return
        }
        // `makeScreenshot()` 不给尺寸时取的是 hosting controller 的 `intrinsicContentSize`
        // （QRCode.swift:131-:136）；那个值为 0 时交回来的是零尺寸的图，分享出去只剩一个空白附件。
        // 链接是同一枚码的另一种形态，拿它兜底不会让用户什么都发不出去。
        let card = cardImage()
        showShareSheet(items: card.size.width > 1 ? [card] : [invite])
    }

    /// 存相册用现网那一枚 `UIImageWriteToSavedPhotosAlbum`（ChatView.swift:2720 是本工程唯一的
    /// 先例，没有 PHPhotoLibrary 的请求路径）。权限文案 `NSPhotoLibraryAddUsageDescription`
    /// 已由 build setting 的 INFOPLIST_KEY_* 提供，本文件不动 Info.plist。
    private func saveToAlbum() {
        guard invite != nil else { return }
        let card = cardImage()
        guard card.size.width > 1 else {
            toast.show(Copy.blankCardToast, kind: .danger)
            return
        }
        UIImageWriteToSavedPhotosAlbum(card, nil, nil, nil)
        toast.show(Copy.savedToast, kind: .success)
        PopopxHaptics.notice(.success)
    }
}

// MARK: - 卡片自己的几何

/// pass 卡需要、而设计系统没有的那两格数字（照 `PopopxQRCardSheet.swift:209-218` 的 `Pass` 写法）。
private enum Pass {
    static let linkPreviewCharacters = 28
    /// 占位那一格与真码同高，铸链成功时卡片不会跳一下。
    static let qrPlaceholderHeight: CGFloat = 180

    /// 浅色淡得更远（尾部要读作深靛蓝边），深色淡得少（那里墨色接近黑，尾部得是亮的一端）。
    static func dimOpacity(for scheme: ColorScheme) -> Double {
        scheme == .light ? 0.55 : 0.70
    }
}

// MARK: - 文案

/// 卡上每一句中文只在这里出现一次（`PopopxQRCardSheet.swift:223-233` 那条 `private enum Copy` 规矩）。
private enum Copy {
    static let sheetTitle = "我的主页名片码"
    static let sheetSubtitle = "出示此码，对方扫码与你建连后自动收到你的加密主页"
    static let issuerOverline = "匿名身份"

    static let qrAccessibilityLabel = "主页名片二维码"
    static let qrNotReadyValue = "尚未生成"
    static let badgeAccessibility = "本张码将分发的主页模式"

    static let minting = "正在铸一次性连接链接…"
    static let retry = "重试"
    static let mintFailedNote = "链接没铸出来：请检查网络后点重试。"

    static let modeGroup = "这张码分发哪一档"
    static let standardNote = "常驻名片：好友接收后不设销毁时间，可随时打开查看图文与视频。"
    static let ephemeralNote = "打开后阅后即焚：有效期从好友点开那一下起计，到点后本机内容与原件一并销毁。"
    static let noSavedProfileNote = "本机还没有保存过的主页。现在武装好也不会推送任何内容，先去「我 → 加密个人主页」做好并保存。"

    static let armFootnote = "切换即武装：扫码建连之后由本机自动发出这一档，不需要你在聊天里再点一次。"
    static let armIdle = "当前没有武装自动推送。"
    static let armExpired = "武装已过期：切换一次模式或时长即可重新武装。"
    static let armActiveStandardFormat = "已武装：扫码建连后自动推送「%@」，约 %d 分钟内有效"
    static let armActiveEphemeralFormat = "已武装：扫码建连后自动推送「%@」，约 %d 分钟内有效，焚化时长 %@"
    static let armToast = "已武装本张码：对方扫码建连后自动推送这一档"
    static let cancelArmed = "取消自动推送"
    static let cancelArmedToast = "已取消扫码自动推送"

    static let securityNote = "该链接仅用于建立一次性加密连接，任何人得到它都可以向你发起连接（不要公开传播）。二维码里不含主页内容，内容只在建连之后作为一条消息发出。"

    static let close = "关闭"
    static let share = "分享"
    static let saveAlbum = "存相册"
    static let regen = "换新码"
    static let savedToast = "已存入相册（首次会请求写入权限）"
    static let noLinkToast = "链接还没铸好，暂时分享不了。"
    static let blankCardToast = "名片还没排好版，稍一下再存。"
}

// MARK: - Preview

#if DEBUG
struct ProfileQRCodeSheet_Previews: PreviewProvider {
    static var previews: some View {
        ProfileQRCodeSheet(identityName: "墨蓝信使")
    }
}
#endif
