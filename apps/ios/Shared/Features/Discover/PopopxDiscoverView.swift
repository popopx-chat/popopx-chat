//
//  PopopxDiscoverView.swift
//  POPOPX (iOS / Shared)
//
//  The third tab: the Mac node banner and the three-shelf bento plaza of the ten official
//  service accounts.
//
//  Three layout facts worth keeping next to the code that depends on them:
//
//  * The navigation stack belongs to the host. `MainTabView` already wraps this view in its
//    `NavigationStack`, so the body starts at the `ScrollView` and the title, display mode and
//    `.refreshable` attach there — the same shape `PopopxContactsView` uses. A second stack
//    inside this view stacked two nav bars on top of each other, which is why Discover was the
//    only tab of the five that did it: Chats (`ChatsListView`) and Cabin (`PopopxCabinView`)
//    build their own stack and the shell leaves them alone, Contacts and Me let the shell own it.
//  * The plaza deliberately does **not** use `PopopxSectionCard` for the shelves. That atom
//    is a single-column grouped list, and its `VStack(spacing: 0)` row stack is the right
//    shape for settings and the wrong shape for six cards a user scans for an icon. The
//    plaza borrows its visual language instead — same `radiusCard`, same `card` fill, same
//    hairline, same `PopopxType` ramp — so a bento tile and a settings card are unmistakably
//    one family. `PopopxSectionCard` still wraps the one genuinely list-shaped block on this
//    screen: the section footers.
//  * The grid is two columns and never adaptive. `GridItem(.adaptive(minimum: 168))` gives
//    three columns on an iPad and *one* column in a 320 pt Split View, which would make the
//    same service cost a different amount of scrolling depending on how Spaces happens to be
//    arranged. Two columns is the one count that holds from iPhone SE to iPad Pro, and the
//    tiles are built for that width.
//

import SwiftUI

// MARK: - Plaza

struct PopopxDiscoverView: View {
    @State private var data = DiscoverSubscriptionManager.shared
    @State private var credits = PopopxCreditsManager.shared
    @State private var filter: PopopxDiscoverFilter = .all
    @State private var search = ""
    @State private var detailService: PopopxNodeServiceId?
    @State private var showsPairing = false
    @State private var showsAssistant = false
    @FocusState private var searchFocused: Bool

    private let columns = [
        GridItem(.flexible(), spacing: PopopxMetrics.spaceS),
        GridItem(.flexible(), spacing: PopopxMetrics.spaceS)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                PopopxDiscoverBanner { showsPairing = true }

                PopopxDiscoverAssistantEntry { showsAssistant = true }

                PopopxDiscoverSearchField(text: $search, focused: $searchFocused)

                PopopxDiscoverFilterBar(selection: $filter, counts: data.activeCountByFilter)

                if visibleSections.isEmpty {
                    PopopxDiscoverEmptyState(searching: !search.trimmingCharacters(in: .whitespaces).isEmpty)
                        .padding(.top, PopopxMetrics.spaceXL)
                } else {
                    ForEach(visibleSections) { shelf in
                        PopopxDiscoverShelf(
                            section: shelf.section,
                            services: shelf.services,
                            columns: columns
                        ) { service in
                            detailService = service
                        }
                    }
                    Text(DiscoverCopy.serviceSectionFooter)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelHint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, PopopxMetrics.gutter)
                        .padding(.top, PopopxMetrics.space2XS)
                }
            }
            .padding(.bottom, PopopxMetrics.spaceXL)
        }
        .background(PopopxPalette.base)
        .navigationTitle(DiscoverCopy.plazaTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbarTitleDisplayMode(.large)
        .refreshable { data.sweep() }
        .sheet(item: $detailService) { service in
            DiscoverServiceDetailSheet(serviceId: service)
        }
        .sheet(isPresented: $showsPairing) {
            MacNodePairingSheet()
        }
        .sheet(isPresented: $showsAssistant) {
            PopopxCopilotAssistantView()
        }
        .onAppear {
            credits.loadIfNeeded()
            data.loadIfNeeded()
        }
    }

    /// Sections that still hold something after the filter and the search. An empty shelf
    /// would print a heading over nothing, which reads as a bug in the catalogue.
    private var visibleSections: [PopopxDiscoverShelfModel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return PopopxDiscoverSection.allCases.compactMap { section in
            guard filter.matches(section) else { return nil }
            let services = PopopxNodeServiceId.grouped(section).filter { service in
                query.isEmpty || service.matchesSearch(query)
            }
            return services.isEmpty ? nil : PopopxDiscoverShelfModel(section: section, services: services)
        }
    }
}

