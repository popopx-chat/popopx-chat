//
//  OnboardingStepsView.swift
//  POPOPX (iOS)
//
//  Created by Evgeny on 07/05/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//  Modifications Copyright © 2026 POPOPX Chat.
//
// Spec: spec/client/navigation.md

import SwiftUI

// Spec: spec/client/navigation.md#OnboardingView
struct OnboardingView: View {
    var onboarding: OnboardingStage

    var body: some View {
        NavigationStack {
            switch onboarding {
            case .step1_POPOPXInfo:
                POPOPXInfo(onboarding: true)
                    .modifier(ThemedBackground())
            case .step2_CreateProfile:
                CreateFirstProfile()
                    .modifier(ThemedBackground())
            case .step3_CreatePOPOPXAddress: // deprecated
                CreatePOPOPXAddress()
            case .step3_ChooseServerOperators,
                .step4_SetNotificationsMode: // deprecated
                YourNetworkView()
                    .navigationBarBackButtonHidden(true)
                    .modifier(ThemedBackground())
            case .step4_NetworkCommitments:
                OnboardingConditionsView(selectedOperatorIds: Set(ChatModel.shared.conditions.serverOperators.filter { $0.enabled }.map { $0.operatorId }))
                    .navigationBarBackButtonHidden(true)
                    .modifier(ThemedBackground())
            case .onboardingComplete: EmptyView()
            }
        }
    }
}

func onboardingButtonPlaceholder() -> some View {
    Spacer().frame(height: 40)
}

// Spec: spec/client/navigation.md#onboardingStage
enum OnboardingStage: String, Identifiable {
    case step1_POPOPXInfo
    case step2_CreateProfile
    case step3_CreatePOPOPXAddress // deprecated
    case step3_ChooseServerOperators
    case step4_SetNotificationsMode // deprecated
    case step4_NetworkCommitments
    case onboardingComplete

    public var id: Self { self }
}

// MARK: - 引导页共用文案（第一阶段录入的本地化 Key）

