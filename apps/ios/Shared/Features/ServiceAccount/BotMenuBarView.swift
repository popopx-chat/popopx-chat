//
//  BotMenuBarView.swift
//  POPOPX (iOS)
//
//  The service account's bottom second-level custom menu bar. A single row of at most 3 top-level menu buttons,
//  sized like the input bar's own panel row so it does not shift the layout. Tapping a button that has a `sub_menu` springs a
//  second-level popup upward over the bar (at most 5 sub-items). Each item performs its kind's action: `send_cmd` sends the
//  command text as a plain uplink line through the router (so it follows the app's dual-mode SMP/Bluetooth routing),
//  `open_url` asks the H5 launcher (the host passes `onOpenURL`), `open_channel` navigates via the injected callback.
//  One control collapses the bar back to the native keyboard (the one-tap switch the brief asks for); that is the injected `collapse` callback,
//  so the host stays the single owner of keyboard state.
//
//  ### Where this deviates from the brief, and why
//
//  1. **scancode / location / click_text are not reachable from this view.** The brief says to route them through the app's
//     existing composer path if one exists that can be verified. The existing composer path for location is `showLocationPicker`,
//     a private `@State` in `ComposeView` (`ComposeView.swift:401`, set at `:1240` and `:1533`); the send chain `popopxSendLocation`
//     (`ComposeView.swift:1611`) is a private method on the host. `ScanCodeView` is an SMP-connection crypto verification flow,
//     not a general QR scanner. `click_text` fills the composer's draft, but the mandated public API carries no draft binding.
//     This view therefore shows `PopopxEcoCopy.menuUnavailable` for all three kinds. Wiring them honestly would require a fourth
//     closure on the init (e.g. `onRequestLocation` / `onRequestScan` / `onFillComposer`) — that is the host's job.
//  2. **`PopopxEcoActionRunner.run` is card-scoped, not menu-scoped.** The runner takes a `PopopxServiceCard` and its own
//     `.sendCommand` case explicitly returns `.ignored` with the comment "A card carries commands only through a menu button; a
//     card action of this kind is a server that meant the menu layer." Menu items therefore go straight to `PopopxEcoRouter.shared`
//     (`send(_:toContactId:)` at `PopopxEcoRouterAndDeepLink.swift:486`, `sendCallback` at `:559`), which is the dual-mode uplink
//     the brief asks for.
//  3. **`PopopxEcoStore.liveMenu(for:)` mutates during body.** The store's public reader calls `loadIfNeeded()`, which writes
//     `cards` and `menus` on the first access; calling it from `body` would trip "Modifying state during view update". The bar
//     reads `ecoStore.menus[contactId]` directly (pure read, tracked by Observation) and falls back to the snapshot passed in
//     the init, and no host needs `loadIfNeeded()` to see a menu: that load restores cards only, never menus.
//  4. **`PopopxH5Launcher` is not called from this file.** The brief names `PopopxH5Launcher.shared.open(urlString:contactId:)`
//     but the existing router calls `PopopxH5Launcher.present(url:session:)` (`PopopxEcoRouterAndDeepLink.swift:795`), and the
//     host passes `onOpenURL` to keep one launcher call site. This view forwards the URL verbatim; the launcher, the session
//     check and the signing all belong to the host.
//  5. **A parent that carries both an action and sub-items.** WeChat's own rule is "a parent with children is view-only"; the
//     models file's `Item.isSane` does not reject the combination (`PopopxEcoModels.swift:386`). This bar folds the parent's
//     own action in as the first row of the popup, so it is reachable rather than silently dropped, but only when the server
//     sent fewer than `maximumSubItems` children — the 5-row ceiling is the reason the parent row is folded away away when the
//     server already sent 5 children.
//  6. **A third level of nesting.** The bar owns exactly two levels (the top row and one popup). A menu whose sub-item itself
//     carries sub-items would be a third level nobody can reach; the models file's own philosophy is "rejecting the whole menu
//     is better than rendering half of it" (`PopopxEcoModels.swift:385`), so this bar drops the whole menu in that case and
//     draws the plain/disabled row.
//  7. **`PopopxEcoMenu.Item.isSane` does not validate `view` URLs or `openChannel` payloads.** The card's `PopopxEcoAction.isSane`
//     calls `PopopxEcoAction.isHttpURL` and `PopopxChannelPublicURI.parse`; the menu item's `isSane` only checks presence. The
//     bar therefore re-validates both before calling the host's closures — a `javascript:` URL or a malformed channel URI is
//     treated as `.unreachable` and shows `menuUnavailable` rather than being forwarded.
//
//  ### Integration notes for the host
//
//  - The bar must not be mounted inside a view whose top edge is clipped: the second-level popup draws above the row via
//    `.alignmentGuide(.top) { $0.height }` and would be cut off otherwise.
//  - The host should hide the bar while the keyboard is visible, mirroring how `PopopxInputBar` lowers the keyboard when it
//    opens its own panel (`PopopxInputBar.swift:812`).
//  - The bar drains no `PopopxEcoStore.pendingNotice`; that belongs to the host (the router raises key-rotation notices, not
//     menu notices, and the bar has no toast surface for them).
//

