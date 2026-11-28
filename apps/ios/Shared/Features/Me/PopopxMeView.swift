//
//  PopopxMeView.swift
//  POPOPX (iOS)
//
//  [Phase 4] Tab 4 "Me". A WeChat-style information architecture: one personal card header at the top, then four card groups
//  assets and node entitlements / encrypted home page and card wallet / frequently used / privacy and security defences (2026-11-20 refactor ruling).
//
//  Five structural decisions:
//
//  1. The page does not place its own NavigationStack — the stack is wrapped centrally by Shared/Navigation/MainTabView.swift:152-171,
//     and the `navigationDestination` for those three "relay and server" values is registered in that layer too (value links get hoisted to the stack root,
//     so writing it on "All settings" itself has not one line of effect).
//     Here we only push existing pages outward (`NavigationLink { page }`, the same style as SettingsView.swift:405-424).
//  2. Every row pushes to a page that really exists and whose init and environment dependencies were checked one by one — no placeholder rows, no TODO.
//     `UserProfile` depends on `SaveableSettings` (see the PopopxProfileHost comment), so it is wrapped one layer following the app's existing
//     mounting style before injecting, to avoid a missing EnvironmentObject.
//  3. This page keeps only the triple-tap emergency wipe, which has nothing to do with Bluetooth. The offline-mesh master switch, the real verification block and the pairing policy all used to sit on this fourth card,
//     and on 2026-11-20 the whole block moved to the settings center at the top-right of the Cabin page (`PopopxCabinMeshSettingsSheet`,
//     `Shared/Features/Cabin/PopopxCabinView.swift`); the migration is equivalent item by item, and all four landing points still go through
//     `PopopxMeshRuntime.shared` to write back into the package's only kill switch / store / binding table, so this page keeps no second set of state.
//     The emergency wipe stays here: what it wipes is exactly that whole set, and it only feeds taps into the existing arming state machine, while the confirmation sheet is still presented by the gate
//     already mounted for the whole app — this page does not write a second alert.
//  4. This rearrangement only moved "which card a row lives in" and deleted not one existing route: identity management and the home-page card QR were promoted from rows into
//     a whole hot area of the card header plus a QR micro-badge, and all other rows land in the four groups above. "Top up compute credits" is still an unconditional
//     entry (the reason is in the `badgeSheet` comment below). The two rows deleted on 2026-11-20 each went somewhere: "Add friends" —
//     the same `PopopxAddFriendView` hangs on the "+" at the top-right of the message tab (ChatsListView.swift:296-298); the "Offline mesh"
//     row — the Cabin page's settings center, see decision 3.
//     Real-device walkthrough three.1/three.4 also moved the frequently-used group: the "Notifications" and "Version" rows were deleted and each went somewhere (All settings → Notifications,
//     and the version page inside `PopopxHelpView`); the "Appearance & icon", "Display language" and "Help & about" rows were lifted up from the
//     "All settings" second-level page. Still only "which card a row lives in" moved, not one destination was newly invented, and no second entry was left behind.
//  5. The badge row's three exits do not establish their own criterion: it switches on the shared enum `phase.capsuleState` itself,
//     and reads the same state and the same branches as the top bar entry `PopopxBadgeHeaderEntry` (`PopopxBadgeSheet.entry(for:)`),
//     so a future extra tier fails to compile here instead of two places each telling their own story.
//
//  Colors, font sizes, corner radii and spacing all take tokens from Shared/Theme/PopopxTheme.swift; controls use only
//  the existing atomic library in Shared/Components, with no new button, switch or text field invented (`PopopxIconBadge` is
//  private inside the atomic library, and every helper this page needs is cohesive inside this one file). All copy is the English original sentence as the Key,
//  new entries are written into the 16 translation directories, and `en.lproj` gets no redundant entry (the Key it reads is already English).
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand — the iron rule forbids scripts from modifying project.pbxproj.
//

import SwiftUI
import UIKit
import Foundation
import POPOPXChat
import PopopxMeshKit
import PopopxMeshUI

// MARK: - The page

