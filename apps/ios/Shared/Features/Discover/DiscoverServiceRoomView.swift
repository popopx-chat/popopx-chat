//
//  DiscoverServiceRoomView.swift
//  POPOPX
//
//  The "service account" conversation the brief asks for.
//
//  It is deliberately NOT an SMP chat. A chat row needs a real peer, which only comes into
//  existence when the user connects the Mac's one-time invitation link; the app cannot invent
//  one, and picking a chat by guesswork would send control commands into a stranger's thread.
//  So the room is a local console over the SAME transport: commands leave through
//  `PopopxSilentSignalingRouter` to the contact the user attached during bonding, receipts
//  arrive through the same router's inbound recording, and the three menu buttons the brief
//  specifies sit where a chat puts its input bar.
//

import SwiftUI

// MARK: - Room

struct DiscoverServiceRoomView: View {
    let serviceId: PopopxNodeServiceId

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var data = DiscoverSubscriptionManager.shared
    @State private var toast = PopopxToastModel()
    @State private var runningAction: String?
    @State private var showsPairing = false
    @State private var showsTopUp = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { anchor in
                ScrollView {
                    VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                        PopopxDiscoverRoomHeader(
                            service: serviceId,
                            status: data.status(for: serviceId),
                            expiresAtMs: data.subscription(for: serviceId)?.expiresAtMs
                        )

                        if results.isEmpty {
                            PopopxDiscoverRoomEmpty(service: serviceId)
                                .padding(.top, PopopxMetrics.spaceL)
                        } else {
                            ForEach(results) { card in
                                PopopxNodeResultCardRow(card: card)
                                    .id(card.id)
                            }
                        }
                    }
                    .padding(.top, PopopxMetrics.spaceXS)
                    .padding(.bottom, PopopxMetrics.spaceM)
                }
                .background(PopopxPalette.base)
                .onChange(of: results.count) { _, count in
                    guard count > 0, let newest = results.first else { return }
                    PopopxMotion.withAnimation(PopopxSpring.fluid, reduceMotion: reduceMotion) {
                        anchor.scrollTo(newest.id, anchor: .top)
                    }
                }
            }
            .navigationTitle(serviceId.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PopopxPalette.labelSecondary)
                    }
                    .accessibilityLabel(DiscoverCopy.closeRoom)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PopopxDiscoverMenuBar(
                    service: serviceId,
                    enabled: canSend,
                    runningAction: runningAction,
                    onSend: sendTapped,
                    onPair: { showsPairing = true },
                    onTopUp: { showsTopUp = true }
                )
            }
        }
        .sheet(isPresented: $showsPairing) { MacNodePairingSheet() }
        .sheet(isPresented: $showsTopUp) { PopopxCreditsStoreView() }
        .popopxToast(toast)
        .onAppear { data.loadIfNeeded() }
    }

    private var results: [PopopxNodeResultCard] { data.results(for: serviceId) }

    /// A metered service has no window to be inside, so only the node link gates it.
    private var canSend: Bool {
        guard data.binding?.contactId != nil else { return false }
        return data.status(for: serviceId).isUsable
    }

    private func sendTapped(_ action: PopopxNodeMenuAction) {
        Task { await send(action) }
    }

    /// Sends, then reports. The receipt is the Mac's own answer, recorded in the room; the
    /// toast only says that SMP accepted the command, because "sent" and "done" are two
    /// different claims and conflating them is how a console ends up lying.
    private func send(_ action: PopopxNodeMenuAction) async {
        PopopxHaptics.impact(.light)
        runningAction = action.id
        let delivered = await data.dispatch(action)
        runningAction = nil
        toast.show(
            delivered ? DiscoverCopy.commandSent : DiscoverCopy.commandNotDelivered,
            kind: delivered ? .encrypted : .danger
        )
        PopopxHaptics.notice(delivered ? .success : .error)
    }
}

// MARK: - Header

struct PopopxDiscoverRoomHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    let service: PopopxNodeServiceId
    let status: PopopxDiscoverServiceStatus
    let expiresAtMs: Int64?

    var body: some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Image(systemName: service.symbol)
                .font(.system(size: 19))
                .foregroundStyle(PopopxPalette.brand)
                .frame(width: 38, height: 38)
                .background(PopopxPalette.brand.opacity(0.10), in: .rect(cornerRadius: PopopxMetrics.radiusControl))

            VStack(alignment: .leading, spacing: 3) {
                Text(service.tagline)
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: PopopxMetrics.spaceXS) {
                    PopopxDiscoverStatusBadge(status: status)
                    Text(expiryLine)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelHint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(PopopxMetrics.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .popopxCardElevation(colorScheme: colorScheme)
        .padding(.horizontal, PopopxMetrics.gutter)
    }

    private var expiryLine: String {
        switch service.cycleCost {
        case .usageBased:
            return DiscoverCopy.cycleMeteredLine
        case let .credits(price):
            guard let expiresAtMs, expiresAtMs > 0 else { return DiscoverCopy.cycleUnactivatedLine }
            let todayMs = Int64(Date().timeIntervalSince1970 * 1_000)
            let days = max(0, Int((expiresAtMs - todayMs) / 86_400_000))
            return String(format: DiscoverCopy.cycleDaysLeft, days)
                + " · "
                + String(format: DiscoverCopy.cyclePriceFormat, Int64(price))
        }
    }
}

// MARK: - Empty transcript

struct PopopxDiscoverRoomEmpty: View {
    let service: PopopxNodeServiceId

    var body: some View {
        PopopxSectionCard(nil) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                Label(DiscoverCopy.roomEmptyTitle, systemImage: "moon.stars")
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.label)
                Text(DiscoverCopy.roomEmptyHint)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(service.highlights, id: \.self) { highlight in
                    HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PopopxPalette.successInk)
                            .padding(.top, 2)
                        Text(highlight)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, PopopxMetrics.gutter)
    }
}

// MARK: - Result card

/// One answer from the Mac.
///
/// It renders the host's own vocabulary and nothing more: the flag the node printed, the
/// headline it wrote, the duration it measured, the body it attached. The headline stays as it
/// arrived rather than being re-titled, so what the user reads here is what the Mac logged —
/// a translated summary would be a second answer to "what did my machine say".
struct PopopxNodeResultCardRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let card: PopopxNodeResultCard

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
                Image(systemName: card.status.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(card.status == .succeeded ? PopopxPalette.successInk : PopopxPalette.dangerInk)
                    .padding(.top, 1)

                Text(card.headline)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: PopopxMetrics.spaceXS)

                Text(PopopxDiscoverTimestamp.string(fromMilliseconds: card.receivedAtMs))
                    .font(PopopxType.metricSmall)
                    .foregroundStyle(PopopxPalette.labelHint)
            }

            if !card.detail.isEmpty {
                Text(card.detail)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let duration = card.durationMilliseconds, duration > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text(String(format: DiscoverCopy.durationFormat, duration))
                        .font(PopopxType.metricSmall)
                }
                .foregroundStyle(PopopxPalette.labelHint)
            }

            HStack(spacing: 4) {
                Image(systemName: PopopxMacNodeVisual.bondedSymbol)
                    .font(.system(size: 9))
                Text(card.serviceId.nodeDisplayName)
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
        .padding(.horizontal, PopopxMetrics.gutter)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bottom menu

/// The service's three buttons, mounted at the bottom safe-area edge where a chat puts its
/// input bar.
struct PopopxDiscoverMenuBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let service: PopopxNodeServiceId
    let enabled: Bool
    let runningAction: String?
    let onSend: (PopopxNodeMenuAction) -> Void
    let onPair: () -> Void
    let onTopUp: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !enabled {
                PopopxDiscoverBlockedBar(service: service, onPair: onPair, onTopUp: onTopUp)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PopopxMetrics.spaceXS) {
                    ForEach(service.menuActions) { action in
                        PopopxDiscoverMenuButton(
                            action: action,
                            busy: runningAction == action.id,
                            enabled: enabled && runningAction == nil,
                            onSend: { onSend(action) }
                        )
                    }
                }
                .padding(.horizontal, PopopxMetrics.gutter)
                .padding(.vertical, PopopxMetrics.spaceS)
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PopopxPalette.separator)
                .frame(height: PopopxMetrics.hairline)
        }
        .animation(PopopxSpring.snappy, value: enabled)
    }
}

