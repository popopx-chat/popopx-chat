//
//  PopopxSettingsViews.swift
//  POPOPX (iOS)
//
//  [fourth phase] the popopx version of the settings tree: replaces Shared/Views/UserSettings/SettingsView.swift:305.
//  Its input surface is aligned with it verbatim (`showProgress`, `versionText`, `colorScheme`/`dismiss`/`ChatModel`/
//  `SceneDelegate` environments), so each of the two call sites only needs one word changed to mount it:
//  Shared/Features/Me/PopopxMeView.swift:418 and Shared/Views/ChatList/ChatListView.swift:112.
//
//  Four structural decisions:
//
//  1. This page uses no List, but a ScrollView + grouped cards (`PopopxSectionCard`). The sub-pages pushed into it (the two privacy toggles,
//     notifications, calls, servers, data, migration) are all outside this round's scope; this page is only responsible for the entries: every row is a real init, a real environment object,
//     a real Binding, with no placeholder rows.
//     From 2026-11-20 on, this page no longer has the 'Cabin offline meshing' and 'Badges and usage' cards: the first was folded whole into the top-right
//     `PopopxCabinMeshSettingsSheet` of the Cabin page, and the second is carried by the dynamic badge row at the top of the 'Me' page and the compute-point wallet.
//     Device walkthrough III.1/III.4 removed two more cards: this page keeps only entries, never a second route to the same destination:
//       · the whole 'Appearance' group moved up to the 'Me' tab's frequent group in 2026-11, and device round 6 II.1 brought it back to this page
//         (`appearanceCard`; the card name and the two row phrasings use the English source sentence as Key); the theme name at the row end has always lived in this file's
//         `PopopxSettingsValues.themeName`, and both sides read the same `currentThemeDefault` -- no second set of readings.
//       · 'Help and about' was upgraded from a card into a real page `PopopxHelpView` (likewise entered only from the 'Me' tab), and gained
//         the open-source address and privacy policy rows; `PopopxDisplayLanguageView` is the 'display language' page brought out by that same upgrade.
//       · `privacyCard` whole card deleted on 2026-11-20 (device round 6 II.2): the screen-protection and link-de-tracking toggles that were left on that card
//         share the same batch of state as `PrivacySettings.swift:75`/`:88`, and now sit directly on the 'Me' tab's defence card.
//     · Device round 8, task six (hierarchy rearrangement): the 'Network and servers' card went from one entry to three entries at the same level.
//         'Advanced network settings' and 'Network connection' were originally buried inside that 'Relays and servers' page (`NetworkAndServers`);
//         they are now raised to this level and deleted where they were; one level fewer, and both phrasings plus the rows left on that page are unchanged (see `networkCard` for the details).
//  2. Colour, font size, corner radius and spacing come only from the tokens in Shared/Theme/PopopxTheme.swift; the row controls are
//     assembled per the Shared/Components atom-library conventions, and the hit area is held at 44pt by `PopopxMetrics.minHitTarget`.
//     This page therefore does not read the whole-app theme object -- the sub-pages still carry their own background modifiers, and that convergence is a separate cut.
//  3. The 'Relays and servers' row is **not** a value-based link but a plain `Button`: the tap performs exactly one
//     `settingsTrack.path.append(ServersDestination.networkAndServers)`. Device walkthrough round 2 (2026-11-20)
//     concluded that the registration position is not that lever -- registration written on this page (before `8dea049d3`) versus raised to the stack root (`8dea049d3`)
//     had verbatim identical symptoms (tapping only redraws this page; pressing Back is what pushes), and ProtocolServersView.swift:295-298 states
//     that for a given type only the registration closest to the stack root is kept, so the stack root is the correct position; what is broken is the `NavigationLink(value:)`
//     activation of this hop. The path is held by `PopopxSettingsNavTrack` (Shared/Navigation/MainTabView.swift),
//     and the two hosts each hold a copy and inject it: MainTabView.swift:174's 'Me' tab and ChatListView.swift:98's
//     UserPickerSheetView. The three pages' own registrations stay at their respective stack roots (ServersDestination / ProtocolServerSelection /
//     ChatRelaySelection); this page writes no registration any more and leaves no comment to mislead the next person.
//  4. The three `@AppStorage` toggles write the very same key as the sub-pages, not a second set of state: screen protection, link de-tracking,
//     call forced relay. `@AppStorage` follows UserDefaults changes on its own, so the two sides are always in sync.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand -- the iron rule forbids scripts from changing project.pbxproj.
//

import SwiftUI
import UIKit
import StoreKit
import POPOPXChat

// MARK: - Root page