@MainActor
struct PopopxMeView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The single state source for the fuse, pairing policy and wipe is this coordinator on the app side (the same pattern as SettingsView.swift:627).
    @ObservedObject private var meshRuntime = PopopxMeshRuntime.shared

    /// The emergency wipe's arming state machine itself: this page only feeds taps into it, and the confirmation is raised by the existing gate.
    @ObservedObject private var panicWipe: PopopxPanicWipeManager
    @ObservedObject private var panicArming: PopopxPanicWipeArming

    /// The compute-credits ledger: an `@Observable` singleton, and this page reads only one balance value to serve as the entry row's subtitle.
    @State private var credits = PopopxCreditsManager.shared

    @State private var toast = PopopxToastModel()
    /// The switch for the "Home card QR" sheet. The entry is the QR micro-badge at the right end of the card header (ruling 4: it no longer occupies a row of its own).
    @State private var showsProfileQR = false
    /// The three panels of the compute-credits ecosystem. Badge **details** and **upgrade** now also have a row on this page (WeChat-style grouping requires assets
    /// to be reachable directly), but it carries no criterion of its own — see structural decision 5 above and `routeBadge()` below.
    @State private var showsCreditsStore = false
    @State private var showsRedeemCode = false
    @State private var showsGiftCard = false
    /// The paywall must have a second switch here even though the capsule already attaches it: the capsule dispatches by state,
    /// and the `.activeLit` tier hands the tap to the badge details, so **people already lit have nowhere left to buy credits**.
    /// And the compute-credits center page does not attach a paywall, per its own file header. So this row is the only unconditional entry.
    ///
    /// The three exits (paywall / trial explanation / details) are collected into one `PopopxBadgeSheet?`, sharing the top bar capsule's
    /// carrier (`PopopxBadgeSheetHost`): this used to be three parallel `.sheet(isPresented:)`,
    /// and tapping "see badge details" from the trial modal had to raise another sheet inside the sheet, which the system simply dropped — on a real device that is "tapping did nothing".
    @State private var badgeSheet: PopopxBadgeSheet?
    /// The "add a new identity" shortcut entry at the bottom-right of the card: it goes by push (this page is inside `NavigationStack(path:)`,
    /// `MainTabView.swift:152`), not a sheet — the same pattern as the one at `UserProfilesView.swift:112-114`.
    @State private var showsCreateIdentity = false
    /// The badge runtime: an `@Observable` singleton, reading the same `phase` as the top bar capsule and the badge details, so this page keeps no second set of state.
    @State private var badge = PopopxBadgeManager.shared
    /// The number of gift vouchers unused on this device. `PopopxP2PVoucherVault` is an actor and can only be awaited inside `.task`,
    /// never asked synchronously in the body; if the read fails it stays 0, so this row never pretends there "are vouchers".
    @State private var unusedVouchers = 0
    /// The current tier of this device's encrypted personal home page, shaped like "configured · resident card"; `nil` = not read yet (no fake state on the first frame).
    @State private var profileStatusValue: String?

    /// The identity number currently being switched to; nil = no switch is running right now. While switching, a second tap is not accepted, otherwise two
    /// `setActiveUser` calls would race for `ChatModel.currentUser`.
    @State private var busyUserID: Int64?

    /// The two switches merged into this defence card by device round 6 two.2. The keys are exactly the same batch as the settings page's original two bindings and as
    /// `PrivacySettings.swift:27`/`:18` (not copies): the masking one is still what
    /// `AppSettings.swift:45`, `:86` read when exporting and restoring configuration, and the tracking-removal one is read by
    /// `ComposeView.swift:636` before sending a message. Changing the host does not change the data.
    @AppStorage(DEFAULT_PRIVACY_PROTECT_SCREEN) private var protectScreen = false
    @AppStorage(GROUP_DEFAULT_PRIVACY_SANITIZE_LINKS, store: groupDefaults) private var sanitizeLinks = false

    @MainActor init() {
        let runtime = PopopxMeshRuntime.shared
        _panicWipe = ObservedObject(wrappedValue: runtime.panicWipe)
        _panicArming = ObservedObject(wrappedValue: runtime.panicWipe.arming)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                nameCard
                assetEntries
                spaceEntries
                generalEntries
                securityEntries
                helpEntries
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // After the title bar was closed off, the first row of this page is the card itself. The whitespace is now given by the content: the top inset rises from 8 to 24
            // (`spaceL`), so between the card and the status bar there is a deliberate stretch of breathing room rather than the gap left by a missing row.
            .padding(.top, PopopxMetrics.spaceL)
            .padding(.bottom, PopopxMetrics.space2XL)
            // After switching or creating an identity the whole group of cards rearranges. Under Reduce Motion it lands directly, with no spring.
            .popopxAnimation(PopopxSpring.fluid, value: chatModel.currentUser?.userId, reduceMotion: reduceMotion)
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.pageTitle)
        // The large "Me" title row no longer occupies the first screen (device round 6 additional item, WeChat-style whitespace): the system title bar is hidden entirely,
        // and the title itself is still declared, so VoiceOver can announce what this page is called — it simply no longer draws a row.
        // The wording follows the message page `ChatsListView.swift:256`: the hiding applies only to this page of the stack, and second-level pages declare themselves visible —
        // every row link passes through `PopopxMeRowLink`, which adds one `.toolbar(.visible, for: .navigationBar)` there
        // covering every page it pushes; the `showsCreateIdentity` hop has its own separate one (below :152).
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsProfileQR) {
            // The detents belong to the caller (the convention at `ProfileQRCodeSheet.swift:19`). This card's content is
            // card + mode picker + action rows, much taller than the location card in chat, and 0.8 is the tier at which, sharing the screen with `nameCard`,
            // it does not squeeze out its own action rows.
            ProfileQRCodeSheet(identityName: chatModel.currentUser?.displayName ?? Copy.profileQRIdentityFallback)
                .presentationDetents([.fraction(0.8)])
        }
        // The second entry of the compute-credits ecosystem. The detents likewise belong to the caller (the convention above): the purchase page's sheet must hold a seven-tier price table,
        // and giving it `.medium` would make it scroll inside its own table; the redemption code is the shortest, so the middle tier is enough.
        .sheet(isPresented: $showsCreditsStore) {
            PopopxCreditsStoreView()
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showsRedeemCode) {
            PopopxVoucherRedeemSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsGiftCard) {
            PopopxGiftBadgeCardSheet()
                .presentationDetents([.large])
        }
        // The badge's three exits (paywall / trial explanation / details) go through the top bar capsule's one carrier, and the detents belong to the carrier.
        // The paywall and the compute-credits center remain two parallel Sheets, not nesting: the compute-credits center row opens independently (above
        // `showsCreditsStore`), and when the paywall is open it attaches the "compute-credits center" layer itself.
        // （`PopopxBadgePaywallView.swift:247`）。
        .popopxBadgeSheets($badgeSheet)
        // The destination page of the "add a new identity" shortcut: `CreateProfile` carries its own title and themed background
        // (`Shared/Views/Onboarding/CreateProfile.swift:121`, `:122`), so nothing is decorated twice here;
        // it only reclaims on itself the title bar the home page hid — this hop does not go through `PopopxMeRowLink`,
        // so visibility has to be declared separately, otherwise you push into a creation form with no back button.
        .navigationDestination(isPresented: $showsCreateIdentity) {
            CreateProfile()
                .toolbar(.visible, for: .navigationBar)
        }
        .onChange(of: showsProfileQR) { _, opened in
            // Closing the card QR re-reads the tier once: the mode switch inside that sheet changes this device's arming record,
            // and the slot on the entry row must state the tier that is true right now.
            if !opened { Task { await refreshProfileStatus() } }
        }
        // The card-wallet row says "how many are still usable right now", so both sheets that move vouchers trigger a re-read as soon as they close:
        // redemption writes a voucher as used and transfer hands a voucher to the peer; neither calls back into this page, so the only option is to ask the vault again.
        .onChange(of: showsRedeemCode) { _, opened in
            if !opened { Task { await refreshVoucherCount() } }
        }
        .onChange(of: showsGiftCard) { _, opened in
            if !opened { Task { await refreshVoucherCount() } }
        }
        .popopxToast(toast)
        // The initial value of the entry row's slot: read once on entering this page, and again after switching identity. If the read fails it is "not created yet",
        // and that sentence must be read rather than guessed — `ProfileStorageManager.loadEditable()` returning nil
        // is the only evidence that can support saying "not configured".
        .task(id: chatModel.currentUser?.userId) {
            await refreshProfileStatus()
        }
        // Vouchers are things inside this device's keychain, unrelated to which identity is active, so the read is bound only once to "having entered this page".
        .task {
            await refreshVoucherCount()
        }
    }

    // MARK: The top personal card header

    @ViewBuilder private var nameCard: some View {
        if let user = chatModel.currentUser {
            PopopxIdentityCard(
                user: user,
                phase: badge.phase,
                others: switchableOthers(of: user),
                lockedCount: lockedCount,
                busyUserID: busyUserID,
                onSwitch: { info in switchIdentity(to: info) },
                onCopyUserID: { copyUserID(user.userId) },
                onShowProfileQR: {
                    PopopxHaptics.impact(.light)
                    showsProfileQR = true
                },
                onAddIdentity: { showsCreateIdentity = true }
            )
        } else {
            emptyIdentityCard
        }
    }

    /// The genuinely empty state: without `currentUser` it does not display a fake card, it only explains what an identity is and offers an existing creation page.
    private var emptyIdentityCard: some View {
        PopopxSectionCard(footnote: Copy.emptyFootnote) {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
                PopopxMeAvatar(image: nil, side: PopopxMetrics.space2XL)
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(Copy.emptyTitle)
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                    Text(Copy.emptyNote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PopopxMeDivider()
            PopopxMeRowLink(Copy.createIdentity, systemImage: "person.crop.circle.badge.plus", tint: .brand) {
                CreateProfile()
            }
        }
    }

    /// The tier read into the entry row's slot. Its precedence matches this home page's actual sending behaviour:
    /// **the arming record left by the card QR outranks the saved home page** — scan-to-auto-push uses exactly that tier,
    ///（`ProfileAutoSender.handleContactConnected(contactId:)`，ProfileAutoSender.swift:241），
    /// so the label says that, rather than a tier that would not be sent this time.
    /// Only the copy **still within its validity window** counts: once `armingWindowSeconds` passes it can no longer be pushed (ProfileAutoSender.swift:161 that slot gets cleared),
    /// and showing an expired one as a tier would only make people go and turn off a switch that no longer exists.
    private func refreshProfileStatus() async {
        let armed = ProfileAutoSender.shared.armedProfileScene
        if let armed, armed.expiresAt > Date() {
            profileStatusValue = "\(Copy.profileConfigured) · \(profileModeLabel(armed.mode))"
            return
        }
        guard let manifest = await ProfileStorageManager.shared.loadEditable() else {
            profileStatusValue = Copy.profileUnconfigured
            return
        }
        profileStatusValue = "\(Copy.profileConfigured) · \(profileModeLabel(manifest.sendMode))"
    }

    /// How the tier is worded belongs to this page: `PersonalProfileModel.cardLabel` was a Chinese constant outside the 16 catalogs, so this page maps the same
    /// `mode` itself through `Copy`; cardLabel now reads those same two keys, so the two places cannot word one tier differently.
    private func profileModeLabel(_ mode: PopopxProfileSendMode) -> String {
        switch mode {
        case .ephemeral: return Copy.profileModeEphemeral
        case .standard: return Copy.profileModeStandard
        }
    }

    // MARK: Group 1 · assets and node entitlements

    private var assetEntries: some View {
        PopopxSectionCard(Copy.groupAssets, footnote: Copy.commerceFootnote) {
            PopopxPickerRow(Copy.creditsWallet, value: creditsBalanceTitle,
                            systemImage: "wallet.pass.fill", tint: .brand) {
                PopopxHaptics.selection()
                showsCreditsStore = true
            }
            PopopxMeDivider()
            PopopxPickerRow(Copy.badgeRow, value: badgeRowValue,
                            systemImage: "checkmark.shield.fill", tint: badge.phase.isLit ? .success : .neutral) {
                PopopxHaptics.selection()
                routeBadge()
            }
            .accessibilityIdentifier("popopx.me.badge")
            // The capsule that reaches the purchase page directly in one step. Why it is not merged into the row above: `PopopxPickerRow` has no trailing slot
            // (the shared atomic library is a red-line file, and the icon base inside it, `PopopxIconBadge`, is still file-private,
            // `PopopxControls.swift:315`), so assembling a row by hand means redrawing an atom, which shows as soon as a title stretches across 16 languages.
            // So it hugs the same card, right-aligned as its own row, and uses `PopopxButton(fullWidth: false)` to get
            // the ready-made brand background and 44pt hit area. In the dormant state this one goes where the whole row goes (both into the purchase page),
            // the only difference being you need not first guess that "the whole row is tappable".
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                PopopxButton(badgeActionTitle, role: .primary, fullWidth: false) {
                    badgeSheet = .paywall
                }
            }
            .padding(.top, PopopxMetrics.spaceS)
            PopopxMeDivider()
            // An unconditional entry: this is the only row on the whole page that can open a panel without looking at the badge state, for the reason see `badgeSheet` above.
            // After the device round 8 page split it opens the **compute-credits center**, no longer the paywall — this row's source text is
            // "Top up Compute Credits", and after the product flow was split, still sending it to the screen that sells badges is exactly the confusion this round fixes.
            PopopxPickerRow(Copy.purchaseCredits, systemImage: "cart.fill", tint: .brand) {
                PopopxHaptics.selection()
                showsCreditsStore = true
            }
            .accessibilityIdentifier("popopx.me.paywall")
        }
    }

    /// The badge slot tells the truth for all three tiers: dormant does not write "0 days", and trial and formal do not share the word "remaining" (wording same as
    /// `PopopxBadgeCopy.remaining`). Day counts always round up; with one minute left you cannot say "0 days".
    private var badgeRowValue: String {
        switch badge.phase {
        case .dormant:
            return Copy.badgeDormant
        case let .trial(expiresAt):
            return String(format: Copy.badgeTrialFormat, badgeDaysLeft(expiresAt))
        case let .active(_, expiresAt):
            return String(format: Copy.badgeRunningFormat, badgeDaysLeft(expiresAt))
        }
    }

    private func badgeDaysLeft(_ expiresAt: Date) -> Int {
        max(1, Int(ceil(max(0, expiresAt.timeIntervalSinceNow) / 86_400)))
    }

    /// Only the formally lit tier deserves "renew": during the trial and while dormant charging has not begun, so saying "renew" to them is inventing
    /// a subscription that does not exist. The criterion is the shared enum `capsuleState`, the same one as `routeBadge()` — it cannot use
    /// `isLit`, which also counts the trial period as "lit" (`PopopxBadgeCreditsModels.swift:262`).
    private var badgeActionTitle: String {
        switch badge.phase.capsuleState {
        case .activeLit: Copy.badgeRenew
        case .trialPulsing, .dormant: Copy.badgeBuy
        }
    }

    /// The criterion is `PopopxBadgeSheet.entry(for:)` alone, and the top bar capsule goes through it too: three states → three exits are closed off here,
    /// and if the capsule gains a tier later, changing that function makes this fail to compile instead of two places each telling their own story.
    private func routeBadge() {
        badgeSheet = PopopxBadgeSheet.entry(for: badge.phase.capsuleState)
    }

    // MARK: Group 2 · encrypted home page and card wallet

    private var spaceEntries: some View {
        PopopxSectionCard(Copy.groupSpace) {
            // The encrypted personal home page: the builder is pushed with a `NavigationLink`, not a Sheet — it does not carry its own navigation container
            // (the convention of the layer at `ProfileBuilderView.swift:434`), so pushing it gets the ready-made back button for free.
            // The `value` slot is this machine's current home-page tier; reading the disk is an actor hop, so it lives in `.task`
            // and is not read synchronously in the body, otherwise every rearrangement of these cards would ask the disk once.
            PopopxMeRowLink(Copy.personalProfile, value: profileStatusValue, systemImage: "person.text.rectangle.fill", tint: .brand) {
                ProfileBuilderView()
                    .navigationTitle(Copy.personalProfile)
            }
            PopopxMeDivider()
            PopopxMeRowLink(Copy.myProfile, systemImage: "person.text.rectangle", tint: .brand) {
                PopopxProfileHost()
            }
            PopopxMeDivider()
            giftVaultRow
        }
    }

    /// The card-wallet row is a `Menu`, not a page: the repository has no "card wallet browsing page" view,
    /// only the transfer and redemption sheets, so this row merges the two actions into one long-press-style choice
    /// instead of inventing a fourth page that merely lists the local vouchers. The row body is still drawn by `PopopxPickerRow`,
    /// but its own `Button` would swallow the menu's tap, so the whole row is made unhittable and handed to the outer `Menu`.
    private var giftVaultRow: some View {
        Menu {
            Button(Copy.giftSend) {
                PopopxHaptics.selection()
                showsGiftCard = true
            }
            Button(Copy.redeemCode) {
                PopopxHaptics.selection()
                showsRedeemCode = true
            }
        } label: {
            PopopxPickerRow(Copy.giftVault, value: voucherValueTitle,
                            systemImage: "giftcard.fill", tint: .neutral) { }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(Text(verbatim: Copy.giftVault))
        .accessibilityValue(Text(verbatim: voucherValueTitle ?? ""))
        .accessibilityHint(Text(verbatim: Copy.giftMenuHint))
        .accessibilityIdentifier("popopx.me.giftVault")
    }

    /// With not a single slot, no number is shown: an empty wallet saying "0 available" would make people think some concept of "cards" in the system is waiting to be filled up.
    private var voucherValueTitle: String? {
        unusedVouchers > 0 ? String(format: Copy.vouchersAvailableFormat, unusedVouchers) : nil
    }

    @MainActor private func refreshVoucherCount() async {
        // Badge cards only, and the reason is the menu above: this row's two actions are "send a gift badge" and "enter a code",
        // so a number here has to mean the cards that row can actually act on. Compute-credit gift cards are inventoried on the
        // Compute Credits page, which is the only place that can send one.
        unusedVouchers = await PopopxP2PVoucherVault.shared.badgeVouchers(state: .unused).count
    }

    // MARK: Group 3 · frequently used

    private var generalEntries: some View {
        PopopxSectionCard(Copy.groupGeneral) {
            // The "Add friends" row used to be here; deleted on 2026-11-20: the "+" at the top-right of the message tab already hangs the same
            // `PopopxAddFriendView` (ChatsListView.swift:296-298), and the same thing should not have an entry in two places.
            // Device round 6 two.1: chat preferences, appearance & icon and display language fall back into "All settings", while help & about
            // was promoted into the page's last card (`helpEntries` below). This group therefore has only one job left — entering All settings.
            // The three rows' destinations and decoration (`PreferencesView`/`AppearanceSettings`/`PopopxDisplayLanguageView`
            // plus their own `.navigationTitle` and `ThemedBackground`) moved exactly as they were, not one parameter changed,
            // and the two values at the row ends went back into the same file as their original supplier `PopopxSettingsValues`.
            PopopxMeRowLink(Copy.settings, systemImage: "gearshape.fill") {
                PopopxPresenceGated(reason: Copy.presenceReasonSettings) {
                    PopopxSettingsView()
                        .navigationTitle(Copy.settings)
                        .modifier(ThemedBackground(grouped: true))
                }
            }
        }
    }

    // MARK: Group 5 · help and about (the page's last card)

    /// Device round 6 two.3: it used to be the tail row of the "frequently used" group, still with the privacy defences pressing above it, so looking for the open-source address and the privacy policy
    /// meant scrolling back to the middle of the page. Now it is the last card — after reading this page is where you decide whether to trust it.
    /// The card gives no title: the group name and the row name would be the same sentence, and the last section of WeChat's page is also just a single row.
    /// The destination `PopopxHelpView` is unchanged by one word (both the open-source address and the offline "POPOPX Privacy Policy" reader are in that page).
    private var helpEntries: some View {
        PopopxSectionCard {
            PopopxMeRowLink(Copy.helpRow, systemImage: "questionmark.circle") {
                PopopxHelpView()
                    .navigationTitle(Copy.helpRow)
            }
        }
    }

    // MARK: Group 4 · privacy and security defences

    /// Ruling 6: do not compress four things into one row. A row saying "app lock, dual password, screen-recording guard, triple-tap wipe" would be dishonest —
    /// the first two live on the `PrivacySettings` and `PopopxAntiTheftSettingsView` pages respectively, and the last one
    /// only lives on this card here, so no row can reach another row's destination. Hence two rows, each saying where it goes.
    private var securityEntries: some View {
        PopopxSectionCard(Copy.groupSecurity) {
            PopopxMeRowLink(Copy.privacySettings, systemImage: "lock.shield.fill", tint: .brand) {
                PopopxPresenceGated(reason: Copy.presenceReasonPrivacy) {
                    PrivacySettings()
                        .navigationTitle(Copy.privacySettings)
                        // The sentence is 30 characters long: as a large title on a 402pt screen it
                        // truncates to "Privacy and security s…", so this page wears an inline title.
                        .navigationBarTitleDisplayMode(.inline)
                        .modifier(ThemedBackground(grouped: true))
                }
            }
            PopopxMeDivider()
            // Device round 6 two.2: these two used to be in the "All settings → Privacy and security" card. The two keys they bind already had
            // one `Toggle` each at `PrivacySettings.swift:75`, `:88`, and the settings-page card was only the second place for the same batch of state;
            // this round merges it into this defence card, so the two become "defence card + privacy settings page", and the ones you can flip directly are no longer hidden
            // behind one push. (Whether to also close off those two inside the privacy settings page has been escalated for a ruling: that is an upstream page.)
            // The titles reuse English original sentences already present in the 16 directories (`"Protect app screen"` / `"Remove link tracking"`),
            // so this row and that switch in the privacy settings page say the same sentence; the two descriptions are POPOPX's own wording,
            // and this round turned them into Keys and filled in the 16 translations (the Chinese values are the settings page's original two sentences).
            // The app lock (`PopopxLockView`) is still on the privacy settings page: it needs the two bindings `prefPerformLA` and
            // `currentLAMode` (`PrivacySettings.swift:60`), which only that page itself can produce,
            // so no second set is replicated here.
            PopopxToggleRow(
                Copy.protectScreenRow,
                note: Copy.protectScreenNote,
                systemImage: "eye.slash",
                tint: .neutral,
                isOn: $protectScreen
            )
            PopopxMeDivider()
            PopopxToggleRow(
                Copy.sanitizeLinksRow,
                note: Copy.sanitizeLinksNote,
                systemImage: "link.badge.plus",
                tint: .neutral,
                isOn: $sanitizeLinks
            )
            PopopxMeDivider()
            // The value on the right reports only "is the sensor half switched on", not whether the dual password is configured: the latter is itself information
            // you would not want a bystander to see at a glance, and putting it on a first-level page amounts to doing the coercer's triage for them.
            PopopxMeRowLink(
                Copy.antiTheft,
                value: PopopxAntiTheftMotionGuard.shared.enabled ? Copy.antiTheftOn : Copy.antiTheftOff,
                systemImage: "exclamationmark.shield.fill",
                tint: .brand
            ) {
                PopopxAntiTheftSettingsView()
                    .navigationTitle(Copy.antiTheft)
                    .modifier(ThemedBackground(grouped: true))
            }
            .accessibilityIdentifier("popopx.me.antiTheft")
            PopopxMeDivider()
            // The offline-mesh master switch, the real verification block and the pairing policy all used to be on this card; on 2026-11-20 the whole block moved to
            // the settings center at the top-right of the Cabin page (`PopopxCabinMeshSettingsSheet`). What this card keeps are the three defences unrelated
            // to Bluetooth; the triple-tap wipe stays last, because what it wipes is exactly the mesh data that moved away.
            panicBlock
        }
    }

    /// The balance slot reads the ledger itself, not a number from some purchase callback: after the panel closes, this row must become correct by itself.
    /// Loading need not happen here — the first line of `PopopxCreditsManager.start()` is `loadIfNeeded()`
    /// (PopopxCreditsManager.swift:79-86), and that hop is scheduled inside `POPOPXApp.init()`.
    private var creditsBalanceTitle: String {
        String(format: PopopxCommerceCopy.creditsAmountFormat, credits.balance)
    }

    /// A danger row plus its own explanation form one block, occupying a single position inside the card.
    private var panicBlock: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            panicWipeRow
            Text(Copy.panicNote)
            Text(Copy.panicScope)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The only red row (§1.1 danger = system red): the emergency wipe. It does not raise its own confirmation.
    private var panicWipeRow: some View {
        PopopxPickerRow(
            Copy.panicRow,
            value: panicValue,
            systemImage: "exclamationmark.triangle.fill",
            tint: .danger
        ) {
            armPanicWipe()
        }
        .disabled(!meshRuntime.isFuseOn)
        .opacity(meshRuntime.isFuseOn ? 1 : 0.45)
        .accessibilityHint(Text(verbatim: Copy.panicRowHint))
    }

    /// The other switchable identities: the same criterion as UserPicker.swift:33-35 — identities that are locked (`user.hidden`, i.e. with a
    /// `viewPwdHash`) do not enter the switcher, because what is passed here is `viewPwd: nil`, and switching to a locked identity carrying nil would only
    /// fail. Locked identities are handled by the "Identity management" page: it uses the search field as a password field and goes through
    /// `changeActiveUserAsync_(_:viewPwd:)`'s real-password branch (UserProfilesView.swift:338 + :221).
    private func switchableOthers(of user: User) -> [UserInfo] {
        chatModel.users
            .filter { !$0.user.hidden && $0.user.userId != user.userId }
            .sorted { $0.user.activeOrder > $1.user.activeOrder }
    }

    private var lockedCount: Int {
        chatModel.users.filter { $0.user.hidden }.count
    }

    @MainActor private func switchIdentity(to info: UserInfo) {
        guard busyUserID == nil else { return }
        busyUserID = info.user.userId
        Task { @MainActor in
            defer { busyUserID = nil }
            do {
                try await changeActiveUserAsync_(info.user.userId, viewPwd: nil)
                PopopxHaptics.notice(.success)
                toast.show(Copy.switchDone, kind: .encrypted)
            } catch {
                logger.error("popopx me: switching identity \(info.user.userId) failed: \(responseError(error))")
                PopopxHaptics.notice(.error)
                toast.show(Copy.switchFailed, kind: .danger)
            }
        }
    }

    @MainActor private func copyUserID(_ userID: Int64) {
        UIPasteboard.general.string = String(userID)
        PopopxHaptics.impact(.light)
        toast.show(Copy.copiedUserID, kind: .success)
    }

    /// Feeds exactly one tap into the existing arming state machine: `PopopxPanicWipeArming.tap` decides "exactly three times within one second" by itself.
    /// The confirmation sheet is `PopopxPanicWipeGate`'s responsibility, and it is already mounted
    /// (POPOPXApp.swift:48 → POPOPXAPI.swift:4013-4030) at the app root by `PopopxMeshPanicWipeMount`, bound to the same
    /// `isAwaitingConfirmation`. So a second alert is never written here: writing one would have two confirmations fighting over the same state machine,
    /// and what the iron rule requires is one confirmation, and only that one. When the fuse is off, that gate does not exist at all
    /// (the `if runtime.isFuseOn` at POPOPXAPI.swift:4022), so this row is disabled at the same time.
    @MainActor private func armPanicWipe() {
        guard meshRuntime.isFuseOn else { return }
        PopopxHaptics.impact(.light)
        _ = panicWipe.tap()
    }

    /// The value at the row end is the state machine's truth at this moment, not "I suppose I pressed it".
    private var panicValue: String {
        if panicWipe.isWiping { return Copy.panicWiping }
        if panicArming.isAwaitingConfirmation { return Copy.panicAwaiting }
        if !meshRuntime.isFuseOn { return Copy.panicDisabled }
        let taps = panicArming.tapCount
        return taps > 0 ? String(format: Copy.panicTapsFormat, taps) : Copy.panicReady
    }
}