struct PopopxDiscoverMenuButton: View {
    let action: PopopxNodeMenuAction
    let busy: Bool
    let enabled: Bool
    let onSend: () -> Void

    var body: some View {
        Button(action: onSend) {
            HStack(spacing: 5) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PopopxPalette.brand)
                } else {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(action.title)
                    .font(PopopxType.meta)
                    .lineLimit(1)
            }
            .foregroundStyle(enabled ? PopopxPalette.brand : PopopxPalette.labelHint)
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(height: 34)
            .background(enabled ? PopopxPalette.brand.opacity(0.10) : Color.clear, in: .capsule)
            .overlay(Capsule().strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline))
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(!enabled || busy)
        .accessibilityHint(DiscoverCopy.menuButtonHint)
    }
}

/// The strip that replaces the buttons when a command could not possibly go anywhere. Its one
/// action is the fix for the cause that is actually showing: an unbonded machine is repaired by
/// the pairing sheet, an unpaid service by the top-up page.
struct PopopxDiscoverBlockedBar: View {
    let service: PopopxNodeServiceId
    let onPair: () -> Void
    let onTopUp: () -> Void

    @State private var data = DiscoverSubscriptionManager.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PopopxPalette.dangerInk)
                Text(blockerCopy)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: PopopxMetrics.spaceXS)
                Text(actionTitle)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.brand)
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.vertical, PopopxMetrics.spaceXS)
            .background(PopopxPalette.danger.opacity(0.06))
        }
        .buttonStyle(.plain)
        .accessibilityHint(actionTitle)
    }

    private var needsCredits: Bool {
        if case .awaitingBalance = data.status(for: service) { return true }
        return false
    }

    private var action: () -> Void { needsCredits ? onTopUp : onPair }

    private var actionTitle: String { needsCredits ? DiscoverCopy.goToTopUp : DiscoverCopy.noNodeAction }

    /// Three different failures, one sentence each, chosen by the state rather than by the
    /// caller: never bonded, bonded without a chat, and simply out of paid time read
    /// differently, and only two of them are fixed by scanning again.
    private var blockerCopy: String {
        if data.binding == nil { return DiscoverCopy.roomNeedsBonding }
        if data.binding?.contactId == nil { return DiscoverCopy.roomNeedsChat }
        return needsCredits ? DiscoverCopy.roomNeedsCredits : DiscoverCopy.roomNeedsActivation
    }
}

// MARK: - Timestamps

enum PopopxDiscoverTimestamp {
    /// Today at HH:mm, otherwise the short date. A console of receipts is read in order, so
    /// the time of day matters more than the day itself until the receipt is older than today.
    static func string(fromMilliseconds milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - Copy

extension DiscoverCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "discover service room")
    }

    static let closeRoom = key("Close")
    static let durationFormat = key("%lld ms")
    static let commandSent = key("Command sent to your Mac")
    static let commandNotDelivered = key("The command could not be delivered")
    static let menuButtonHint = key("Sends this request to your paired Mac")
    static let roomNeedsBonding = key("No Mac node bonded yet")
    static let roomNeedsChat = key("Bonded, but no chat to send through")
    static let roomNeedsActivation = key("This service is not active")
    static let roomNeedsCredits = key("The paid time ran out. Add Compute Credits to resume.")
    static let cycleMeteredLine = key("Metered by the task")
    static let cycleUnactivatedLine = key("Not activated")
    static let cycleDaysLeft = key("%lld days left")
}