@MainActor
struct PopopxSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var chatModel: ChatModel

    /// The host stack's path. Used only for the deterministic push of the 'Relays and servers' hop; see decision 3 in the file header.
    @Environment(PopopxSettingsNavTrack.self) private var settingsTrack

    /// `MigrateFromDevice` reports the migration's progress back to this page through it and covers the whole screen (old SettingsView.swift:312/318).
    @State private var showProgress: Bool = false

    var versionText: String? = appVersion

    /// After device round 6 II.2 this tree keeps only the call toggle: the screen-blur and de-tracking toggles, together with that 'Privacy and security' card,
    /// were merged into the 'Me' tab's privacy and security defence (`securityEntries` in `PopopxMeView.swift`; the two keys themselves are unchanged).
    /// The same batch of keys as CallSettings.swift:15/31.
    @AppStorage(DEFAULT_WEBRTC_POLICY_RELAY) private var webrtcPolicyRelay = true

    /// Externally only two forms are recognised: `PopopxSettingsView()` and `PopopxSettingsView(versionText:)`.
    /// The explicit init is written so that the `@State`/wrapped properties can stay private.
    init(versionText: String? = appVersion) {
        self.versionText = versionText
    }

    var body: some View {
        ZStack {
            settingsTree
            if showProgress {
                progressOverlay
            }
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.pageTitle)
        .toolbarBackground(PopopxMaterial.bar, for: .navigationBar)
    }

    private var settingsTree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                headerCard
                appearanceCard
                callsAndNtfsCard
                networkCard
                dataCard

                PopopxMediaCompressionSettingsSection()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
    }

    // MARK: Top: version and the two-colour language

    private var headerCard: some View {
        PopopxSectionCard {
            HStack(alignment: .center, spacing: PopopxMetrics.spaceS) {
                // the wordmark has separate light and dark image sets, and this row is the only place in the whole page that must read colorScheme;
                // a resizable image must be given a frame upper bound, or it will stretch the entire card open.
                Image(PopopxBrandAsset.wordmark(for: colorScheme))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(
                        maxWidth: PopopxMetrics.space2XL * 3,
                        maxHeight: PopopxMetrics.spaceL,
                        alignment: .leading
                    )
                    .accessibilityHidden(true)
                Spacer(minLength: PopopxMetrics.spaceXS)
                Text(verbatim: "v\(versionText ?? "?") (\(appBuild ?? "?"))")
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PopopxSettingsDivider()

            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                legendChip(
                    systemImage: "lock.shield.fill",
                    title: Copy.legendOnline,
                    fill: PopopxPalette.brand,
                    ink: PopopxPalette.onBrand
                )
                legendChip(
                    systemImage: "antenna.radiowaves.left.and.right",
                    title: Copy.legendMesh,
                    fill: PopopxPalette.mesh,
                    ink: PopopxPalette.onMesh
                )
                Text(Copy.legendNote)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendChip(systemImage: String, title: String, fill: Color, ink: Color) -> some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: systemImage)
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(ink)
                .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
                .background(fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                .accessibilityHidden(true)
            Text(title)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.label)
            Spacer(minLength: PopopxMetrics.spaceXS)
        }
    }

    // MARK: Appearance and language

    /// Device round 6 II.1: this group was raised whole to the 'Me' tab's frequent group in 2026-11 and now comes back down to the settings tree, in the position
    /// right after the top card -- which is where it was to begin with. The destination, `ThemedBackground`, the availability gate (`AppearanceSettings`
    /// still requiring a running session) and the row-end reading are copied verbatim; `PopopxSettingsValues.themeName`/`languageName`
    /// those two readings are back in the same file as their provider, so there is one fewer cross-file reference.
    private var appearanceCard: some View {
        PopopxSectionCard(PopopxGeneralCopy.groupAppearance) {
            PopopxSettingsRowLink(
                PopopxGeneralCopy.appearanceRow,
                value: PopopxSettingsValues.themeName,
                systemImage: "sun.max",
                enabled: chatModel.chatRunning == true,
                hint: PopopxGeneralCopy.openHint
            ) {
                AppearanceSettings()
                    .navigationTitle(PopopxGeneralCopy.appearanceRow)
                    .modifier(ThemedBackground(grouped: true))
            }
            PopopxSettingsDivider()
            // the language page needs no running session: it opens this app's page inside the system settings, so this row neither gates nor disables.
            PopopxSettingsRowLink(
                PopopxGeneralCopy.languageRow,
                systemImage: "character.bubble",
                hint: PopopxGeneralCopy.openHint
            ) {
                PopopxDisplayLanguageView()
                    .navigationTitle(PopopxGeneralCopy.languageRow)
            }
        }
    }

    // MARK: Notifications and calls

    private var callsAndNtfsCard: some View {
        PopopxSectionCard(Copy.groupCalls) {
            // device round 6 II.1: the profile's chat preferences come back down here from the 'Me' tab's frequent group, right next to the two things they govern
            // -- notifications and calls. The destination and the three entries are as before, given verbatim per the existing mount point at `ChatListView.swift:100-103`.
            if let user = chatModel.currentUser {
                PopopxSettingsRowLink(
                    PopopxGeneralCopy.chatPreferences,
                    value: user.showNtfs ? PopopxGeneralCopy.notifyOn : PopopxGeneralCopy.notifyOff,
                    systemImage: "slider.horizontal.3",
                    hint: PopopxGeneralCopy.openHint
                ) {
                    PreferencesView(
                        profile: user.profile,
                        preferences: user.fullPreferences,
                        currentPreferences: user.fullPreferences
                    )
                    .navigationTitle(PopopxGeneralCopy.chatPreferences)
                    .modifier(ThemedBackground(grouped: true))
                }
                PopopxSettingsDivider()
            }
            PopopxSettingsRowLink(
                Copy.notificationsRow,
                value: notificationValue,
                systemImage: notificationIcon,
                enabled: chatModel.chatRunning == true
            ) {
                NotificationsView()
                    .navigationTitle(Copy.notificationsRow)
            }
            PopopxSettingsDivider()
            PopopxSettingsRowLink(
                Copy.callsRow,
                systemImage: "video",
                enabled: chatModel.chatRunning == true
            ) {
                CallSettings()
                    .navigationTitle(Copy.callsRow)
            }
            PopopxSettingsDivider()
            PopopxToggleRow(
                Copy.relayCallsRow,
                note: webrtcPolicyRelay ? Copy.relayCallsNoteOn : Copy.relayCallsNoteOff,
                systemImage: "network",
                tint: .neutral,
                isOn: $webrtcPolicyRelay
            )
        }
    }

    /// The notification mode comes from `chatModel.notificationMode` (ChatModel.swift:435), covering all three cases.
    private var notificationValue: String {
        switch chatModel.notificationMode {
        case .off: return Copy.ntfsOff
        case .periodic: return Copy.ntfsPeriodic
        case .instant: return Copy.ntfsInstant
        }
    }

    /// The icon changes with the mode, but no second colour scheme is introduced: the old page's three system yellow/green spots (SettingsView.swift:606-610)
    /// are not tokens, so here they fall back to the neutral colour uniformly.
    private var notificationIcon: String {
        switch chatModel.notificationMode {
        case .off: return "bell.slash"
        case .periodic: return "timer"
        case .instant: return "bolt.fill"
        }
    }

    // MARK: Network and servers

    /// Device round 8, task six (hierarchy rearrangement): this card went from one entry to three entries at the same level.
    /// The 'Advanced network settings' and 'Network connection' rows were originally buried in that 'Relays and servers' page
    /// (`NetworkAndServers`) as its last two Sections; they are now raised to this level and deleted from where they were, leaving that page only
    /// the server rows themselves (preset servers / your servers / save).
    /// The push mechanism of the three rows was not chosen casually; each has a reason:
    /// · 'Relays and servers' = a plain `Button` + one `settingsTrack.path.append` (decision 3 in the file header) --
    ///   changed to `NavigationLink(value:)`, a tap on a real device only redraws this page and Back is what pushes it.
    /// · 'Advanced network settings' = a destination-closure `NavigationLink` (`PopopxSettingsRowLink`), the very same mechanism as every other
    ///   row on this page: it writes no value into the path and is resolved by registration, so it does not depend on the broken lever of decision 3, and a tap pushes immediately.
    ///   Availability matches the original: that page reads and writes network configuration, so it disables when no session is running (same rule as `callsAndNtfsCard`).
    /// · 'Network connection' = a read-only status row. On its original page it was also not an entry but a stretch of reading, and flattening does not invent
    ///   a destination that does not exist for it, so it gets no chevron and takes no tap.
    private var networkCard: some View {
        PopopxSectionCard(Copy.groupNetwork, footnote: Copy.networkFootnote) {
            // Plain Button + one path assignment, not `NavigationLink(value:)`: on a real device that hop only redraws this page when tapped.
            Button {
                settingsTrack.path.append(ServersDestination.networkAndServers)
            } label: {
                PopopxSettingsRowLabel(
                    title: Copy.serversRow,
                    systemImage: "externaldrive.connected.to.line.below",
                    tint: .brand
                )
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopopxPressButtonStyle())
            .accessibilityHint(Text(verbatim: Copy.openHint))
            .disabled(chatModel.chatRunning != true)
            .opacity(chatModel.chatRunning == true ? 1 : 0.45)
            PopopxSettingsDivider()
            PopopxSettingsRowLink(
                PopopxNetworkCopy.advancedRow,
                systemImage: "network",
                tint: .brand,
                enabled: chatModel.chatRunning == true,
                hint: PopopxGeneralCopy.openHint
            ) {
                AdvancedNetworkSettings()
                    .navigationTitle(PopopxNetworkCopy.advancedTitle)
                    .modifier(ThemedBackground(grouped: true))
            }
            PopopxSettingsDivider()
            PopopxNetworkStatusRow(
                type: chatModel.networkInfo.networkType,
                online: chatModel.networkInfo.online
            )
        }
    }

    // MARK: Data and migration

    private var dataCard: some View {
        PopopxSectionCard(Copy.groupData, footnote: Copy.dataFootnote) {
            PopopxSettingsRowLink(
                Copy.chatDataRow,
                systemImage: chatModel.chatDbEncrypted == false ? "exclamationmark.triangle.fill" : "internaldrive",
                tint: chatModel.chatDbEncrypted == false ? .danger : .neutral
            ) {
                DatabaseView(dismissSettingsSheet: dismiss, chatItemTTL: chatModel.chatItemTTL)
                    .navigationTitle(Copy.chatDataRow)
            }
            PopopxSettingsDivider()
            PopopxSettingsRowLink(
                Copy.migrateRow,
                note: showProgress ? Copy.migrateRunning : nil,
                systemImage: "tray.and.arrow.up"
            ) {
                MigrateFromDevice(showProgressOnSettings: $showProgress)
                    .navigationTitle(Copy.migrateRow)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    // MARK: Migration progress overlay

    private var progressOverlay: some View {
        ZStack {
            PopopxPalette.base
                .opacity(0.72)
            ProgressView()
                .controlSize(.large)
                .tint(PopopxPalette.brand)
                .padding(PopopxMetrics.spaceL)
                .background(PopopxPalette.cardHigh, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Copy.migrateRunning))
    }
}

// MARK: - The two shared row-end readings

/// The 'Me' tab's frequent group and this page both have to write the same true value at the row end, so only this one reading is kept, not two sets of state.
/// The words themselves still come from this file's `Copy`: those are phrasings already in the settings tree, and read from another page they are still the same sentence,
/// so the same thing never ends up written two different ways in two places.
enum PopopxSettingsValues {
    /// The row end writes exactly the true value inside `currentThemeDefault` (that `StringDefault` in old SettingsView.swift:239),
    /// not some boolean that one page memorised.
    @MainActor static var themeName: String {
        switch currentThemeDefault.get() {
        case DefaultTheme.SYSTEM_THEME_NAME: return Copy.themeSystem
        case DefaultTheme.LIGHT.themeName: return Copy.themeLight
        case DefaultTheme.DARK.themeName: return Copy.themeDark
        case DefaultTheme.POPOPX.themeName: return Copy.themePopopx
        case DefaultTheme.BLACK.themeName: return Copy.themeBlack
        default: return Copy.themeCustom
        }
    }

    /// Which language this app currently uses. The derivation is verbatim the same as `AppearanceSettings`' original line
    /// (the first localization the system chose for this app + its readable language name), but here it is computed on its own
    /// instead of reading that page's private computed property.
    @MainActor static var languageName: String {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.current.localizedString(forIdentifier: lang)?.localizedCapitalized ?? lang
    }
}

// MARK: - Row

/// The content body of a row: it is not a Button; the link and the button each decide who owns the tap.
@MainActor
struct PopopxSettingsRowLabel: View {
    let title: String
    var value: String?
    var note: String?
    var systemImage: String?
    var assetImage: String?
    var tint: PopopxIconTint = .neutral
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            artwork
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(title)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: PopopxMetrics.spaceXS)
            if let value {
                Text(value)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The two shapes share one `spaceXL` frame (PopopxTheme.swift:162) and are the same size as the atom library's
    /// `PopopxIconBadge` (PopopxControls.swift:315-327): changing the icon does not make the row height jump.
    @ViewBuilder private var artwork: some View {
        if let assetImage {
            Image(assetImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
                .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                .background(PopopxPalette.separator, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                .accessibilityHidden(true)
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(tint.ink)
                .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                .background(tint.fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                .accessibilityHidden(true)
        }
    }
}

/// Pushes an existing page.
@MainActor
private struct PopopxSettingsRowLink<Destination: View>: View {
    private let label: PopopxSettingsRowLabel
    private let enabled: Bool
    private let hint: String
    private let destination: () -> Destination

    /// `hint` is the VoiceOver line "Open": the settings tree keeps using this file's Chinese constants, while the upgraded
    /// `PopopxHelpView` goes by Keys, so it comes from the caller rather than this place deciding the wording for both pages.
    init(
        _ title: String,
        value: String? = nil,
        note: String? = nil,
        systemImage: String?,
        assetImage: String? = nil,
        tint: PopopxIconTint = .neutral,
        enabled: Bool = true,
        hint: String = Copy.openHint,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.label = PopopxSettingsRowLabel(
            title: title,
            value: value,
            note: note,
            systemImage: systemImage,
            assetImage: assetImage,
            tint: tint
        )
        self.enabled = enabled
        self.hint = hint
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            label
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityHint(Text(verbatim: hint))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A row that does not navigate and only does something (rating, open-source address, contacting the team, presenting a document).
/// It has no `hint` parameter: this row does not navigate in the first place, and `note` makes the destination clear by itself.
@MainActor
private struct PopopxSettingsActionButton: View {
    private let label: PopopxSettingsRowLabel
    private let enabled: Bool
    private let action: () -> Void

    init(
        _ title: String,
        value: String? = nil,
        note: String? = nil,
        systemImage: String,
        tint: PopopxIconTint = .neutral,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.label = PopopxSettingsRowLabel(
            title: title,
            value: value,
            note: note,
            systemImage: systemImage,
            tint: tint,
            showsChevron: false
        )
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A read-only row: no navigation, no button; the row end writes one true reading plus a status dot.
/// What brought it out this round is 'Network connection' -- that row was never an entry in `NetworkAndServers` but a stretch of reading
/// (type + online dot), and raising it here does not invent a destination that does not exist for it.
/// The whole row composes into a single VoiceOver element: the reading and the state go to `accessibilityValue` and to the title, not into a pile of fragments.
@MainActor
private struct PopopxNetworkStatusRow: View {
    let type: UserNetworkType
    let online: Bool

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            Image(systemName: symbol)
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxIconTint.neutral.ink)
                .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                .background(PopopxIconTint.neutral.fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                .accessibilityHidden(true)
            Text(PopopxNetworkCopy.connectionRow)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PopopxMetrics.spaceXS)
            Text(type.text)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
            Circle()
                .fill(online ? PopopxIconTint.success.fill : PopopxIconTint.danger.fill)
                .frame(width: PopopxMetrics.spaceXS, height: PopopxMetrics.spaceXS)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(PopopxNetworkCopy.connectionRow))
        .accessibilityValue(
            Text(type.text)
                + Text(verbatim: " · ")
                + Text(verbatim: online ? PopopxNetworkCopy.online : PopopxNetworkCopy.offline)
        )
    }

    /// The icon changes with the real link type: that type comes from the interface determination in `NetworkObserver.swift:44`,
    /// and so does the status dot -- no second "is there a network" calculation here.
    private var symbol: String {
        switch type {
        case .wifi: "wifi"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .ethernet: "cable.connector"
        case .other: "network"
        case .none: "wifi.slash"
        }
    }
}

/// The divider inside a card: a hairline `PopopxMetrics.divider` high, with `spaceXS` left above and below.
private struct PopopxSettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - Help and about (III.4: upgraded from a card in the settings tree into a real page)

/// The three destinations of the original helpCard are moved over exactly as they were, plus two more rows for the open-source address and the privacy policy.
/// The page is entered only from the 'Me' tab's frequent group and the settings tree no longer holds a second copy -- this page carries no `navigationTitle` of its own,
/// the title is given by the row that pushes it, which avoids writing the same wording in two places.
@MainActor
struct PopopxHelpView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.dismiss) private var dismiss

    @State private var toast = PopopxToastModel()
    /// The switch for the full privacy policy. Its type, Sheet, body text and onboarding screen 4 are verbatim the same one: `PopopxLegalDocumentSheet`
    /// is an offline built-in document; no web page is loaded here and no second copy of the body text is made.
    @State private var document: PopopxLegalDocumentSheet.Document?

    /// The repository address is a fact, not copy: this string enters no translation, and both places use the same constant.
    private static let repositoryURLString = "https://github.com/popopx-chat/popopx-chat"
    private static let repositoryURL = URL(string: PopopxHelpView.repositoryURLString)!

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                PopopxSectionCard {
                    PopopxSettingsRowLink(
                        PopopxHelpCopy.aboutRow,
                        systemImage: "info.circle",
                        hint: PopopxHelpCopy.openHint
                    ) {
                        POPOPXInfo(onboarding: false)
                            .navigationBarTitle(PopopxHelpCopy.aboutRow, displayMode: .inline)
                    }
                    PopopxSettingsDivider()
                    PopopxSettingsRowLink(
                        PopopxHelpCopy.versionRow,
                        value: appVersion.map { "v\($0)" },
                        systemImage: "number",
                        hint: PopopxHelpCopy.openHint
                    ) {
                        VersionView()
                            .navigationTitle(PopopxHelpCopy.versionRow)
                    }
                    PopopxSettingsDivider()
                    // 'How to use' and 'Recently updated' were deleted as rows on 2026-11-20: what the former pushes, `ChatHelp`, and what the latter pushes,
                    // `WhatsNewView`, are both still mounted on the old track (the message tab and the first-launch flow); this copy in the settings tree was a second entry,
                    // saying the same thing but with one level less context than the original page. The about/version/rate rows stay.
                    // Ruling 4: the 'Ask a question and make a suggestion' entry is hidden for now (popopxTeamURL currently points at the upstream default relay, not a POPOPX-owned server).
                    // It will be reopened once the official popopx channel is connected. The askTeam() function is kept; the button is commented out.
                    // PopopxSettingsActionButton(
                    //     Copy.askTeamRow,
                    //     note: Copy.askTeamNote,
                    //     systemImage: "envelope",
                    //     enabled: chatModel.chatRunning == true
                    // ) {
                    //     askTeam()
                    // }
                    // PopopxSettingsDivider()
                    PopopxSettingsActionButton(
                        PopopxHelpCopy.rateRow,
                        note: PopopxHelpCopy.rateNote,
                        systemImage: "star"
                    ) {
                        requestReview()
                    }
                    PopopxSettingsDivider()
                    repositoryRow
                    PopopxSettingsDivider()
                    // The privacy policy is a document, not a page, so this row draws no chevron: opening it shows a Sheet.
                    PopopxSettingsActionButton(
                        PopopxOnboardingCopy.privacyPolicy,
                        note: PopopxHelpCopy.privacyNote,
                        systemImage: "doc.text.fill"
                    ) {
                        PopopxHaptics.selection()
                        document = .privacy
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
        .background(PopopxPalette.base)
        .toolbarBackground(PopopxMaterial.bar, for: .navigationBar)
        .sheet(item: $document) { doc in
            PopopxLegalDocumentSheet(document: doc)
                .presentationDetents([.medium, .large])
        }
        .popopxToast(toast)
    }

    /// Open-source address: the whole row opens the system browser, and a copy key at the right end puts that same address string on the clipboard with a one-line receipt.
    /// The two actions are side-by-side siblings rather than hidden gestures (long-press/swipe gestures carry no hint at all in this family of rows).
    /// The slot at the row end is the address itself; the value of `PopopxSettingsRowLabel` takes at most two lines, so in a narrow language it may
    /// get truncated, and the copy key backs up the full value -- even if you cannot read it all, you can still take it.
    private var repositoryRow: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            Button(action: openRepository) {
                PopopxSettingsRowLabel(
                    title: PopopxHelpCopy.repositoryRow,
                    value: Self.repositoryURLString,
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    showsChevron: false
                )
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopopxPressButtonStyle())
            .accessibilityHint(Text(verbatim: PopopxHelpCopy.openInBrowserHint))

            Button(action: copyRepository) {
                Image(systemName: "doc.on.doc")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PopopxPressButtonStyle())
            .accessibilityLabel(Text(verbatim: PopopxHelpCopy.copyAddress))
        }
    }

    /// External links are the system browser's business (same convention as `UIApplication.shared.open` in PopopxCabinView.swift:2318 and
    /// `UIApplication.shared.open` in PopopxLocationPickerSheet.swift:763).
    private func openRepository() {
        PopopxHaptics.impact(.light)
        UIApplication.shared.open(Self.repositoryURL)
    }

    private func copyRepository() {
        UIPasteboard.general.string = Self.repositoryURLString
        PopopxHaptics.impact(.light)
        toast.show(PopopxHelpCopy.copiedAddress, kind: .success)
    }

    /// The rating is submitted by the system dialog; if no windowScene can be obtained it exits quietly instead of presenting a second hand-made sheet.
    /// This does not read `@EnvironmentObject var sceneDelegate` (the way old SettingsView.swift:309 and the HEAD line did):
    /// nowhere in the whole app is `SceneDelegate` injected into the environment (the only `.environmentObject(SceneDelegate())`
    /// is in this file's preview), and an unreadable environment object means a crash -- so the risk this row carried for a long time is not moved over with this page.
    /// It reads the existing static window handle instead (same convention as ThemeManager.swift:130-144 and POPOPXApp.swift:162).
    private func requestReview() {
        guard let scene = SceneDelegate.windowStatic?.windowScene else { return }
        SKStoreReviewController.requestReview(in: scene)
    }

    /// The team contact is the app's own link: a foreground `UIApplication.open` gets dropped by the system, so it still goes through the in-app connection flow
    /// (same convention as old SettingsView.swift:516-523; `popopxTeamURL` is at SettingsView.swift:23).
    /// It moved here along with the parked row above; this page is pushed onto the stack, so `dismiss()` now pops this page.
    private func askTeam() {
        dismiss()
        DispatchQueue.main.async {
            chatModel.appOpenUrl = popopxTeamURL
        }
    }
}

// MARK: - Display language (III.4: the only entry for the app's language)

/// iOS stores 'which language this one app uses' in the system settings; the app cannot change it itself and should not build its own language picker either.
/// So this page says only three things: which one is in use now, where to change it, and when it takes effect.
@MainActor
struct PopopxDisplayLanguageView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                PopopxSectionCard {
                    PopopxSettingsRowLabel(
                        title: PopopxLanguageCopy.currentRow,
                        value: PopopxSettingsValues.languageName,
                        systemImage: "character.bubble",
                        showsChevron: false
                    )
                    .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                    PopopxSettingsDivider()
                    // rows and rows inside a card have 0 spacing between them (`PopopxSectionCard`'s convention); the three body sentences and that one
                    // button need breathing room, so they form their own VStack rather than being scattered through the card.
                    VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                        Text(PopopxLanguageCopy.systemNote)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        PopopxButton(PopopxLanguageCopy.openSettings, systemImage: "gearshape") {
                            UIApplication.shared.open(appSettingsURL)
                        }
                        Text(PopopxLanguageCopy.relaunchNote)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
        .background(PopopxPalette.base)
        .toolbarBackground(PopopxMaterial.bar, for: .navigationBar)
    }
}

// MARK: - Copy

/// Every Chinese sentence on the page appears only once, here.
private enum Copy {
    static let pageTitle = NSLocalizedString("Settings", comment: "POPOPX settings tree")
    static let openHint = NSLocalizedString("Open", comment: "POPOPX settings tree")

    // Top
    static let legendOnline = NSLocalizedString("Online: over an SMP relay", comment: "POPOPX settings tree")
    static let legendMesh = NSLocalizedString("Offline: POPOPX Bluetooth mesh", comment: "POPOPX settings tree")
    static let legendNote = NSLocalizedString("Only one colour is used per row: you must be able to see at a glance which lane carried it.", comment: "POPOPX settings tree")

    // Appearance -- this group's card name and its two row phrasings came back to this page from the 'Me' tab on 2026-11-20 and switched to the English source sentence as Key
    // (see `PopopxGeneralCopy` below; the 16 directories already have translations). Only the six Chinese names of the themes themselves are kept here,
    // and `PopopxSettingsValues.themeName` reads exactly those at the row end -- they are values, not translatable UI wording.
    static let themeSystem = NSLocalizedString("Follow system", comment: "POPOPX settings tree")
    static let themeLight = NSLocalizedString("Light", comment: "POPOPX settings tree")
    static let themeDark = NSLocalizedString("Dark", comment: "POPOPX settings tree")
    static let themePopopx = "popopx"
    static let themeBlack = NSLocalizedString("Pure black", comment: "POPOPX settings tree")
    static let themeCustom = NSLocalizedString("Customize theme", comment: "POPOPX settings tree")

    // Privacy and security -- the whole card deleted 2026-11-20 (device round 6 II.2): these two toggles and
    // `PrivacySettings.swift:75`, `:88` are the same batch of state, and now sit directly on the 'Me' tab's defence card,
    // so their wording moved to the English Keys shared by those two pages (see `protectScreenRow` and the rest in `PopopxMeView.swift`).
    // No unmounted Chinese constant is left here at all.

    // Notifications and calls
    static let groupCalls = NSLocalizedString("Notifications and calls", comment: "POPOPX settings tree")
    static let notificationsRow = NSLocalizedString("Notifications", comment: "POPOPX settings tree")
    static let ntfsOff = NSLocalizedString("No server", comment: "POPOPX settings tree")
    static let ntfsPeriodic = NSLocalizedString("Periodic checks", comment: "POPOPX settings tree")
    static let ntfsInstant = NSLocalizedString("Instant notifications", comment: "POPOPX settings tree")
    static let callsRow = NSLocalizedString("Audio and video calls", comment: "POPOPX settings tree")
    static let relayCallsRow = NSLocalizedString("Force calls through a relay", comment: "POPOPX settings tree")
    static let relayCallsNoteOn = NSLocalizedString("A relay protects your IP address, but it can see how long a call lasts.", comment: "POPOPX settings tree")
    static let relayCallsNoteOff = NSLocalizedString("The relay is used only when it is necessary; the other side may see your IP address.", comment: "POPOPX settings tree")

    // Network and servers
    static let groupNetwork = NSLocalizedString("Network and servers", comment: "POPOPX settings tree")
    static let serversRow = NSLocalizedString("Relays and servers", comment: "POPOPX settings tree")
    static let networkFootnote = NSLocalizedString("Going back asks you once whether to save; if you do not save, the last core configuration stays in effect.", comment: "POPOPX settings tree")

    // Data and migration
    static let groupData = NSLocalizedString("Data and migration", comment: "POPOPX settings tree")
    static let chatDataRow = NSLocalizedString("Chat data", comment: "POPOPX settings tree")
    static let dataFootnote = NSLocalizedString("Retention, export and encryption are all here; a migration hands your entire device identity to another device, so do not quit midway.", comment: "POPOPX settings tree")
    static let migrateRow = NSLocalizedString("Migrate to another device", comment: "POPOPX settings tree")
    static let migrateRunning = NSLocalizedString("Migration in progress", comment: "POPOPX settings tree")

    // Help and about -- the whole card was upgraded into `PopopxHelpView` in 2026-11, and the title and description moved to that page's `PopopxHelpCopy`
    // English source sentences as Keys. Only the two strings of the row that ruling 4 has not ruled on remain here, so for now nothing mounts them (see
    // the row commented out in `PopopxHelpView`); the reopening step must first turn these two sentences into Keys,
    // and the Chinese constants are of no further use on that page.
    static let askTeamRow = NSLocalizedString("Questions and feedback", comment: "POPOPX settings tree")
    static let askTeamNote = NSLocalizedString("Connect to this account inside the app: no browser, no email.", comment: "POPOPX settings tree")
}

/// The three row phrasings that came back down to the settings tree from the 'Me' tab's frequent group in device round 6 II.1. Same convention as that page: **the English source sentence is the Key**.
/// Six of the seven are ready-made entries -- the whole block was moved over verbatim from `Copy` in `PopopxMeView.swift` without changing a word of the source,
/// so not a single translation had to change; the only addition is this group's card name. `en.lproj` is not written (an entry that cannot be read falls back to the Key itself, which is English).
private enum PopopxGeneralCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX settings tree")
    }

    /// Only this one is a Key added this round; all the rest are reused.
    static let groupAppearance = key("Appearance and language")
    static let appearanceRow = key("Appearance and icons")
    static let languageRow = key("Display language")
    /// Deliberately not named `"Chat preferences"`: that Key already belongs to another page in the 16 directories, and its Chinese value is
    /// 'chat preferences'. Reusing it would let somebody else decide this row's wording, so the source text is made unique (the same convention as the compute-point ecosystem).
    static let chatPreferences = key("Chat preferences for this identity")
    static let notifyOn = key("Notifications on")
    static let notifyOff = key("This identity is muted")
    /// The row-end VoiceOver hint: its Chinese value is 'Open', the same as the Chinese `Copy.openHint` above, so the wording is not split two ways.
    static let openHint = key("Open")
}

