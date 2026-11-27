//
//  DiscoverServiceDetailSheet.swift
//  POPOPX
//
//  The service detail and subscription panel: the one screen where a 30-day price is agreed
//  to. Three rules shape it:
//
//  1. **The number the user confirms is the number that is charged.** The price, the cycle
//     length and the date the next renewal will happen are all read from
//     `PopopxNodeServiceId.cycleCost` and the stored row, never restated in prose, so this
//     sheet and `DiscoverSubscriptionManager.sweep()` cannot disagree about what a month costs.
//     A user who has read this page knows the exact sentence the renewal ledger row will
//     write, because it is the same sentence.
//  2. **Activation only ever spends credits already in the wallet.** When the balance is short
//     the CTA turns into the top-up page instead of charging anything, because the money has
//     to leave through StoreKit on a screen the user chose, not as a side effect of enabling a
//     service (requirement, module 2 item 2).
//  3. **`autoRenew` defaults to off.** An auto-renewing service that quietly takes credits
//     every 30 days has to be a decision, not a discovered state. The switch is off until the
//     user turns it on, and the sheet says in one line what turning it on permits.
//

import SwiftUI

// MARK: - Sheet

struct DiscoverServiceDetailSheet: View {
    let serviceId: PopopxNodeServiceId

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var data = DiscoverSubscriptionManager.shared
    @State private var credits = PopopxCreditsManager.shared
    @State private var toast = PopopxToastModel()
    @State private var showsTopUp = false
    @State private var showsRoom = false
    @State private var showsStopConfirmation = false
    @State private var activating = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                    PopopxSectionCard(nil) {
                        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                            Text(PopopxCommerceCopy.creditsBalance)
                                .font(PopopxType.caption)
                                .foregroundStyle(PopopxPalette.labelSecondary)
                            Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, credits.balance))
                                .font(PopopxType.title)
                                .foregroundStyle(PopopxPalette.label)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, PopopxMetrics.spaceXS)
                        divider
                        PopopxDiscoverDetailHero(service: serviceId, status: status)
                    }

                    highlightsCard

                    billingCard

                    if subscription == nil {
                        PopopxDiscoverDetailMenuCard(service: serviceId)
                    } else {
                        autoRenewCard
                        PopopxDiscoverDetailMenuCard(service: serviceId)
                        historyCard
                    }

                    actions
                }
                .padding(.top, PopopxMetrics.spaceXS)
                .padding(.bottom, PopopxMetrics.space2XL)
            }
            .background(PopopxPalette.base)
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
        }
        .sheet(isPresented: $showsTopUp) { PopopxCreditsStoreView() }
        .sheet(isPresented: $showsRoom) { DiscoverServiceRoomView(serviceId: serviceId) }
        .presentationDetents([.large])
        .confirmationDialog(
            DiscoverCopy.confirmStop,
            isPresented: $showsStopConfirmation,
            titleVisibility: .visible
        ) {
            Button(DiscoverCopy.stopAction, role: .destructive) { stop() }
            Button(DiscoverCopy.keepAction, role: .cancel) {}
        } message: {
            Text(DiscoverCopy.stopBody(serviceId.title))
        }
        .popopxToast(toast)
        .onAppear { data.loadIfNeeded() }
    }

    private var subscription: PopopxDiscoverSubscription? { data.subscription(for: serviceId) }

    private var status: PopopxDiscoverServiceStatus { data.status(for: serviceId) }

    // MARK: Cards

    private var highlightsCard: some View {
        PopopxSectionCard(DiscoverCopy.detailHighlightsTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                ForEach(Array(serviceId.highlights.enumerated()), id: \.offset) { _, highlight in
                    HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PopopxPalette.successInk)
                            .padding(.top, 2)
                        Text(highlight)
                            .font(PopopxType.secondary)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The billing terms, spelled out before the user agrees to any of them, and read from
    /// `cycleCost` rather than restated so this card and the charge cannot drift apart.
    private var billingCard: some View {
        PopopxSectionCard(DiscoverCopy.detailBillingTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                switch serviceId.cycleCost {
                case let .credits(amount):
                    PopopxDiscoverDetailFactRow(
                        label: DiscoverCopy.detailPriceLabel,
                        value: String(format: DiscoverCopy.cyclePriceFormat, Int64(amount)),
                        emphasised: true
                    )
                    PopopxDiscoverDetailFactRow(
                        label: DiscoverCopy.detailCycleLabel,
                        value: DiscoverCopy.detailCycleLength
                    )
                    if let subscription, subscription.expiresAtMs > 0 {
                        PopopxDiscoverDetailFactRow(
                            label: DiscoverCopy.detailEndsLabel,
                            value: DiscoverCopy.expiry(subscription.expiresAt)
                        )
                        if subscription.autoRenew {
                            PopopxDiscoverDetailFactRow(
                                label: DiscoverCopy.detailRenewsLabel,
                                value: DiscoverCopy.expiry(
                                    subscription.expiresAt.addingTimeInterval(PopopxDiscoverClock.cycleSeconds)
                                )
                            )
                        }
                    }
                case .usageBased:
                    PopopxDiscoverDetailNote(
                        text: DiscoverCopy.detailMeteredBody,
                        systemImage: "scalemass"
                    )
                }
                PopopxDiscoverDetailNote(
                    text: DiscoverCopy.autoRenewExplanation,
                    systemImage: "lock.shield"
                )
            }
        }
    }

    private var autoRenewCard: some View {
        PopopxSectionCard(DiscoverCopy.detailRenewalTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                Toggle(
                    isOn: autoRenewBinding,
                    label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DiscoverCopy.autoRenewTitle)
                                .font(PopopxType.sectionHeader)
                                .foregroundStyle(PopopxPalette.label)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(DiscoverCopy.autoRenewFootnote)
                                .font(PopopxType.caption)
                                .foregroundStyle(PopopxPalette.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                )
                .tint(PopopxPalette.brand)

                if let subscription, subscription.autoRenew {
                    PopopxDiscoverDetailNote(
                        text: DiscoverCopy.nextRenewal(
                            DiscoverCopy.expiry(subscription.expiresAt),
                            creditsRequired
                        ),
                        systemImage: "arrow.clockwise.circle"
                    )
                }
            }
        }
    }

    private var historyCard: some View {
        PopopxSectionCard(DiscoverCopy.detailHistoryTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                PopopxDiscoverDetailFactRow(
                    label: DiscoverCopy.detailCyclesLabel,
                    value: DiscoverCopy.cyclesPaid(subscription?.cyclesPaid ?? 0)
                )
                PopopxDiscoverDetailFactRow(
                    label: DiscoverCopy.detailEntriesLabel,
                    value: DiscoverCopy.entryCount(data.results(for: serviceId).count)
                )
                Text(DiscoverCopy.detailHistoryHint)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            switch serviceId.cycleCost {
            case .usageBased:
                PopopxButton(DiscoverCopy.activateMetered, systemImage: PopopxMacNodeVisual.symbol, role: .primary) {
                    showsRoom = true
                }
            case let .credits(amount):
                if subscription == nil {
                    PopopxButton(
                        DiscoverCopy.activate(amount),
                        systemImage: "checkmark.circle",
                        role: .primary,
                        isLoading: activating,
                        action: activate
                    )
                    if credits.balance < amount {
                        PopopxButton(DiscoverCopy.goToTopUp, systemImage: "plus", role: .secondary) {
                            showsTopUp = true
                        }
                    }
                } else {
                    PopopxButton(DiscoverCopy.detailOpenRoom, systemImage: "arrow.up.forward.app", role: .primary) {
                        showsRoom = true
                    }
                    PopopxButton(
                        DiscoverCopy.stopService,
                        systemImage: "pause.circle",
                        role: .destructive,
                        fullWidth: true
                    ) {
                        showsStopConfirmation = true
                    }
                }
            }
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.top, PopopxMetrics.spaceXS)
    }

    private var divider: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.hairline)
    }

    private var creditsRequired: Int { serviceId.cycleCost.renewalCredits ?? 0 }

    private var autoRenewBinding: Binding<Bool> {
        Binding(
            get: { subscription?.autoRenew ?? false },
            set: { data.setAutoRenew($0, for: serviceId) }
        )
    }

    // MARK: Intents

    private func activate() async {
        activating = true
        defer { activating = false }
        do {
            try data.activate(serviceId)
            toast.show(
                String(format: DiscoverCopy.activatedFormat, serviceId.title),
                kind: .success
            )
            PopopxHaptics.notice(.success)
            showsRoom = true
        } catch let error as PopopxDiscoverError {
            report(error)
        } catch {
            report(.persistenceFailed)
        }
    }

    /// Each failure gets its own next screen. An insufficient balance is the only case the
    /// user can fix in one tap, so it goes straight to the top-up page rather than leaving a
    /// message to interpret.
    private func report(_ error: PopopxDiscoverError) {
        PopopxHaptics.notice(.error)
        toast.show(error.localizedDescription, kind: .danger)
        if case .insufficientCredits = error {
            showsTopUp = true
        }
    }

    private func stop() {
        data.stop(serviceId)
        toast.show(DiscoverCopy.deactivatedNotice, kind: .success)
        PopopxHaptics.impact(.medium)
    }
}