// MARK: - Node banner

/// The one place on this tab that says whether a Mac is reachable at all.
///
/// It is a button rather than a status row because the useful next action is always the
/// same: open the bonding sheet. A banner that cannot be tapped would make the user hunt
/// for the entry point in the tab bar.
struct PopopxDiscoverBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var data = DiscoverSubscriptionManager.shared

    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: PopopxMetrics.spaceS) {
                Image(systemName: PopopxMacNodeVisual.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: .rect(cornerRadius: PopopxMetrics.radiusControl))

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(1)
                    Text(subheadline)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: PopopxMetrics.spaceXS)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PopopxPalette.labelHint)
            }
            .padding(PopopxMetrics.spaceS)
            .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                    .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            )
            .popopxCardElevation(colorScheme: colorScheme)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.top, PopopxMetrics.spaceXS)
    }

    private var binding: PopopxMacNodeBinding? { data.binding }

    private var isConnected: Bool { binding?.handshakeConfirmed == true && binding?.contactId != nil }

    private var tint: Color {
        if isConnected { return PopopxPalette.meshInk }
        return binding == nil ? PopopxPalette.labelHint : PopopxPalette.brand
    }

    private var headline: String {
        guard let binding else { return DiscoverCopy.noNodeTitle }
        let label = binding.deviceLabel.isEmpty
            ? (binding.contactDisplayName?.isEmpty == false ? binding.contactDisplayName! : DiscoverCopy.defaultNodeName)
            : binding.deviceLabel
        return isConnected ? DiscoverCopy.nodeConnected(label) : label
    }

    private var subheadline: String {
        guard let binding else { return DiscoverCopy.pairingIntro }
        if binding.contactId == nil { return DiscoverCopy.bannerNeedsChat }
        return isConnected ? DiscoverCopy.bannerReady : DiscoverCopy.nodeIdle
    }
}

// MARK: - Assistant entry

/// 「发现 → 我的私人助理」: the one door into the on-device assistant from outside a conversation.
///
/// It sits directly under the node banner rather than inside a shelf because it is not a service. The
/// ten shelf tiles are things the user pays credits to run on a Mac; this is a thing that runs on the
/// phone, reads the phone's own calendar, and costs nothing — putting it in a shelf would tell the user
/// it bills like the others.
///
/// A button, for the same reason the banner is one: the row's only job is to open the sheet, and a row
/// that only reports state would leave the settings inside it unreachable from here.
struct PopopxDiscoverAssistantEntry: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var copilot: PopopxCopilotModel

    private let action: () -> Void

    @MainActor
    init(action: @escaping () -> Void) {
        _copilot = ObservedObject(wrappedValue: PopopxCopilotModel.shared)
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: PopopxMetrics.spaceS) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: .rect(cornerRadius: PopopxMetrics.radiusControl))

                VStack(alignment: .leading, spacing: 2) {
                    Text(PopopxCopilotCopy.entryTitle)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(1)
                    Text(copilot.showsLiveIndicator ? PopopxCopilotCopy.liveIndicator : PopopxCopilotCopy.entrySubtitle)
                        .font(PopopxType.caption)
                        .foregroundStyle(copilot.showsLiveIndicator ? PopopxPalette.successInk : PopopxPalette.labelSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: PopopxMetrics.spaceXS)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PopopxPalette.labelHint)
            }
            .padding(PopopxMetrics.spaceS)
            .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                    .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            )
            .popopxCardElevation(colorScheme: colorScheme)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    /// Green only while the real-time assist is genuinely on, which is the state the row would be lying
    /// about if it were a permanent brand color.
    private var tint: Color { copilot.showsLiveIndicator ? PopopxPalette.successInk : PopopxPalette.brand }
}

// MARK: - Search

/// The search box, which is a control rather than a `.searchable` modifier on purpose:
/// `.searchable` on a tab that lives inside a `TabView` hands the field to the navigation
/// bar and pushes the bar's own title into the scroll area on compact widths, and this
/// screen's header carries the balance, which must not scroll away behind it.
struct PopopxDiscoverSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PopopxPalette.labelHint)
            TextField(DiscoverCopy.searchPrompt, text: $text)
                .font(PopopxType.body)
                .foregroundStyle(PopopxPalette.label)
                .focused(focused)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(PopopxPalette.labelHint.opacity(0.9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(DiscoverCopy.clearSearch)
            }
        }
        .padding(.horizontal, PopopxMetrics.spaceS)
        .frame(height: 38)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .padding(.horizontal, PopopxMetrics.gutter)
    }
}