// MARK: - New copy for the 'Network and servers' card (the English source sentence is the Key)

/// The two rows raised up here in device round 8, task six. Same convention as `PopopxGeneralCopy`: **the English source sentence is the Key**,
/// and all five references here are ready-made entries -- they were originally the very words of those two sections in `NetworkAndServers.swift`, and moving the whole block up
/// changed not a word of the source, so not one of the 16 directories needs touching (`en.lproj` is not written; an entry that cannot be read falls back to the Key itself).
private enum PopopxNetworkCopy {
    /// Row title: the wording of the original row `Text("Advanced network settings")` (Chinese value 'Advanced network settings').
    static let advancedRow = NSLocalizedString("Advanced network settings", comment: "POPOPX settings tree")
    /// The pushed page's title: the `.navigationTitle("Advanced settings")` originally given to `AdvancedNetworkSettings`
    /// (Chinese value 'Advanced settings') -- the row and the page each keep their own sentence, verbatim the same as before the raise.
    static let advancedTitle = NSLocalizedString("Advanced settings", comment: "POPOPX settings tree")
    /// Status row title: the Section header `Text("Network connection")` of that original section (Chinese value 'Network connection').
    static let connectionRow = NSLocalizedString("Network connection", comment: "POPOPX settings tree")
    /// The status dot's VoiceOver reading: the link-type half is already a ready-made entry (`UserNetworkType.text`:
    /// "WiFi"/"Cellular"/"Wired ethernet"/"Other"/"No network connection"), so only online or not is added here
    /// (the Chinese values are exactly 'Online' and 'Offline', the same wording as those two rows of the top legend).
    static let online = NSLocalizedString("Online", comment: "POPOPX settings tree")
    static let offline = NSLocalizedString("Offline", comment: "POPOPX settings tree")
}