import SwiftUI

// MARK: - Public API

/// The service account's bottom second-level custom menu bar.
///
/// The host owns navigation, web presentation and keyboard state; this view owns only the menu.
/// `onOpenURL` and `collapse` are required: only a host can present a page it does not own or dismiss one it did not show.
/// `onOpenChannel` alone has a fallback, because that one action this module can complete by itself (see the initializer).
struct BotMenuBarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let contactId: Int64
    private let menu: PopopxEcoMenu
    private let onOpenChannel: (String) -> Void
    private let onOpenURL: (String) -> Void
    private let collapse: () -> Void

    /// The live menu of THIS contact, read from the store during body so a newer menu_config frame replaces the row without the host re-mounting.
    /// Following the house precedent (PopopxCreditsStoreView.swift:82): `@State private var store = PopopxStoreKitManager.shared`.
    @State private var ecoStore = PopopxEcoStore.shared
    @State private var toast = PopopxToastModel()
    @State private var openParentID: String?
    @State private var inflightIDs: Set<String> = []

    init(
        menu: PopopxEcoMenu,
        contactId: Int64,
        onOpenChannel: ((String) -> Void)? = nil,
        onOpenURL: @escaping (String) -> Void,
        collapse: @escaping () -> Void
    ) {
        self.menu = menu
        self.contactId = contactId
        // The fallback is the same route a card button's `open_channel` takes (`PopopxEcoDeepLinkHandler.openChannel`), so a menu item
        // and a card button naming the same channel cannot end up with one working and one that only reports a failure. The hop is a
        // `Task` because the handler is `@MainActor` and this closure type is not.
        self.onOpenChannel = onOpenChannel ?? { text in
            Task { @MainActor in PopopxEcoDeepLinkHandler.openChannel(text) }
        }
        self.onOpenURL = onOpenURL
        self.collapse = collapse
    }

    var body: some View {
        let live = renderedMenu
        VStack(spacing: PopopxMetrics.space2XS) {
            Rectangle()
                .fill(PopopxPalette.separator)
                .frame(height: PopopxMetrics.divider)
            if let live {
                menuRow(live)
            } else {
                plainRow
            }
        }
        .padding(.horizontal, PopopxMetrics.spaceS)
        .padding(.top, PopopxMetrics.space2XS)
        .padding(.bottom, PopopxMetrics.space2XS)
        .overlay(alignment: .top) {
            BotMenuPopupLayer(
                toast: toast,
                rows: openRows(in: live),
                onSelect: { perform($0) }
            )
        }
        .popopxAnimation(PopopxSpring.snappy, value: openParentID, reduceMotion: reduceMotion)
        .onChange(of: live) { _, _ in closePopup() }
    }

    // MARK: - Menu rendering

    /// The menu this bar draws. nil = not renderable → the plain/disabled row.
    @MainActor private var renderedMenu: PopopxEcoMenu? {
        let candidate = ecoStore.menus[contactId] ?? menu
        guard candidate.isSane else { return nil }
        // The bar owns exactly two levels (PopopxEcoLimits.maximumSubItems); a third level would be unreachable, so drop the menu rather than render half of it.
        guard candidate.items.allSatisfy({ top in top.subItems.allSatisfy({ sub in sub.subItems.isEmpty }) }) else { return nil }
        return candidate
    }

    /// The rows to show in the popup for the currently open parent, if any.
    /// If the parent carries its own action AND the server sent fewer than the cap of children, the parent is folded in as the first row
    /// (so its action is reachable instead of silently dropped).
    private func openRows(in menu: PopopxEcoMenu?) -> [PopopxEcoMenu.Item] {
        guard let menu, let id = openParentID, let parent = menu.items.first(where: { $0.id == id }) else { return [] }
        var rows = parent.subItems
        if !rows.isEmpty, parent.action != nil, parent.payload != nil, rows.count < PopopxEcoLimits.maximumSubItems {
            rows.insert(parent, at: 0)
        }
        return rows
    }

    // MARK: - Row

    private func menuRow(_ menu: PopopxEcoMenu) -> some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: PopopxMetrics.spaceXS) {
                        ForEach(menu.items) { item in
                            menuKey(item, equalWidth: false)
                        }
                    }
                    .padding(.horizontal, PopopxMetrics.space2XS)
                }
                .scrollClipDisabled()
            } else {
                ForEach(menu.items) { item in
                    menuKey(item, equalWidth: true)
                }
            }
            collapseKey
        }
        .frame(minHeight: PopopxMetrics.minHitTarget)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: PopopxEcoCopy.menuBarLabel))
    }

    private func menuKey(_ item: PopopxEcoMenu.Item, equalWidth: Bool) -> some View {
        let hasSub = !item.subItems.isEmpty
        let isOpen = openParentID == item.id
        let busy = inflightIDs.contains(item.id)
        let canFire = (!busy && firing(of: item) != .unreachable) || hasSub
        return Button {
            tap(item)
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Text(verbatim: item.title)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1 : 2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if hasSub {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.up")
                        .font(PopopxType.microTag)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                }
            }
            .frame(maxWidth: equalWidth ? .infinity : nil, minHeight: PopopxMetrics.minHitTarget)
            .padding(.horizontal, PopopxMetrics.spaceS)
            .background(
                isOpen ? PopopxPalette.brand : PopopxPalette.card,
                in: .rect(cornerRadius: PopopxMetrics.radiusControl)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                    .strokeBorder(
                        isOpen ? Color.clear : PopopxPalette.hairlineInner,
                        lineWidth: PopopxMetrics.hairline
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
        .disabled(!canFire)
        .opacity(canFire ? 1 : 0.45)
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityHint(hasSub ? Text(verbatim: PopopxEcoCopy.menuBarOpenHaptics) : Text(verbatim: ""))
        .accessibilityIdentifier("popopx.botMenuBar.item.\(item.id)")
    }

    private var plainRow: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Text(verbatim: PopopxEcoCopy.menuBarLabel)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelHint)
            Spacer(minLength: PopopxMetrics.spaceXS)
            collapseKey
        }
        .frame(minHeight: PopopxMetrics.minHitTarget)
        .accessibilityLabel(Text(verbatim: PopopxEcoCopy.menuBarLabel))
    }

    private var collapseKey: some View {
        Button {
            PopopxHaptics.impact(.light)
            closePopup()
            collapse()
        } label: {
            Image(systemName: "keyboard")
                .font(PopopxType.sectionHeader)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
                .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
        .accessibilityLabel(Text(verbatim: PopopxEcoCopy.menuBarCollapse))
        .accessibilityIdentifier("popopx.botMenuBar.collapse")
    }

    // MARK: - Actions

    @MainActor private func tap(_ item: PopopxEcoMenu.Item) {
        PopopxHaptics.impact(.light)
        if !item.subItems.isEmpty {
            PopopxMotion.withAnimation(PopopxSpring.snappy, reduceMotion: reduceMotion) {
                openParentID = (openParentID == item.id) ? nil : item.id
            }
            return
        }
        perform(item)
    }

    @MainActor private func perform(_ item: PopopxEcoMenu.Item) {
        PopopxMotion.withAnimation(PopopxSpring.snappy, reduceMotion: reduceMotion) {
            openParentID = nil
        }
        switch firing(of: item) {
        case let .send(text):
            sendUplink(text, itemID: item.id, callback: false)
        case let .callback(text):
            sendUplink(text, itemID: item.id, callback: true)
        case let .url(u):
            onOpenURL(u)
        case let .channel(uri):
            onOpenChannel(uri)
        case .unreachable:
            receipt(PopopxEcoCopy.menuUnavailable, .danger)
        }
    }

    @MainActor private func sendUplink(_ text: String, itemID: String, callback: Bool) {
        guard !inflightIDs.contains(itemID) else { return }
        inflightIDs.insert(itemID)
        Task { @MainActor in
            let outcome = callback
                ? await PopopxEcoRouter.shared.sendCallback(payload: text, toContactId: contactId)
                : await PopopxEcoRouter.shared.send(text, toContactId: contactId)
            inflightIDs.remove(itemID)
            switch outcome {
            case .sent:
                receipt(PopopxEcoCopy.cardSent, .success)
            case .queuedOffline:
                receipt(PopopxEcoCopy.cardWaiting, .mesh)
            case .failed:
                receipt(PopopxEcoCopy.cardFailed, .danger)
                PopopxHaptics.notice(.error)
            }
        }
    }

    @MainActor private func receipt(_ text: String, _ kind: PopopxToastKind) {
        toast.show(PopopxToastMessage(text: text, kind: kind))
    }

    @MainActor private func closePopup() {
        PopopxMotion.withAnimation(PopopxSpring.snappy, reduceMotion: reduceMotion) {
            openParentID = nil
        }
    }

    // MARK: - Firing

    private enum Firing: Equatable {
        case send(String)
        case callback(String)
        case url(String)
        case channel(String)
        case unreachable
    }

    private func firing(of item: PopopxEcoMenu.Item) -> Firing {
        switch item.kind {
        case .scancode, .location:
            return .unreachable
        case .clickText:
            return .unreachable
        case .view:
            guard let url = item.url, PopopxEcoAction.isHttpURL(url) else { return .unreachable }
            return .url(url)
        case .click:
            guard let action = item.action else { return .unreachable }
            switch action {
            case .sendCommand:
                guard let payload = item.payload, isSingleLine(payload) else { return .unreachable }
                return .send(payload)
            case .callback:
                guard let payload = item.payload, isSingleLine(payload) else { return .unreachable }
                return .callback(payload)
            case .openURL:
                guard let url = item.url, PopopxEcoAction.isHttpURL(url) else { return .unreachable }
                return .url(url)
            case .openChannel:
                guard let payload = item.payload, PopopxChannelPublicURI.parse(payload) != nil else { return .unreachable }
                return .channel(payload)
            case .payCredits, .none:
                return .unreachable
            }
        }
    }

    private func isSingleLine(_ text: String) -> Bool {
        !text.isEmpty
            && text.count <= PopopxEcoLimits.maximumPayloadCharacters
            && !text.contains("\n") && !text.contains("\r")
    }
}