// MARK: - The top personal card header

/// A WeChat-style card header: 64pt avatar + bold identity name + dual-mode status bar, with a QR micro-badge and `chevron.right` at the right end.
/// The whole row (avatar to status bar) pushes "Identity management", and the QR micro-badge is a parallel second button — so these two buttons must be
/// **siblings** rather than nested: a `Button` inside a `Button` only lets the outer one eat the tap, and the card QR would never open.
@MainActor
private struct PopopxIdentityCard: View {
    private let user: User
    private let phase: PopopxBadgePhase
    private let others: [UserInfo]
    private let lockedCount: Int
    private let busyUserID: Int64?
    private let onSwitch: (UserInfo) -> Void
    private let onCopyUserID: () async -> Void
    private let onShowProfileQR: () -> Void
    private let onAddIdentity: () -> Void

    init(
        user: User,
        phase: PopopxBadgePhase,
        others: [UserInfo],
        lockedCount: Int,
        busyUserID: Int64?,
        onSwitch: @escaping (UserInfo) -> Void,
        onCopyUserID: @escaping () async -> Void,
        onShowProfileQR: @escaping () -> Void,
        onAddIdentity: @escaping () -> Void
    ) {
        self.user = user
        self.phase = phase
        self.others = others
        self.lockedCount = lockedCount
        self.busyUserID = busyUserID
        self.onSwitch = onSwitch
        self.onCopyUserID = onCopyUserID
        self.onShowProfileQR = onShowProfileQR
        self.onAddIdentity = onAddIdentity
    }

