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

// MARK: - Brand claim (locale-free by design)

/// The core claim is the one line that is deliberately **not** a localization key: every POPOPX portal renders the same
/// English sentence in every locale (a translated slogan stops being the slogan), and views take it through
/// `Text(verbatim:)` so no catalog can drift away from the portals. The four layers are specified in README.md.
/// It lives here rather than in its own file because the app target lists sources explicitly in `project.pbxproj`.
enum PopopxBrandCopy {
    static let claim = "Connect Everything."
}

// MARK: - Shared onboarding copy (the localization Keys entered in the first phase)

/// All user-visible copy of the four screens resolves here: the atomic controls such as `PopopxButton` / `PopopxSectionCard` /
/// `PopopxToggleRow` take a `String` and cannot get a `LocalizedStringKey`,
/// so each Key is looked up once here and the four pages and the reader share that same copy; a bare Key never escapes.
enum PopopxOnboardingCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX onboarding v2")
    }

    // Stage labels of the top-bar progress capsule
    static let stageIdentity = key("Identity isolation")
    static let stageRouting = key("Routing & notifications")
    static let stageCommitments = key("Commitments & launch")

    // Screen 1 · manifesto page
    static let heroTitle = key("Own your network.")
    static let heroNote = key("Private messaging with no account and no user IDs.")
    static let pillSMP = key("SMP end-to-end encrypted")
    static let pillMesh = key("Cabin Bluetooth Mesh relay")
    static let givesYou = key("What POPOPX gives you")
    static let brandPositioning = key("Privacy-First Intelligent Connection Platform")
    static let brandSlogan = key("Connect Freely · Communicate Privately · Collaborate Intelligently")
    static let brandMission = key(
        "POPOPX does not merely provide connection tools — it builds an open ecosystem where people, AI, agents, devices, and services connect securely and collaborate freely."
    )
    static let noUserIDsTitle = key("No user IDs")
    static let noUserIDsNote = key(
        "No phone number, no email, no global public key. Nothing links your contacts to each other, and each anonymous identity stays separate."
    )
    static let relaysTitle = key("Dynamic relays and near-field")
    static let relaysNote = key(
        "Online you use the dynamic SMP relay node cluster. Offline, Cabin switches to a 1–7 hop Bluetooth Mesh and pairs face to face over UWB or a tap."
    )
    static let shieldTitle = key("Anti-peeping and local-only cards")
    static let shieldNote = key(
        "Screenshots and recordings are blocked, top-secret messages burn after reading, location stays encrypted in both modes, and your encrypted profile card never leaves this device."
    )
    static let trialBadgeNote = key("Complete this setup to receive the 3-Day Pioneer Node Trial Badge.")
    static let createIdentity = key("Create encrypted identity")
    static let restoreBackup = key("Restore from encrypted backup")

    // Screen 2 · create the anonymous identity
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

    // Screen 3 · dual-mode routing and notifications
    static let modesTitle = key("Choose how POPOPX connects and wakes")
    static let onlineChannel = key("Online encrypted channel")
    // The three tier titles reuse the Keys already in AppAPITypes.swift:1701 `NotificationsMode.label`; no separate entries are created.
    static let modeInstant = key("Instant")
    static let modePeriodic = key("Periodic")
    static let modeNoPush = key("No push server")
    static let instantNote = key("Low latency · minor metadata exposure")
    static let periodicNote = key("Higher privacy · balanced battery")
    static let noPushNote = key("Maximum discretion · nothing pushed")
    /// The trailing chip for a tier's selected state: a small dot alone does not read as "this tier is selected" on a real device.
    static let modeSelected = key("Selected")
    static let pushFootnote = key(
        "Apple's push service carries only the signal that new data is waiting, never the content."
    )
    static let offlineMesh = key("Cabin offline mesh")
    static let offlineMeshNote = key(
        "When the internet is down, messages hop over nearby devices, up to 7 hops, with no server. Pair face to face with UWB or a tap."
    )
    static let bluetoothPermissionNote = key("Bluetooth permission is requested the first time the mesh starts.")
    static let relayNodes = key("Dynamic SMP relay nodes")
    /// When there is only 1 available operator (or none yet), a "1 / 1" picker makes people think they must go and choose one,
    /// so at that count the card on screen 3 turns into a status display while the entry to the detail sheet is kept.
    static let relayReadyTitle = key("Default cluster is ready")
    static let relayAutoRouting = key("Automatic routing")
    // The "relay operator" sheet: its Keys all reuse existing upstream sentences and are only resolved by this enum now,
    // so every word in the sheet goes through the same localization channel as the other three screens.
    static let operatorsTitle = key("Server operators")
    static let operatorsNote = key("You can configure servers via settings.")
    static let operatorsHowItHelps = key("How it helps privacy")
    static let operatorsAbout = key("About operators")
    static let operatorsOK = key("OK")
    static let back = key("Back")
    static let continueButton = key("Continue")

    // Screen 4 · security promises, launch protection and legal
    static let commitmentsTitle = key("Security commitments and local protection")
    static let commitmentsCard = key("Network and security commitments")
    // The three promises must each take one row on 393×852: the original sentence crammed three clauses into one, which needs more than 3 rows in any language,
    // so screen 4 would inevitably require scrolling. Only the actionable core assertions stay here; the full statement is still carried by the offline reader's body text
    // (the English sentence is the Key, so the matching lines in the 16 language directories are whole-line rewrites, not additions).
    static let commitmentRelay = key("Asynchronous SMP relaying; POPOPX has no cloud account backup; keep your local encrypted backup safe — deleting or wiping is irreversible.")
    static let commitmentRouting = key("Private routing hides your IP; finishing grants the 3-day trial badge.")
    static let commitmentWipe = key("Three taps on the logo erase local data; screenshots are blocked.")
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
    /// The linkable version of the agreement sentence: the two document titles are injected via `%1$@` / `%2$@`, and the inline hot spots use exactly
    /// the translations of `privacyPolicy` / `termsOfUse`, verbatim identical to the reader's titles.
    /// The original sentence cannot be split by substring search: of the 16 translations, the 7 in bg cs fi hu pl ru uk add case inflection or
    /// articles, so verbatim containment fails and the link silently drops back to plain text; the remaining 9 translations were built by replacing the titles into
    /// the original sentence. `legalAgreement` is kept as the accessibility label.
    static let legalAgreementLinks = key("I have read and agree to %1$@ and %2$@.")
    static let readAndClose = key("I have read it")
    static let agreeAndEnter = key("Agree and enter POPOPX")
    static let commitmentsRequired = key("Confirm the three commitments above.")
    static let legalRequired = key("Agree to the privacy policy and terms of use to continue.")
    static let readyToast = key("Encrypted queue, Bluetooth Mesh and the privacy shield are ready.")
    static let badgeToast = key("The 3-Day Pioneer Node Trial Badge is active.")

    // Shared by the reader
    static let legalEffective = key("Effective: November 2026")
    static let legalPublished = key("The full published statement is at popopx.chat/privacy.")

    // Privacy policy body text
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
            "Protected screens are blocked from screenshots and screen recording by the system itself. In Cabin mode messages hop over Bluetooth between nearby devices and never reach the public internet."
        )),
        (key("Your controls"), key(
            "You can export or delete any identity, erase the local database or trigger Panic Wipe at any time. Deletion is irreversible because no server holds a copy."
        ))
    ]

    // Terms of use body text
    static let termsSections: [(String, String)] = [
        (key("Acceptable use"), key(
            "Use POPOPX within the laws of the country you are in. Public groups and Cabin broadcasts must carry no unlawful content, no spam and no harassment of other users."
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

// MARK: - Shared onboarding visual atoms

/// A 0.5pt hairline divider. The identically named divider in `PopopxControls` sits inside `#if DEBUG` and is private,
///  so a Release build cannot reach it; onboarding therefore ships its own, with colour and stroke width both taken from the palette tokens.
struct PopopxOnboardingHairline: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.hairline)
            .padding(.vertical, PopopxMetrics.spaceXS)
            .accessibilityHidden(true)
    }
}

/// The rounded coloured SF Symbol badge at the head of a row: `PopopxIconBadge` is private as well,
/// so this uses the public `PopopxIconTint` to combine the same pair of fill/ink, which makes a colour mismatch impossible.
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

/// The trailing status chip ("Selected" / "Automatic routing"): light brand background + brand text,
/// a visual confirmation only; the reading is left to the row it sits in, so the whole chip is hidden from accessibility.
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

// MARK: - Unified top-bar progress capsule
/// The page header shared by the four screens: a `1 / 3` counter + stage label capsule, main and sub title, and a three-segment progress track.
/// Screen 1 (the manifesto page) does not carry it; there the composition is the Logo glow.
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
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
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

// MARK: - Privacy policy / terms of use offline reader

/// The built-in legal documents of screen 4: the body text comes entirely from `PopopxOnboardingCopy`, with no network access and nothing loaded from
/// `popopx.chat/privacy`; that sentence only tells the user where the full outward-facing text lives.
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