// MARK: - Popup layer

private struct BotMenuPopupLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let toast: PopopxToastModel
    let rows: [PopopxEcoMenu.Item]
    let onSelect: (PopopxEcoMenu.Item) -> Void

    private static let maxPopupHeight = PopopxMetrics.minHitTarget * CGFloat(PopopxEcoLimits.maximumSubItems)

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            if rows.isEmpty {
                if let message = toast.presented {
                    PopopxToastCapsule(message: message)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                submenuCard
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, PopopxMetrics.space2XS)
        .alignmentGuide(.top) { $0.height }
        .popopxAnimation(PopopxSpring.snappy, value: rows.map(\.id), reduceMotion: reduceMotion)
        .popopxAnimation(PopopxSpring.snappy, value: toast.presented, reduceMotion: reduceMotion)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var submenuCard: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, sub in
                    if index > 0 {
                        Rectangle()
                            .fill(PopopxPalette.separator)
                            .frame(height: PopopxMetrics.hairline)
                    }
                    submenuRow(sub)
                }
            }
        }
        .padding(.vertical, PopopxMetrics.space2XS)
        .frame(maxHeight: Self.maxPopupHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.cardHigh, in: .rect(cornerRadius: PopopxMetrics.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .popopxCardElevation(colorScheme: colorScheme)
    }

    private func submenuRow(_ sub: PopopxEcoMenu.Item) -> some View {
        Button {
            onSelect(sub)
        } label: {
            HStack(spacing: PopopxMetrics.spaceS) {
                Text(verbatim: sub.title)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: PopopxMetrics.spaceS)
                Image(systemName: glyph(for: sub))
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelSecondary)
            }
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
        .accessibilityLabel(Text(verbatim: sub.title))
    }

    private func glyph(for item: PopopxEcoMenu.Item) -> String {
        switch item.kind {
        case .scancode:
            return "qrcode"
        case .location:
            return "location.fill"
        case .clickText:
            return "text.cursor"
        case .view, .click:
            guard let action = item.action else { return "circle" }
            switch action {
            case .sendCommand:
                return "paperplane"
            case .callback:
                return "arrow.up"
            case .openURL:
                return "square.and.arrow.up"
            case .openChannel:
                return "link"
            case .payCredits, .none:
                return "circle"
            }
        }
    }
}