// MARK: - New copy for the two pages (the English source sentence is the Key)

/// The copy of `PopopxHelpView`. Same convention as the 'Me' tab: the English source sentence is the Key, and new entries are written into
/// `bg/cs/de/es/fi/fr/hu/it/ja/nl/pl/ru/th/tr/uk/zh-Hans`, all 16 directories; `en.lproj` is not written.
/// The `Copy` above is the settings tree's Chinese constant table, and this page no longer adds English sentences to it.
private enum PopopxHelpCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX help")
    }

    static let aboutRow = key("About popopx")
    /// Reuses an existing entry: this Key already has a translation in all 16 directories, and its Chinese value is exactly 'Version'.
    static let versionRow = key("Version and updates")
    /// The navigation row's VoiceOver hint: again reusing an existing entry (its Chinese value is exactly 'Open'),
    /// because this page, unlike the settings tree, has no Chinese constants in this file to borrow.
    static let openHint = NSLocalizedString("Open", comment: "Help: reuses the existing all-catalog term")
    static let rateRow = key("Rate the app")
    static let rateNote = key("The system shows this dialog only a few times a year. If nothing appears, nothing is broken.")
    static let repositoryRow = key("Source code")
    /// The privacy policy row's title takes `PopopxOnboardingCopy.privacyPolicy` directly: row and document title must be one and the same sentence verbatim.
    static let privacyNote = key("The full text is bundled with the app and opened here, offline.")
    static let openInBrowserHint = key("Opens in your browser")
    static let copyAddress = key("Copy address")
    static let copiedAddress = key("Repository address copied")
}