/// 四屏所有用户可见文案都在此解析：`PopopxButton` / `PopopxSectionCard` /
/// `PopopxToggleRow` 这些原子控件收的是 `String`，拿不到 `LocalizedStringKey`，
/// 所以 Key 在此查一次表，四个页面与阅读器共用同一份，绝不落裸 Key。
enum PopopxOnboardingCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX onboarding v2")
    }

    // 顶栏进度胶囊的阶段标签
    static let stageIdentity = key("Identity isolation")
    static let stageRouting = key("Routing & notifications")
    static let stageCommitments = key("Commitments & launch")

    // 第 1 屏 · 宣言页
    static let heroTitle = key("Own your network.")
    static let heroNote = key("Private messaging with no account and no user IDs.")
    static let pillSMP = key("SMP end-to-end encrypted")
    static let pillMesh = key("厢语 Bluetooth Mesh relay")
    static let givesYou = key("What POPOPX gives you")
    static let noUserIDsTitle = key("No user IDs")
    static let noUserIDsNote = key(
        "No phone number, no email, no global public key. Nothing links your contacts to each other, and each anonymous identity stays separate."
    )
    static let relaysTitle = key("Dynamic relays and near-field")
    static let relaysNote = key(
        "Online you use the dynamic SMP relay node cluster. Offline, 厢语 switches to a 1–7 hop Bluetooth Mesh and pairs face to face over UWB or a tap."
    )
    static let shieldTitle = key("Anti-peeping and local-only cards")
    static let shieldNote = key(
        "Screenshots and recordings are blocked, top-secret messages burn after reading, location stays encrypted in both modes, and your encrypted profile card never leaves this device."
    )
    static let trialBadgeNote = key("Complete this setup to receive the 3-Day Pioneer Node Trial Badge.")
    static let createIdentity = key("Create encrypted identity")
    static let restoreBackup = key("Restore from encrypted backup")

    // 第 2 屏 · 创建匿名身份
    static let identityTitle = key("Create your first anonymous identity")
    static let identityNote = key(
        "Identity, keys, POPOPX Compute Credits and your profile card are encrypted on this device only. Servers cannot see them."
    )
    static let profilePhoto = key("Profile photo")
    static let tapToChoosePhoto = key("Tap to choose a photo")
    static let newAvatar = key("New avatar")
    static let anonymousName = key("Anonymous name")
    static let anonymousNamePrompt = key("How you appear to contacts")
    static let noteForFriends = key("Note for friends")
    static let noteForFriendsPrompt = key("Optional full name, visible only to contacts you choose")
    static let nameRequired = key("Enter an anonymous name to continue.")
    static let nameInvalidHint = key("This name contains characters POPOPX cannot use.")
    static let privacyBoost = key("Privacy boost")
    static let incognitoRow = key("Incognito mode by default")
    static let incognitoNote = key(
        "Every new connection gets a fresh random nickname, so one name never links two chats."
    )
    static let next = key("Next")

    // 第 3 屏 · 双模路由与通知
    static let modesTitle = key("Choose how POPOPX connects and wakes")
    static let onlineChannel = key("Online encrypted channel")
    // 三档标题沿用 AppAPITypes.swift:1701 `NotificationsMode.label` 已有的 Key，不另立词条。
    static let modeInstant = key("Instant")
    static let modePeriodic = key("Periodic")
    static let modeNoPush = key("No push server")
    static let instantNote = key("Low latency · minor metadata exposure")
    static let periodicNote = key("Higher privacy · balanced battery")
    static let noPushNote = key("Maximum discretion · nothing pushed")
    /// 三档选中态的右侧微标：光靠一个小圆点在真机上读不出"这档已经选中"。
    static let modeSelected = key("Selected")
    static let pushFootnote = key(
        "Apple's push service carries only the signal that new data is waiting, never the content."
    )
    static let offlineMesh = key("厢语 offline mesh")
    static let offlineMeshNote = key(
        "When the internet is down, messages hop over nearby devices, up to 7 hops, with no server. Pair face to face with UWB or a tap."
    )
    static let bluetoothPermissionNote = key("Bluetooth permission is requested the first time the mesh starts.")
    static let relayNodes = key("Dynamic SMP relay nodes")
    /// 可用运营商只有 1 个（或还没有）时，"1 / 1" 的选择器会让人以为必须去选一个，
    /// 所以第 3 屏那张卡在这种数量下改成状态展示，详情弹层入口保留。
    static let relayReadyTitle = key("Default cluster is ready")
    static let relayAutoRouting = key("Automatic routing")
    // 「中继运营商」弹层：Key 全部沿用上游既有句子，只是改由本枚举解析，
    // 这样弹层里的每个字都和其他三屏走同一条本地化通道。
    static let operatorsTitle = key("Server operators")
    static let operatorsNote = key("You can configure servers via settings.")
    static let operatorsHowItHelps = key("How it helps privacy")
    static let operatorsAbout = key("About operators")
    static let operatorsOK = key("OK")
    static let back = key("Back")
    static let continueButton = key("Continue")

    // 第 4 屏 · 安全承诺、启动防护与法务
    static let commitmentsTitle = key("Security commitments and local protection")
    static let commitmentsCard = key("Network and security commitments")
    static let commitmentRelay = key(
        "Messages are relayed asynchronously by the dynamic SMP relay node cluster, and deleting them here is irreversible."
    )
    static let commitmentRouting = key(
        "Private routing is on by default to hide your real IP address. Finishing this setup grants the 3-Day Pioneer Node Trial Badge, which falls back to free public nodes when it expires and keeps every message."
    )
    static let commitmentWipe = key(
        "Tapping the logo three times triggers Panic Wipe, a physical erasure of the local database. Top-secret messages are shielded from screenshots and recording."
    )
    static let launchProtection = key("Launch protection")
    static let biometricRow = key("Face ID / Touch ID lock")
    static let biometricNote = key("POPOPX asks for biometrics before it opens. The database stays locked until then.")
    static let biometricUnavailable = key("Biometrics are not available on this device.")
    static let legalCard = key("Privacy policy and terms of use")
    static let privacyPolicy = key("POPOPX Privacy Policy")
    static let termsOfUse = key("POPOPX Terms of Use")
    static let legalReadableOffline = key("Read offline, any time")
    static let legalAgreement = key(
        "I have read and agree to the POPOPX Privacy Policy and the POPOPX Terms of Use."
    )
    /// 同意句的可链接版本：两个文档标题由 `%1$@` / `%2$@` 注入，行内热区取的就是
    /// `privacyPolicy` / `termsOfUse` 的译文，与阅读器标题逐字一致。
    /// 不能拿原句找子串切分：16 个译本里 bg cs fi hu pl ru uk 这 7 个给标题加了变格或
    /// 冠词，逐字包含不成立，链接会静默掉回纯文本；其余 9 个的译文就是照原句替换标题
    /// 生成的。`legalAgreement` 保留作无障碍标签。
    static let legalAgreementLinks = key("I have read and agree to %1$@ and %2$@.")
    static let readAndClose = key("I have read it")
    static let agreeAndEnter = key("Agree and enter POPOPX")
    static let commitmentsRequired = key("Confirm the three commitments above.")
    static let legalRequired = key("Agree to the privacy policy and terms of use to continue.")
    static let readyToast = key("Encrypted queue, Bluetooth Mesh and the privacy shield are ready.")
    static let badgeToast = key("The 3-Day Pioneer Node Trial Badge is active.")

    // 阅读器共用
    static let legalEffective = key("Effective: November 2026")
    static let legalPublished = key("The full published statement is at popopx.chat/privacy.")

    // 隐私政策正文
    static let privacySections: [(String, String)] = [
        (key("No account, no collection"), key(
            "POPOPX creates no accounts. Your profiles, contacts, groups, messages and settings exist only in the encrypted database on this device, and nothing here links who talks to whom."
        )),
        (key("Encrypted relay queues"), key(
            "Online messages travel through the dynamic SMP relay node cluster. Queues are encrypted end to end, so a relay node sees neither message content nor both ends of a conversation, and it keeps no history of delivered messages."
        )),
        (key("No analytics in this build"), key(
            "This build bundles no analytics or crash-reporting SDK and no telemetry collector. The status you see in the header describes the nodes your own device is talking to, not you."
        )),
        (key("Credentials stay on device"), key(
            "Identity keys, the POPOPX Compute Credits balance and privacy node badges are kept in this device's Keychain and local encrypted store. They are never uploaded, only you can move them, and a reinstall without a backup loses them."
        )),
        (key("Push token and replay protection"), key(
            "Push delivery uses an Apple device token bound to the notification mode you chose. The token carries no message content, is reissued when you change server or mode, and is used once so a captured token cannot be replayed."
        )),
        (key("The camera guard stays local"), key(
            "The anti-peeping guard switches the front camera on only while a top-secret sheet is open, at the lowest resolution, processes every frame on this device and stops the stream when the sheet closes. Nothing is written to disk and nothing is uploaded."
        )),
        (key("Screenshots, recordings and offline hops"), key(
            "Protected screens are blocked from screenshots and screen recording by the system itself. In 厢语 mode messages hop over Bluetooth between nearby devices and never reach the public internet."
        )),
        (key("Your controls"), key(
            "You can export or delete any identity, erase the local database or trigger Panic Wipe at any time. Deletion is irreversible because no server holds a copy."
        ))
    ]

    // 使用条款正文
    static let termsSections: [(String, String)] = [
        (key("Acceptable use"), key(
            "Use POPOPX within the laws of the country you are in. Public groups and 厢语 broadcasts must carry no unlawful content, no spam and no harassment of other users."
        )),
        (key("Your keys, your responsibility"), key(
            "Your mnemonic phrase, identity keys, badges and POPOPX Compute Credits exist only on this device. If the device or the phrase is lost, they cannot be recovered, frozen or reissued by anyone."
        )),
        (key("No guarantee of availability"), key(
            "Relay nodes, push queues and Bluetooth Mesh hops are provided as they are. Offline delivery depends on nearby devices being present and switched on, so it cannot be guaranteed."
        )),
        (key("Panic Wipe disclaimer"), key(
            "Tapping the logo three times erases local data irreversibly to protect you under coercion. Messages already waiting in a relay queue cannot be erased from this device and are not recovered for you."
        )),
        (key("Operator conditions"), key(
            "Relay operators set their own conditions for the servers they run. When an operator requires acceptance, the app shows that operator's conditions and records your acceptance before using them."
        )),
        (key("Names and changes"), key(
            "POPOPX and the POPOPX logo are the names of this build. These terms and the privacy statement may change; the app always shows the version you agreed to, and continuing to use POPOPX means you accept the change."
        ))
    ]
}