    /// The side length is not a bare number: the large avatar = spaceXL × 2 (64pt), the small avatars in the switcher = spaceXL.
    private static let avatarSide: CGFloat = PopopxMetrics.spaceXL * 2
    private static let chipAvatarSide: CGFloat = PopopxMetrics.spaceXL

    var body: some View {
        PopopxSectionCard(footnote: footnote) {
            HStack(spacing: PopopxMetrics.space2XS) {
                nameRow
                profileQRButton
                disclosureChevron
            }
            PopopxMeDivider()
            identityNumberLine
            if !others.isEmpty {
                PopopxMeDivider()
                switcher
            }
            PopopxMeDivider()
            addIdentityRow
        }
    }

    /// The "add a new identity" shortcut, tucked at the right end of the card's bottom action bar. Real-device feedback was that this route was too hard to find: you first had to push
    /// "Identity management" and then tap "Add profile", two steps (`UserProfilesView.swift:87-97`); this one compresses it into one step.
    /// The wording reuses the existing entry `Copy.createIdentity` ("Create a new identity", already translated in all 16 directories),
    /// so this round adds no Key. The action goes through the push registered by the host: `CreateProfile` is a Form,
    /// and putting it into a sheet would lose the back gesture; it is also the same pattern as `UserProfilesView.swift:112-114`.
    private var addIdentityRow: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            Spacer(minLength: PopopxMetrics.spaceXS)
            PopopxButton(Copy.createIdentity, systemImage: "person.badge.plus", role: .secondary, fullWidth: false) {
                PopopxHaptics.selection()
                onAddIdentity()
            }
        }
        .padding(.vertical, PopopxMetrics.space2XS)
        .accessibilityIdentifier("popopx.me.addIdentity")
    }

    private var nameRow: some View {
        NavigationLink {
            UserProfilesView()
                .navigationTitle(Copy.manageIdentities)
                .modifier(ThemedBackground(grouped: true))
        } label: {
            HStack(alignment: .center, spacing: PopopxMetrics.spaceS) {
                PopopxMeAvatar(image: user.image, side: Self.avatarSide)
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(user.displayName)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsFullName {
                        Text(user.fullName)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    PopopxMeStatusCapsule(phase: phase)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .padding(PopopxMetrics.space2XS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityHint(Text(verbatim: Copy.manageIdentitiesHint))
    }

    /// The card QR micro-badge. The 44×44 hit box is held by `minHitTarget`, while the icon itself is only `spaceM`.
    private var profileQRButton: some View {
        Button(action: onShowProfileQR) {
            Image(systemName: "qrcode")
                .font(PopopxType.microTag)
                .imageScale(.large)
                .foregroundStyle(PopopxPalette.brand)
                .frame(width: PopopxMetrics.spaceM, height: PopopxMetrics.spaceM)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityLabel(Text(verbatim: Copy.personalProfileQR))
        .accessibilityHint(Text(verbatim: Copy.linkHint))
        .accessibilityIdentifier("popopx.me.profileQR")
    }

    /// A decorative arrow: its hit box is on the `nameRow` to the left, so it does not enter the accessibility tree itself.
    private var disclosureChevron: some View {
        Image(systemName: "chevron.right")
            .font(PopopxType.microTag)
            .imageScale(.medium)
            .foregroundStyle(PopopxPalette.labelHint)
            .accessibilityHidden(true)
    }

    private var switcher: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(Copy.otherIdentities)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PopopxMetrics.spaceS) {
                    ForEach(others) { info in
                        PopopxIdentityChip(
                            name: info.user.displayName,
                            image: info.user.image,
                            unread: info.unreadCount,
                            busy: busyUserID == info.user.userId,
                            action: { onSwitch(info) }
                        )
                    }
                }
                .padding(.vertical, PopopxMetrics.space2XS)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// When the nickname equals the full name (or the full name is empty) it is not read out twice — the same criterion as `profileName` at SettingsView.swift:690.
    private var showsFullName: Bool {
        !user.fullName.isEmpty && user.fullName != user.displayName
    }

    private var identityNumberLine: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            HStack(spacing: PopopxMetrics.space2XS) {
                Text(Copy.identityNumberLabel)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                Text(verbatim: "\(user.userId)")
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.label)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: Copy.identityNumberLabel))
            .accessibilityValue(Text(verbatim: "\(user.userId)"))

            Spacer(minLength: PopopxMetrics.spaceXS)

            PopopxButton(
                Copy.copyUserID,
                systemImage: "doc.on.doc",
                role: .ghost,
                fullWidth: false,
                action: onCopyUserID
            )
        }
        .padding(PopopxMetrics.space2XS)
    }

    private var footnote: String? {
        if others.isEmpty {
            return lockedCount > 0 ? String(format: Copy.lockedOnlyNoteFormat, lockedCount) : nil
        }
        return lockedCount > 0
            ? String(format: Copy.switchNoteWithLockedFormat, lockedCount)
            : Copy.switchNote
    }
}