/// The copy of `PopopxDisplayLanguageView`, on the same Key convention.
private enum PopopxLanguageCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX display language")
    }

    static let currentRow = key("Current language")
    static let systemNote = key("iOS keeps the language of each app separately, in the system settings; POPOPX does not store it.")
    /// Reuses an existing entry: this Key already has a translation in all 16 directories.
    static let openSettings = NSLocalizedString("Open Settings", comment: "Display language: reuses the existing all-catalog term")
    static let relaunchNote = key("Close POPOPX and open it again for the new language to take effect.")
}

// MARK: - Previews

#if DEBUG
/// The canvas presents only this page's root view: those are the only two environments it reads itself. The sub-pages pushed into it additionally want the whole-app theme object,
/// which is a name that red-line list forbids on this page, and a fake one should not be made in the preview either -- so the preview does not cover the sub-pages.
struct PopopxSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxSettingsView(versionText: "7.1")
        }
        .environment(PopopxSettingsNavTrack())
        .environmentObject(ChatModel.shared)
    }
}

/// The two pages brought out by the upgrade. They need only `ChatModel` (the one injected at the app root): the rating row reads
/// `SceneDelegate.windowStatic`, not an environment object, so the canvas does not have to make a fake delegate.
struct PopopxHelpView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxHelpView()
                .navigationTitle("Help and about")
        }
        .environmentObject(ChatModel.shared)
    }
}

struct PopopxDisplayLanguageView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxDisplayLanguageView()
                .navigationTitle("Display language")
        }
    }
}
#endif