// MARK: - Hero

struct PopopxDiscoverDetailHero: View {
    let service: PopopxNodeServiceId
    let status: PopopxDiscoverServiceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
                Image(systemName: service.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(PopopxPalette.brand)
                    .frame(width: 44, height: 44)
                    .background(PopopxPalette.brand.opacity(0.10), in: .rect(cornerRadius: PopopxMetrics.radiusControl))
                VStack(alignment: .leading, spacing: 3) {
                    Text(service.title)
                        .font(PopopxType.title)
                        .foregroundStyle(PopopxPalette.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(service.tagline)
                        .font(PopopxType.secondary)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: PopopxMetrics.spaceXS) {
                PopopxDiscoverStatusBadge(status: status)
                Text(service.nodeDisplayName)
                    .font(PopopxType.metricSmall)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.top, PopopxMetrics.space2XS)

            Text(DiscoverCopy.detailRunsOnNode)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.meshInk)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows

struct PopopxDiscoverDetailFactRow: View {
    @Environment(\.layoutDirection) private var layoutDirection

    let label: String
    let value: String
    var emphasised = false
    var valueIsLTR = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            Text(label)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PopopxMetrics.spaceXS)
            Text(value)
                .font(emphasised ? PopopxType.emphasis : PopopxType.meta)
                .foregroundStyle(emphasised ? PopopxPalette.label : PopopxPalette.labelSecondary)
                .multilineTextAlignment(valueIsLTR ? .leading : .trailing)
                .environment(\.layoutDirection, valueIsLTR ? .leftToRight : layoutDirection)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PopopxDiscoverDetailNote: View {
    let text: String
    var systemImage = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PopopxPalette.labelHint)
                .padding(.top, 2)
            Text(text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelHint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PopopxMetrics.spaceXS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.base.opacity(0.6), in: .rect(cornerRadius: PopopxMetrics.radiusChip))
        .accessibilityElement(children: .combine)
    }
}