/// The dual-mode status bar of the card header: the left segment is online transport (SMP), the right segment is the node-entitlement tier.
/// Each segment reads its own single source of truth (the transport wording reuses the already-translated Key from the onboarding page, and entitlement reads `PopopxBadgeManager.phase`),
/// and this page no longer judges a third channel. Coloring uses only `successInk` / `labelSecondary`:
/// in §1.1 cyan-green means offline Cabin exclusively, and using it to color an online entitlement would fabricate a transport channel that does not exist.
private struct PopopxMeStatusCapsule: View {
    private let phase: PopopxBadgePhase

    init(phase: PopopxBadgePhase) {
        self.phase = phase
    }

    var body: some View {
        let tint = phase.isLit ? PopopxPalette.successInk : PopopxPalette.labelSecondary
        HStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: "lock.fill")
                .font(PopopxType.microTag)
                .imageScale(.medium)
            Text(Copy.smpEncrypted)
                .font(PopopxType.microTag)
            Text(verbatim: "·")
                .font(PopopxType.microTag)
            Text(badgeWords)
                .font(PopopxType.microTag)
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, PopopxMetrics.spaceS)
        .padding(.vertical, PopopxMetrics.space2XS)
        .background(PopopxPalette.brand.opacity(0.10), in: .capsule)
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: PopopxMetrics.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(Copy.smpEncrypted), \(badgeWords)"))
    }

    /// Short enough to follow the identity name without wrapping: dormant only says "not activated", lit and trial each say their own day count.
    private var badgeWords: String {
        switch phase {
        case .dormant:
            return Copy.badgeDormant
        case let .trial(expiresAt):
            return String(format: Copy.badgeTrialShortFormat, Self.daysLeft(expiresAt))
        case let .active(_, expiresAt):
            return String(format: Copy.badgeActiveShortFormat, Self.daysLeft(expiresAt))
        }
    }

    private static func daysLeft(_ expiresAt: Date) -> Int {
        max(1, Int(ceil(max(0, expiresAt.timeIntervalSinceNow) / 86_400)))
    }
}