// MARK: - 引导页共用视觉原子

/// 0.5pt 极细分隔线。`PopopxControls` 里那个同名分隔线在 `#if DEBUG` 内且是 private，
///  Release 构建拿不到，所以引导页自带一条，颜色与描边宽度都取自色板 token。
struct PopopxOnboardingHairline: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.hairline)
            .padding(.vertical, PopopxMetrics.spaceXS)
            .accessibilityHidden(true)
    }
}

/// 行首的圆角彩色 SF Symbol 徽章：`PopopxIconBadge` 同样是 private 的，
/// 这里用公开的 `PopopxIconTint` 组合同一对 fill/ink，颜色不可能配错。
struct PopopxOnboardingIconBadge: View {
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

/// 行尾的状态微标（「已选」/「自动路由」）：淡 brand 底 + brand 字，
/// 只作视觉确认，朗读交给所在行本身，所以整枚对无障碍隐藏。
struct PopopxOnboardingChip: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(PopopxType.microTag)
            .foregroundStyle(PopopxPalette.brand)
            .padding(.horizontal, PopopxMetrics.space2XS)
            .padding(.vertical, PopopxMetrics.space2XS)
            .background(
                PopopxPalette.brand.opacity(0.14),
                in: .rect(cornerRadius: PopopxMetrics.radiusChip, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - 统一顶栏进度胶囊
/// 四屏共用的页头：`1 / 3` 计数 + 阶段标签胶囊、主副标题与三段进度轨。
/// 第 1 屏（宣言页）不带它，那里是 Logo 光晕的构图。
struct PopopxOnboardingHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let step: Int
    let steps: Int
    let stage: String
    let title: String
    let note: String?

    init(step: Int, steps: Int, stage: String, title: String, note: String? = nil) {
        self.step = step
        self.steps = steps
        self.stage = stage
        self.title = title
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                Text(verbatim: "\(step) / \(steps)")
                    .font(PopopxType.metricSmall)
                    .foregroundStyle(PopopxPalette.brand)
                Rectangle()
                    .fill(PopopxPalette.separator)
                    .frame(width: PopopxMetrics.hairline, height: PopopxMetrics.spaceS)
                Text(stage)
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .lineLimit(1)
            }
            .padding(.vertical, PopopxMetrics.space2XS)
            .padding(.horizontal, PopopxMetrics.spaceXS)
            .background(PopopxMaterial.chip, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusChip)
                    .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            )

            Text(title)
                .font(PopopxType.title)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)