/// The three buttons the service exposes, shown before the user subscribes.
///
/// Previewing them is not decoration: these are the commands that will be sent to the user's
/// Mac, so they are readable here, on a screen that charges nothing, before the first tap on
/// a screen that does.
struct PopopxDiscoverDetailMenuCard: View {
    let service: PopopxNodeServiceId

    var body: some View {
        PopopxSectionCard(DiscoverCopy.menuHeader) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                ForEach(service.menuActions) { action in
                    HStack(spacing: PopopxMetrics.spaceXS) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PopopxPalette.brand)
                            .frame(width: 18)
                        Text(action.title)
                            .font(PopopxType.secondary)
                            .foregroundStyle(PopopxPalette.label)
                        Spacer(minLength: PopopxMetrics.spaceXS)
                        Text(verbatim: "\(service.rawValue) · \(action.command)")
                            .font(PopopxType.metricSmall)
                            .foregroundStyle(PopopxPalette.labelHint)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(DiscoverCopy.detailMenuHint)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Copy

extension DiscoverCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "discover service detail")
    }

    static let detailHighlightsTitle = key("What it does")
    static let detailRunsOnNode = key("Runs on the Mac you bond, over your own encrypted link")
    static let detailBillingTitle = key("Billing")
    static let detailPriceLabel = key("Price")
    static let detailCycleLabel = key("Cycle")
    static let detailCycleLength = key("30 days")
    static let detailEndsLabel = key("Ends")
    static let detailRenewsLabel = key("Renews")
    static let detailMeteredBody = key(
        "This service is settled per job. Each task prices itself when the Mac returns its receipt; nothing is charged for a month."
    )
    static let detailRenewalTitle = key("Renewal")
    static let autoRenewFootnote = key(
        "With this on, one 30-day cycle is deducted from your Compute Credits when the current one ends, and only if the balance covers it."
    )
    static let detailCyclesLabel = key("Cycles paid")
    static let detailEntriesLabel = key("Receipts on this device")
    static let detailHistoryTitle = key("History")
    static let detailHistoryHint = key(
        "Commands and receipts stay on this device. Removing the Mac node from the pairing screen does not delete them, and neither does a renewal failure."
    )
    static let detailMenuHint = key("These run on your Mac after you bond it. Nothing is sent from this preview.")
    static let detailOpenRoom = key("Open service room")
    static let stopAction = key("Stop renewing")
    static let keepAction = key("Keep it running")

    static func stopBody(_ serviceTitle: String) -> String {
        String(
            format: key("%1$@ stays available until the paid time ends, then stops. Nothing is deleted."),
            serviceTitle
        )
    }

    static func nextRenewal(_ date: String, _ credits: Int) -> String {
        String(
            format: key("Next deduction: %2$lld Compute Credits on %1$@, from your balance only."),
            date, Int64(credits)
        )
    }

    static func cyclesPaid(_ cycles: Int) -> String {
        String(format: key("%lld cycles"), Int64(cycles))
    }

    static func entryCount(_ count: Int) -> String {
        String(format: key("%lld entries"), Int64(count))
    }
}