/// A tappable other identity. The whole thing is a `Button`, 44pt high, VoiceOver reads the name + "continue as this identity".
@MainActor
private struct PopopxIdentityChip: View {
    private let name: String
    private let image: String?
    private let unread: Int
    private let busy: Bool
    private let action: () -> Void

    init(name: String, image: String?, unread: Int, busy: Bool, action: @escaping () -> Void) {
        self.name = name
        self.image = image
        self.unread = unread
        self.busy = busy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: PopopxMetrics.space2XS) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PopopxPalette.brand)
                        .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                } else {
                    PopopxMeAvatar(image: image, side: Self.chipAvatarSide)
                }
                Text(name)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .lineLimit(1)
                if unread > 0 {
                    unreadBadge
                }
            }
            .padding(.horizontal, PopopxMetrics.spaceS)
            // 44pt is a floor rather than a fixed value: under large dynamic type this chip must be able to grow taller, and must not clip the name.
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.separator, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                    .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(busy)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(unread > 0 ? Text(verbatim: String(format: Copy.unreadBadgeFormat, unread)) : Text(verbatim: ""))
        .accessibilityHint(Text(verbatim: Copy.switchHint))
    }

    /// The unread count is taken directly from `UserInfo.unreadCount` (ChatTypes.swift:104); this file does not compute a second set.
    /// The number itself does not enter the accessibility tree: the whole chip already reads it out as the value.
    private var unreadBadge: some View {
        Text(verbatim: "\(unread)")
            .font(PopopxType.metricSmall)
            .foregroundStyle(PopopxPalette.onBrand)
            .padding(.horizontal, PopopxMetrics.space2XS)
            .frame(minWidth: PopopxMetrics.spaceL, minHeight: PopopxMetrics.space2XL / 2)
            .background(PopopxPalette.brand, in: Capsule())
            .accessibilityHidden(true)
    }

    private static let chipAvatarSide: CGFloat = PopopxMetrics.spaceXL
}

/// The avatar. With base64 it uses the existing `ProfileImage`, without it falls back to the brand mark — no placeholder figure is drawn,
/// and no "geometric gradient initial whose hue is derived from the identity" either (ruling 5): the whole repository has no `colorForProfile`-style
/// hue-per-identity helper (0 hits), and in §1.1 indigo-violet means only "online identity" while cyan-green means only "offline Cabin",
/// so using hue as pure decoration would fabricate a transport channel that does not exist. Rather leave it empty than guess.
@MainActor
private struct PopopxMeAvatar: View {
    private let image: String?
    private let side: CGFloat

    /// The appearance unlocked on this device. The same singleton as the outer layer, not a second piece of state: only `owns` is read here,
    /// and spending still happens only on the compute-credits center page.
    @State private var credits = PopopxCreditsManager.shared

    /// The stroke applies only to the large-avatar tier: the chip tier's `side` is `spaceXL`, and a 1.5pt two-colour ring at that size
    /// smears into a dirty circle, showing "appearance" not at all and "broken rendering" instead. The threshold is written as double rather than comparing `avatarSide` directly,
    /// so as not to copy those two size constants a second time inside the same type.
    private static let ringMinimumSide: CGFloat = PopopxMetrics.spaceXL * 2