            if let note {
                Text(note)
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            track
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var track: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            ForEach(0..<steps, id: \.self) { index in
                Capsule()
                    .fill(index < step ? PopopxPalette.brand : PopopxPalette.separator)
                    .frame(height: PopopxMetrics.space2XS)
            }
        }
        .popopxAnimation(PopopxSpring.fluid, value: step, reduceMotion: reduceMotion)
        .accessibilityHidden(true)
    }
}

// MARK: - 隐私政策 / 使用条款离线阅读器

/// 第 4 屏的内置法律文书：正文全部来自 `PopopxOnboardingCopy`，不联网、不加载
/// `popopx.chat/privacy`，那句话只是告诉用户完整对外文本的所在。
struct PopopxLegalDocumentSheet: View {
    enum Document: Identifiable, Hashable {
        case privacy, terms

        var id: Self { self }

        var title: String {
            self == .privacy ? PopopxOnboardingCopy.privacyPolicy : PopopxOnboardingCopy.termsOfUse
        }

        var sections: [(String, String)] {
            self == .privacy ? PopopxOnboardingCopy.privacySections : PopopxOnboardingCopy.termsSections
        }
    }

    @Environment(\.dismiss) private var dismiss

    let document: Document

    var body: some View {
        PopopxSheetContainer(document.title, subtitle: PopopxOnboardingCopy.legalEffective) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                        Text(section.0)
                            .font(PopopxType.sectionHeader)
                            .foregroundStyle(PopopxPalette.label)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(section.1)
                            .font(PopopxType.body)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                PopopxOnboardingHairline()

                Text(PopopxOnboardingCopy.legalPublished)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            PopopxButton(PopopxOnboardingCopy.readAndClose, systemImage: "checkmark", role: .secondary) {
                dismiss()
            }
            .padding(PopopxMetrics.spaceM)
        }
        .presentationDragIndicator(.visible)
    }
}

struct OnboardingStepsView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(onboarding: .step1_POPOPXInfo)
    }
}