// MARK: - Filter bar

/// One chip row: all, then the three shelves.
///
/// The counts come from `DiscoverSubscriptionManager.activeCountByFilter` — a shelf that holds
/// nothing is not the user's problem to discover, but a shelf that holds three running
/// services is worth showing a number on.
struct PopopxDiscoverFilterBar: View {
    @Binding var selection: PopopxDiscoverFilter
    let counts: [PopopxDiscoverFilter: Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                ForEach(PopopxDiscoverFilter.allCases) { filter in
                    PopopxDiscoverFilterChip(
                        title: filter.title,
                        count: counts[filter],
                        selected: selection == filter
                    ) {
                        selection = filter
                    }
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DiscoverCopy.filterBarLabel)
    }
}

struct PopopxDiscoverFilterChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let count: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(PopopxType.meta)
                    .foregroundStyle(selected ? PopopxPalette.onBrand : PopopxPalette.labelSecondary)
                if let count {
                    Text("\(count)")
                        .font(PopopxType.metricSmall)
                        .foregroundStyle(selected ? PopopxPalette.onBrand.opacity(0.8) : PopopxPalette.labelHint)
                }
            }
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(height: 30)
            .background(selected ? PopopxPalette.brand : PopopxPalette.card, in: .capsule)
            .overlay(Capsule().strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline))
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: .rigid))
        .popopxAnimation(PopopxSpring.snappy, value: selected, reduceMotion: reduceMotion)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Shelf

struct PopopxDiscoverShelfModel: Identifiable {
    let section: PopopxDiscoverSection
    let services: [PopopxNodeServiceId]

    var id: String { section.rawValue }
}

struct PopopxDiscoverShelf: View {
    let section: PopopxDiscoverSection
    let services: [PopopxNodeServiceId]
    let columns: [GridItem]
    let open: (PopopxNodeServiceId) -> Void

    @State private var data = DiscoverSubscriptionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PopopxPalette.labelSecondary)
                Text(section.title)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PopopxMetrics.gutter)

            LazyVGrid(columns: columns, spacing: PopopxMetrics.spaceS) {
                ForEach(services) { service in
                    PopopxDiscoverServiceCard(service: service, status: data.status(for: service)) {
                        open(service)
                    }
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
        }
    }
}

// MARK: - Service tile

struct PopopxDiscoverServiceCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let service: PopopxNodeServiceId
    let status: PopopxDiscoverServiceStatus
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
                    Image(systemName: service.symbol)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(PopopxPalette.brand)
                        .frame(width: 30, height: 30)
                        .background(PopopxPalette.brand.opacity(0.10), in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                    Spacer(minLength: 0)
                    PopopxDiscoverStatusBadge(status: status)
                }

                Text(service.title)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)

                Text(service.tagline)
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 4) {
                    Text(service.cycleCost.priceLabel)
                        .font(PopopxType.metricSmall)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 9, weight: .semibold))
                    Text(DiscoverCopy.edgeBadge)
                        .font(PopopxType.microTag)
                }
                .foregroundStyle(PopopxPalette.meshInk)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(PopopxPalette.mesh.opacity(0.12), in: .capsule)
            }
            .padding(PopopxMetrics.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                    .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            )
            .popopxCardElevation(colorScheme: colorScheme)
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: .light))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(DiscoverCopy.openServiceHint)
    }
}

struct PopopxDiscoverStatusBadge: View {
    let status: PopopxDiscoverServiceStatus

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
            Text(status.label)
                .font(PopopxType.microTag)
                .foregroundStyle(inkColor)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(fillColor.opacity(0.12), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.accessibilityLabel)
    }

    /// The three states that matter at a glance are "running", "needs something" and
    /// "nothing yet". Everything else the badge says in words, so the dot only ever carries
    /// those three meanings and never becomes a legend the user has to learn.
    private var tone: PopopxDiscoverBadgeTone {
        switch status {
        case .active, .metered: .running
        case .expiringToday: .warning
        case .awaitingBalance, .expired: .attention
        case .notActivated: .neutral
        }
    }

    private var dotColor: Color {
        switch tone {
        case .running: PopopxPalette.success
        case .warning: PopopxPalette.brand
        case .attention: PopopxPalette.danger
        case .neutral: PopopxPalette.labelHint
        }
    }

    private var inkColor: Color {
        switch tone {
        case .running: PopopxPalette.successInk
        case .warning: PopopxPalette.brand
        case .attention: PopopxPalette.dangerInk
        case .neutral: PopopxPalette.labelSecondary
        }
    }

    private var fillColor: Color {
        switch tone {
        case .running: PopopxPalette.success
        case .warning: PopopxPalette.brand
        case .attention: PopopxPalette.danger
        case .neutral: PopopxPalette.separator
        }
    }
}