    private var wearsAuroraFrame: Bool {
        side >= Self.ringMinimumSide && credits.owns(.auroraShieldAvatarFrame)
    }

    init(image: String?, side: CGFloat) {
        self.image = image
        self.side = side
    }

    var body: some View {
        Group {
            if imageFromBase64(image) != nil {
                // The `color:` value is the same one as UserPicker.swift:44: inside, `ProfileImage` maps
                // this image's lightness/darkness on the group background via `asAnotherColorFromSecondaryVariant`, and replacing it would be wrong.
                ProfileImage(imageStr: image, size: side, color: Color(uiColor: .tertiarySystemGroupedBackground))
            } else {
                Image(PopopxBrandAsset.mark)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous))
            }
        }
        .frame(width: side, height: side)
        // The "aurora shield avatar frame": drawn only around this device's own avatar. This family of avatar types draws only the local identity
        // (contacts and group avatars each have their own types), so the compute-credits center's sentence "rendered on the local avatar, never uploaded"
        // holds structurally here, and the direction need not be judged a second time.
        // `strokeBorder` rather than `stroke`: the former eats the line width inward, so the avatar size is not stretched,
        // and the identity name and address on the same card will not shift by a row because an appearance was bought.
        // The two colours travel diagonally around the ring, and the start point remains `PopopxPalette.brand`: this tier does not replace the brand colour, it only adds one ring.
        .overlay {
            if wearsAuroraFrame {
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusAvatar, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [PopopxPalette.brand, Self.auroraFrameEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: PopopxMetrics.stroke
                    )
            }
        }
        // The avatar is always decoration on this page: the identity name is on the same card, so VoiceOver is not asked to read it twice.
        .accessibilityHidden(true)
    }

    /// The aurora shield's end colour (cyan). The only value in this tier that is not in `PopopxPalette`, and also, within the whole commercial feature, exactly where a decorative colour belongs:
    /// only this one place reads it; anywhere else that wants it must unlock first and then stroke, rather than sharing a token.
    private static let auroraFrameEnd = Color.popopx(light: 0x1F8A70, dark: 0x4FD8B6)
}

/// A row that "pushes an existing page". The appearance reuses `PopopxPickerRow` directly, but the tap is handed to the outer `NavigationLink`:
/// the row in the atomic library is itself a `Button`, and a nested button would eat the link's tap, so the whole row is made unhittable
/// and stays out of the accessibility tree, while the link itself carries the same-named label and hint (44pt is held by `minHitTarget`).
@MainActor
/// The "presence verification" shell for sensitive pages (anti-theft module two). If it does not pass, **not one frame of body content is drawn**.
///
/// Why the interception is not on the `NavigationLink`: the rows of this family are destination-style links, and intercepting the push would mean changing the whole Me page's
/// navigation structure; whereas the semantics of `.suspicious` are "the phone may be in someone else's hands right now", so rendering the body one frame late is a leak.
/// when it is refused, module two has already landed the user on the full-screen overlay, so all this needs is `dismiss()` to close itself,
/// no need to draw an extra "declined" line: one more hint is one more signal a coercer can read.
private struct PopopxPresenceGated<Content: View>: View {
    private let reason: String
    private let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var allowed = false

    init(reason: String, @ViewBuilder content: @escaping () -> Content) {
        self.reason = reason
        self.content = content
    }

    var body: some View {
        if allowed {
            content()
        } else {
            // An empty shell in the same colour as the page background: it may not be a blank page and it may not be a spinner, because both of them communicate "you were stopped".
            Color.clear
                .task {
                    if await PopopxBehaviorGuard.shared.authorized(reason: reason) {
                        allowed = true
                    } else {
                        dismiss()
                    }
                }
        }
    }
}

private struct PopopxMeRowLink<Destination: View>: View {
    private let title: String
    private let value: String?
    private let systemImage: String?
    private let tint: PopopxIconTint
    private let destination: () -> Destination

    init(
        _ title: String,
        value: String? = nil,
        systemImage: String? = nil,
        tint: PopopxIconTint = .neutral,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            // The home page has closed off the whole title bar (a WeChat-style first screen), and "hidden" seeps into the pages pushed from here along with this layer's toolbar preference -
            // the messages page does the same thing by having the destination declare itself visible (`ChatsListView.swift:408`). Every row link passes
            // through here, so one sentence is enough: each sub-page's own `.navigationTitle` still takes effect and not one back button is missing.
            destination()
                .toolbar(.visible, for: .navigationBar)
        } label: {
            PopopxPickerRow(title, value: value, systemImage: systemImage, tint: tint) { }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text(verbatim: Copy.linkHint))
    }
}

/// Divider inside the card. The one of the same name at `PopopxControls.swift:853` lives only inside the `#if DEBUG` gallery, out of reach.
private struct PopopxMeDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

/// `UserProfile` needs `SaveableSettings` from the environment (UserProfile.swift:16, its body writes `ss.profileSave`),
/// and that object is only built on the spot inside the subtree that mounts it (ChatListView.swift:81 creates it, :159 injects it). Wrapping a layer the same way,
/// otherwise pushing it in means a missing EnvironmentObject.
private struct PopopxProfileHost: View {
    @StateObject private var settings = SaveableSettings()

    var body: some View {
        UserProfile()
            .navigationTitle(Copy.myProfile)
            .modifier(ThemedBackground(grouped: true))
            .environmentObject(settings)
    }
}

// MARK: - Copy