// MARK: - Empty state

struct PopopxDiscoverEmptyState: View {
    let searching: Bool

    var body: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            Image(systemName: searching ? "magnifyingglass" : "square.dashed")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(PopopxPalette.labelHint)
            Text(searching ? DiscoverCopy.noResultsTitle : DiscoverCopy.noResultsFilter)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.label)
                .multilineTextAlignment(.center)
            Text(DiscoverCopy.noResultsHint)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PopopxMetrics.spaceL)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Filter model

/// The plaza filter. `all` is a case rather than `nil` so that `Picker`, the count map and
/// the restored scroll position all speak one type.
enum PopopxDiscoverFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case productivity
    case compute
    case sanctuary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: DiscoverCopy.allFilter
        case .productivity: PopopxDiscoverSection.productivity.filterTitle
        case .compute: PopopxDiscoverSection.compute.filterTitle
        case .sanctuary: PopopxDiscoverSection.sanctuary.filterTitle
        }
    }

    func matches(_ section: PopopxDiscoverSection) -> Bool {
        switch self {
        case .all: true
        case .productivity: section == .productivity
        case .compute: section == .compute
        case .sanctuary: section == .sanctuary
        }
    }
}

enum PopopxDiscoverBadgeTone: Hashable {
    case running, warning, attention, neutral
}

// MARK: - Shared visuals

/// The node's own iconography, in one place, because the banner, the pairing sheet and the
/// service room all have to say "this runs on the Mac" with the same glyph.
enum PopopxMacNodeVisual {
    static let symbol = "desktopcomputer"
    static let bondedSymbol = "cable.connector"
    static let cameraSymbol = "qrcode.viewfinder"
}

extension PopopxNodeServiceId {
    /// Search matches the plaza name, the catalogue name the Mac itself prints, the one-line
    /// description and the service id. Matching `nodeDisplayName` is what lets a user who has
    /// already read a result card find the tile that produced it.
    func matchesSearch(_ query: String) -> Bool {
        let needle = query.lowercased()
        return title.lowercased().contains(needle)
            || nodeDisplayName.lowercased().contains(needle)
            || tagline.lowercased().contains(needle)
            || rawValue.lowercased().replacingOccurrences(of: "_", with: " ").contains(needle)
            || menuActions.contains { $0.title.lowercased().contains(needle) }
    }
}

extension DiscoverCopy {
    static let bannerReady = NSLocalizedString("Ready for the menu buttons below", comment: "discover banner")
    static let bannerNeedsChat = NSLocalizedString("Bonded, but no conversation is attached yet", comment: "discover banner")
    static let defaultNodeName = NSLocalizedString("Mac node", comment: "discover banner fallback name")
    static let clearSearch = NSLocalizedString("Clear search", comment: "discover search")
    static let filterBarLabel = NSLocalizedString("Filter services", comment: "discover filter bar")
    static let noResultsFilter = NSLocalizedString("No service in this shelf", comment: "discover empty shelf")
    static let openServiceHint = NSLocalizedString("Opens the service details", comment: "discover accessibility hint")
}

extension PopopxDiscoverServiceStatus {
    /// Spoken rather than visual: "Expiring today" and "Running · auto-renew" mean nothing to
    /// a VoiceOver reader as a coloured dot, and the dot is the only thing the badge adds.
    var accessibilityLabel: String {
        switch self {
        case .notActivated: NSLocalizedString("Not activated", comment: "discover badge spoken")
        case .active: NSLocalizedString("Running, auto-renew on", comment: "discover badge spoken")
        case .expiringToday: NSLocalizedString("Running, expires today", comment: "discover badge spoken")
        case .awaitingBalance: NSLocalizedString("Waiting for Compute Credits", comment: "discover badge spoken")
        case .expired: NSLocalizedString("Stopped", comment: "discover badge spoken")
        case .metered: NSLocalizedString("Charged per job", comment: "discover badge spoken")
        }
    }
}