/// Every sentence on this page that is visible (or that VoiceOver can read out) appears exactly once here, and always through
/// `NSLocalizedString`: **the English source sentence is the Key**, the same approach as the onboarding pages and the compute-point ecosystem.
/// New entries go into the 16 translation directories `bg/cs/de/es/fi/fr/hu/it/ja/nl/pl/ru/th/tr/uk/zh-Hans`,
/// and `en.lproj` is not written (an unreadable entry falls back to the Key itself, which is English).
/// Two Keys deliberately reuse existing entries - `"Settings"`, `"SMP end-to-end encrypted"`:
/// they already have translations in all 16 directories, and the Chinese values are exactly the sentences this page shows.
private enum Copy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX Me tab")
    }

    static let pageTitle = key("Me")
    static let linkHint = key("Open")

    // Personal card header at the top
    static let identityNumberLabel = key("Identity number")
    static let copyUserID = key("Copy number")
    static let copiedUserID = key("Identity number copied")
    static let manageIdentities = key("Manage identities")
    static let manageIdentitiesHint = key("Opens the identity list on this device")
    static let smpEncrypted = NSLocalizedString("SMP end-to-end encrypted", comment: "Me: transport segment of the name card status capsule")
    static let otherIdentities = key("Switch to another identity")
    static let switchHint = key("Continue as this identity")
    static let switchDone = key("Identity switched")
    static let switchFailed = key("Switch failed. Try again later.")
    static let switchNote = key("Locked identities are not listed here: switching to them needs the view password.")
    static let switchNoteWithLockedFormat = NSLocalizedString("Tap an avatar to switch; this device has %d locked identities that need the view password in Manage identities.", comment: "Me: identity switcher footnote")
    static let lockedOnlyNoteFormat = NSLocalizedString("This device has %d locked identities that need the view password before you can switch.", comment: "Me: identity switcher footnote, no switchable identity")
    static let unreadBadgeFormat = NSLocalizedString("%d unread", comment: "Me: unread count spoken on an identity chip")
    static let emptyTitle = key("No active identity yet")
    static let emptyNote = key("An identity is your anonymous card on popopx: a display name, an avatar and a message store of its own. Create one and you can start chatting.")
    static let emptyFootnote = key("Creating an identity asks for no phone number and no email.")
    static let createIdentity = key("Create a new identity")

    // Section title
    static let groupAssets = key("Assets and node benefits")
    /// 2026-11-20 source sentence replaced: the whole "offline mesh" row that used to sit in this section moved to the Cabin page, so the title saying "offline mesh" again
    /// would be reserving a phrase for someone else. The old Key `"Personal space and offline mesh"` has 0 leftovers in the code.
    static let groupSpace = key("Encrypted profile and card vault")
    static let groupGeneral = key("Preferences & Settings")
    static let groupSecurity = key("Privacy and security defences")

    // Section 1 · compute points and badges
    static let creditsWallet = key("Compute Credits wallet")
    static let badgeRow = key("Dynamic privacy node badge")
    static let badgeDormant = key("Not activated")
    static let badgeTrialFormat = NSLocalizedString("Trial: %d days left", comment: "Me: badge row value, pioneer trial")
    static let badgeRunningFormat = NSLocalizedString("Running: %d days left", comment: "Me: badge row value, active badge")
    static let badgeTrialShortFormat = NSLocalizedString("Trial %d days", comment: "Me: name card capsule, pioneer trial")
    static let badgeActiveShortFormat = NSLocalizedString("Routing %d days", comment: "Me: name card capsule, active badge")
    /// "Top up" rather than "buy a compute-point gift pack": this tier carries no bonus at all, and the sentence may not hint that it does.
    static let purchaseCredits = key("Top up Compute Credits")
    /// The capsule on the right of the badge row that goes straight to purchase/renew. The wording has to be short enough to fit inside 393pt of width,
    /// hence the two words "Buy" and "Renew", not the sentence "Buy the official badge now" (that one lives in the alert).
    static let badgeBuy = key("Buy")
    static let badgeRenew = key("Renew")

    // Section 2 · encrypted profile page and card wallet
    static let myProfile = key("My profile")
    static let personalProfile = key("My encrypted profile page")
    static let personalProfileQR = key("Profile card code")
    static let profileConfigured = key("Configured")
    static let profileUnconfigured = key("Not created yet")
    static let profileModeEphemeral = key("Burn after reading")
    static let profileModeStandard = key("Persistent card")
    static let profileQRIdentityFallback = key("Unnamed identity")
    static let giftVault = key("Gift badge cards and redemption")
    static let giftSend = key("Gift a badge card")
    static let redeemCode = key("Redeem a code")
    static let vouchersAvailableFormat = NSLocalizedString("%d available", comment: "Me: unused gift vouchers on this device")
    static let giftMenuHint = key("Lets you gift a badge card or redeem a code")

    // Section 3 · commonly used
    // The three rows "Chat preferences", "Appearance and icon" and "Display language" fell back into "All settings" on 2026-11-20 (on-device round 6, part two.1):
    // their source sentences and the wording of the two values `notifyOn`/`notifyOff` moved together into
    // `PopopxGeneralCopy` in `Shared/Features/Settings/PopopxSettingsViews.swift`, Keys unchanged character for character,
    // the 16 translations untouched in place, so this page no longer references those four entries. The reason for deliberately not calling it `"Chat preferences"` goes
    // with that row: the Key `"Chat preferences"` belongs to other pages in the 16 directories, its Chinese value is "Chat preferences settings",
    // and the source sentence has to stay unique.
    static let settings = NSLocalizedString("Settings", comment: "Me: reuses the existing all-catalog term")
    // The "Notifications" row was deleted in 2026-11: its only entry point is now closed off into commonly used -> All settings -> Notifications; the "Version" row went
    // up with the promotion of `PopopxHelpView` - the old Keys `"Notifications"` and `"Version and updates"` are no longer referenced on this page,
    // while the two entries themselves still belong to other pages and their translations stay untouched.
    /// "Help and about" is now the only row of the last card on the page (see `helpEntries` above); the wording did not change.
    static let helpRow = key("Help and about")

    // Section 4 · privacy and the security lines
    static let privacySettings = key("Privacy and security settings")
    /// The titles of the two switches reuse source sentences that already exist in the 16 directories - they and the two `Toggle`s at `PrivacySettings.swift:75`/`:88`
    /// are the very same switch, so the wording must share one Key and this page no longer coins a sentence of its own.
    static let protectScreenRow = key("Protect app screen")
    static let sanitizeLinksRow = key("Remove link tracking")
    /// The two captions are the two sentences the settings page originally carried; this round they became Keys and 16 translations were filled in (the Chinese values are reused verbatim).
    static let protectScreenNote = key("While the app is in the background its whole interface is replaced by a placeholder, so the app switcher and screenshots show no chat content.")
    static let sanitizeLinksNote = key("Tracking fields are stripped from links while you compose a message, so what the other side receives carries no trace of your source.")
    static let antiTheft = key("Anti-theft lock")
    static let antiTheftOn = key("Turned on")
    static let antiTheftOff = key("Turned off")
    /// The reason string for presence verification: it goes into the system biometric prompt, so it is visible copy too.
    static let presenceReasonPrivacy = key("Confirm this is you before opening privacy and security settings")
    static let presenceReasonSettings = key("Confirm this is you before opening settings")
    static let commerceFootnote = key("Credits and badges live only in this device's keychain: no server keeps the ledger, and neither side can change it remotely.")

    // Dangerous row
    static let panicRow = key("Erase offline mesh data now")
    static let panicReady = key("Triple tap")
    static let panicTapsFormat = NSLocalizedString("%d/3 taps counted", comment: "Me: panic wipe arming progress")
    static let panicAwaiting = key("Waiting for confirmation")
    static let panicWiping = key("Erasing…")
    static let panicDisabled = key("Unavailable while the fuse is closed")
    static let panicRowHint = key("Three taps within one second arm it")
    static let panicNote = key("Three taps on this row within one second arm the wipe; the app's single confirmation dialog then asks you once. Cancelling voids it — nothing is ever erased silently. While the fuse is closed that dialog does not exist, so this row is disabled too.")
    /// The scope, stated where the row can be read without arming it. This row and the self-destruct
    /// code are the two erase paths in the app and they delete different things; until now only the
    /// dialog said so, and only about what is removed, never about what survives.
    static let panicScope = key("It clears this device's offline mesh identity, keys and records plus the app's temporary media copies, then closes the app. Chats, contacts and files stay — the self-destruct passcode is the one that deletes them.")
}

// MARK: - Previews

#if DEBUG
struct PopopxMeView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxMeView()
        }
        .environmentObject(ChatModel.shared)
        .environmentObject(AppTheme.shared)
    }
}

struct PopopxMeViewPopulated_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxMeView()
        }
        .environmentObject(ChatModel.shared)
        .environmentObject(AppTheme.shared)
        .onAppear {
            // A preview may do without live data: all this does is hand the existing sampleData to the shared model,
            // and the empty-state card itself holds no fabricated data (the preview above is exactly how it really looks).
            if ChatModel.shared.currentUser == nil {
                ChatModel.shared.currentUser = User.sampleData
                ChatModel.shared.users = [UserInfo.sampleData]
            }
        }
    }
}
#endif
