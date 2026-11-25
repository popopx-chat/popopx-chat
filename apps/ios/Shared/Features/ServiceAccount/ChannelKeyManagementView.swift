//
//  ChannelKeyManagementView.swift
//  POPOPX (iOS)
//
//  Module 1's key page: the one place the owner can see every channel key this device holds, ask for a new epoch, paste a public
//  URI, and revoke a past epoch by hand.
//
//  ### What this file owns
//  The view is a two-level page. With `channelId == nil` it shows every known channel and lets the owner paste a new public URI or
//  adjust the expiry-warning threshold; each row pushes into that channel's detail. With `channelId != nil` it opens straight to the
//  detail for that channel. The detail carries the current epoch and its schedule state, a button that asks the channel's service
//  account for a new epoch, the epoch history with per-row revoke, and the trust-root fingerprint.
//
//  ### Where the brief's premise did not match the code
//  - The brief's "一键触发新密钥轮换" reads as "mint a new epoch on this device". This device holds no channel identity private key,
//    so it cannot sign a new epoch; the honest action is to ask the channel's service account for one. The button therefore calls
//    `PopopxChannelRotationRequest.request(channelId:)` (ChannelKeyRotationManager.swift:917), which sends a `::CB::rotate:<id>`
//    callback to the issuer contact and returns one of four verdicts. The UI speaks each verdict with an existing `PopopxEcoCopy`
//    member rather than inventing a new sentence.
//  - The brief's "删除频道" is implemented as `removeChannel(_:)` (ChannelKeyRotationManager.swift:760); the page does not offer it
//    because `PopopxEcoCopy` ships no separate "forget this channel" sentence, and reusing `keyRevokeTitle` / `keyRevokeBody` (which
//    speak of an epoch key, not the whole channel) would be dishonest. The gap is recorded in the acceptance report.
//  - The brief's "到期倒计时" is a `TimelineView(.periodic:)` tick; the file starts no heartbeat task of its own.
//  - The brief's "过期警告天数" threshold is wired through `PopopxSliderRow` (PopopxControls.swift:620), the same atom the
//    anti-theft page uses for its tilt-angle limit (PopopxAntiTheftSettingsView.swift:441).
//  - The brief's "历史密钥列表" labels each row with one of four states (current / usable / revoked / expired). `PopopxEcoCopy` has
//    `keyActive` ("Active") for the current epoch, `keyRevoked` ("Revoked") for a revoked one, and `keyScheduleExpired` ("Expired")
//    for an expired one; for an older-but-still-usable epoch the page reuses `keyActive` and reports the gap.
//

import CryptoKit
import SwiftUI

// MARK: - Public entry point

struct ChannelKeyManagementView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    /// When non-nil, the page opens straight to that channel's detail. When nil, it shows every known channel and each row pushes
    /// into the detail.
    private let initialChannelId: String?

    @State private var path = NavigationPath()
    @State private var manager = ChannelKeyRotationManager.shared
    @State private var toast = PopopxToastModel()
    @State private var uriText = ""
    @State private var isRequestingRotation = false
    @State private var showsRevokeDialog = false
    @State private var revokeTarget: RevokeTarget?

    init(channelId: String? = nil, initialURI: String? = nil) {
        self.initialChannelId = channelId
        // Only a *starting value* for the import field, so an `open_channel` tap on a channel this device has no keys for arrives with
        // the link it tapped already filled in; the row still has to be submitted by hand.
        _uriText = State(initialValue: initialURI ?? "")
    }

    var body: some View {
        NavigationStack(path: $path) {
            rootContent
                .navigationDestination(for: ChannelKeyRoute.self) { route in
                    switch route {
                    case .channel(let id):
                        detailView(for: id)
                    }
                }
                .toolbar {
                    if isPresented {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(PopopxEcoCopy.done) { dismiss() }
                                .font(PopopxType.emphasis)
                                .foregroundStyle(PopopxPalette.brand)
                                .frame(minHeight: PopopxMetrics.minHitTarget)
                                .buttonStyle(PopopxPressButtonStyle(feedback: nil))
                        }
                    }
                }
        }
        .background(PopopxPalette.base)
        .popopxToast(toast)
        .confirmationDialog(
            PopopxEcoCopy.keyRevokeTitle,
            isPresented: $showsRevokeDialog,
            titleVisibility: .visible
        ) {
            Button(PopopxEcoCopy.keyRevoke, role: .destructive) {
                if let target = revokeTarget {
                    let ok = manager.revoke(channelId: target.channelId, epoch: target.epoch)
                    if ok {
                        toast.show(PopopxEcoCopy.keyRevoked, kind: .danger)
                        PopopxHaptics.notice(.success)
                    } else {
                        toast.show(PopopxEcoCopy.keyRotateFailed, kind: .danger)
                        PopopxHaptics.notice(.error)
                    }
                }
            }
            Button(PopopxEcoCopy.cardConfirmCancel, role: .cancel) {}
        } message: {
            Text(verbatim: PopopxEcoCopy.keyRevokeBody)
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if let channelId = initialChannelId {
            detailView(for: channelId)
        } else {
            channelListView
        }
    }

    // MARK: - List view

    private var channelListView: some View {
        Group {
            if manager.channels.isEmpty {
                emptyStateView
            } else {
                channelListContent
            }
        }
        .navigationTitle(PopopxEcoCopy.keyPageTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyStateView: some View {
        VStack(spacing: PopopxMetrics.spaceM) {
            Image(systemName: "key.slash")
                .font(.system(size: 48))
                .foregroundStyle(PopopxPalette.labelHint)
                .accessibilityHidden(true)
            Text(verbatim: PopopxEcoCopy.keyNoChannel)
                .font(PopopxType.body)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PopopxMetrics.space2XL)
    }

    private var channelListContent: some View {
        ScrollView {
            LazyVStack(spacing: PopopxMetrics.spaceL) {
                importSection
                thresholdSection
                PopopxSectionCard(PopopxEcoCopy.keyPageTitle) {
                    VStack(spacing: 0) {
                        ForEach(Array(manager.channels.enumerated()), id: \.element.channelId) { index, state in
                            channelRow(state)
                            if index < manager.channels.count - 1 {
                                Divider().overlay(PopopxPalette.separator)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.vertical, PopopxMetrics.spaceM)
        }
    }

    private var importSection: some View {
        PopopxSectionCard(PopopxEcoCopy.keyImportURI, footnote: PopopxEcoCopy.keyImportPrompt) {
            VStack(spacing: PopopxMetrics.spaceXS) {
                PopopxTextField(
                    PopopxEcoCopy.keyImportURI,
                    prompt: PopopxEcoCopy.keyImportPrompt,
                    text: $uriText,
                    systemImage: "link",
                    keyboard: .URL
                )
                PopopxButton(PopopxEcoCopy.keyImportButton, systemImage: "plus.circle.fill") {
                    await importURI()
                }
                .disabled(uriText.isEmpty)
            }
        }
    }

    private var thresholdSection: some View {
        PopopxSectionCard(PopopxEcoCopy.keySchedule) {
            PopopxSliderRow(
                PopopxEcoCopy.keySchedule,
                value: Binding(
                    get: { Double(manager.expiryWarningDays) },
                    set: { manager.setExpiryWarningDays(Int($0)) }
                ),
                in: Double(PopopxEcoLimits.minimumExpiryWarningDays)...Double(PopopxEcoLimits.maximumExpiryWarningDays),
                step: 1,
                valueText: { String(format: PopopxEcoCopy.keyThresholdFormat, Int($0)) }
            )
        }
    }

    private func channelRow(_ state: PopopxChannelKeyState) -> some View {
        NavigationLink(value: ChannelKeyRoute.channel(state.channelId)) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                HStack {
                    Text(verbatim: state.relay ?? state.channelId)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(1)
                    Spacer(minLength: PopopxMetrics.spaceXS)
                    scheduleBadge(for: state.channelId)
                }
                HStack(spacing: PopopxMetrics.spaceXS) {
                    Text(verbatim: "\(state.currentEpoch)")
                        .font(PopopxType.metric)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                    if let relay = state.relay, relay != state.channelId {
                        Text(verbatim: "·")
                            .foregroundStyle(PopopxPalette.labelHint)
                        Text(verbatim: relay)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(PopopxMetrics.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: nil))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Detail view

    private func detailView(for channelId: String) -> some View {
        Group {
            if let state = manager.channel(channelId) {
                detailContent(state)
            } else {
                emptyStateView
            }
        }
        .navigationTitle(manager.channel(channelId)?.relay ?? channelId)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailContent(_ state: PopopxChannelKeyState) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                currentEpochCard(state)
                rotateCard(state)
                historyCard(state)
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.vertical, PopopxMetrics.spaceM)
        }
    }

    private func currentEpochCard(_ state: PopopxChannelKeyState) -> some View {
        PopopxSectionCard(PopopxEcoCopy.keyActiveEpoch) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "\(state.currentEpoch)")
                        .font(PopopxType.title)
                        .foregroundStyle(PopopxPalette.label)
                    Spacer(minLength: PopopxMetrics.spaceXS)
                    scheduleBadge(for: state.channelId)
                }
                if let current = state.currentKey {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        scheduleDetail(epoch: current, now: context.date)
                    }
                }
                identityTrustRow(state)
            }
        }
    }

    private func scheduleDetail(epoch: PopopxChannelEpoch, now: Date) -> some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            if let expiresAtMs = epoch.expiresAtMs {
                let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
                let secondsLeft = max(0, Double(expiresAtMs - nowMs) / 1_000)
                HStack(spacing: PopopxMetrics.spaceXS) {
                    Image(systemName: "clock")
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .accessibilityHidden(true)
                    Text(verbatim: String(format: PopopxEcoCopy.keyExpiryFormat, PopopxCommerceFormat.date(expiresAtMs)))
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                    Spacer(minLength: 0)
                    Text(verbatim: PopopxCommerceFormat.countdown(secondsLeft))
                        .font(PopopxType.metric)
                        .foregroundStyle(secondsLeft < 86_400 * 7 ? PopopxPalette.dangerInk : PopopxPalette.labelSecondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: PopopxMetrics.spaceXS) {
                    Image(systemName: "infinity")
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .accessibilityHidden(true)
                    Text(verbatim: PopopxEcoCopy.keyNeverExpires)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func identityTrustRow(_ state: PopopxChannelKeyState) -> some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Image(systemName: state.issuerContactId != nil ? "checkmark.seal.fill" : "exclamationmark.triangle")
                .font(PopopxType.caption)
                .foregroundStyle(state.issuerContactId != nil ? PopopxPalette.successInk : PopopxPalette.labelHint)
                .accessibilityHidden(true)
            Text(verbatim: state.issuerContactId != nil ? PopopxEcoCopy.keyVerified : PopopxEcoCopy.keyNotVerified)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
            if let fingerprint = fingerprint(of: state.identityKeyData) {
                Spacer(minLength: PopopxMetrics.spaceXS)
                Text(verbatim: fingerprint)
                    .font(PopopxType.metricSmall)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func rotateCard(_ state: PopopxChannelKeyState) -> some View {
        PopopxSectionCard(PopopxEcoCopy.keySchedule) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                Text(verbatim: scheduleDescription(for: state.channelId))
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                PopopxButton(
                    PopopxEcoCopy.keyRotate,
                    systemImage: "arrow.triangle.2.circlepath",
                    isLoading: isRequestingRotation
                ) {
                    await requestRotation(for: state.channelId)
                }
                .disabled(state.issuerContactId == nil)
                if state.issuerContactId == nil {
                    Text(verbatim: PopopxEcoCopy.deepLinkNeedsContact)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelHint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func historyCard(_ state: PopopxChannelKeyState) -> some View {
        let sorted = state.epochs.sorted(by: { $0.epoch > $1.epoch })
        return PopopxSectionCard(PopopxEcoCopy.keyHistory) {
            VStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element.epoch) { index, epoch in
                    epochRow(state: state, epoch: epoch)
                    if index < sorted.count - 1 {
                        Divider().overlay(PopopxPalette.separator)
                    }
                }
            }
        }
    }

    private func epochRow(state: PopopxChannelKeyState, epoch: PopopxChannelEpoch) -> some View {
        let isCurrent = epoch.epoch == state.currentEpoch
        let isUsable = epoch.isUsable && !isCurrent

        return HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                HStack(spacing: PopopxMetrics.spaceXS) {
                    Text(verbatim: "\(epoch.epoch)")
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.label)
                    if isCurrent {
                        stateTag(PopopxEcoCopy.keyActiveEpoch, color: PopopxPalette.successInk)
                    } else if epoch.revoked {
                        stateTag(PopopxEcoCopy.keyRevoked, color: PopopxPalette.dangerInk)
                    } else if !isUsable {
                        stateTag(PopopxEcoCopy.keyScheduleExpired, color: PopopxPalette.labelHint)
                    } else {
                        stateTag(PopopxEcoCopy.keyActive, color: PopopxPalette.successInk)
                    }
                }
                Text(verbatim: PopopxCommerceFormat.date(epoch.createdAtMs))
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
            }
            Spacer(minLength: 0)
            if !isCurrent && !epoch.revoked && isUsable {
                Button {
                    revokeTarget = RevokeTarget(channelId: state.channelId, epoch: epoch.epoch)
                    showsRevokeDialog = true
                } label: {
                    Text(verbatim: PopopxEcoCopy.keyRevoke)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.dangerInk)
                }
                .buttonStyle(PopopxPressButtonStyle(feedback: nil))
                .frame(minHeight: PopopxMetrics.minHitTarget)
            } else if isCurrent {
                Image(systemName: "lock.fill")
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, PopopxMetrics.spaceXS)
        .accessibilityElement(children: .combine)
    }

    private func stateTag(_ text: String, color: Color) -> some View {
        Text(verbatim: text)
            .font(PopopxType.microTag)
            .foregroundStyle(color)
            .padding(.horizontal, PopopxMetrics.spaceXS)
            .padding(.vertical, PopopxMetrics.space2XS)
            .background(color.opacity(0.15), in: .capsule)
    }

    // MARK: - Helpers

    private func scheduleBadge(for channelId: String) -> some View {
        let schedule = manager.schedule(for: channelId)
        let (text, color) = scheduleLabel(schedule)
        return Text(verbatim: text)
            .font(PopopxType.microTag)
            .foregroundStyle(color)
            .padding(.horizontal, PopopxMetrics.spaceXS)
            .padding(.vertical, PopopxMetrics.space2XS)
            .background(color.opacity(0.15), in: .capsule)
    }

    private func scheduleLabel(_ schedule: PopopxKeyRotationSchedule) -> (String, Color) {
        switch schedule {
        case .noChannel:
            return (PopopxEcoCopy.keyNoChannel, PopopxPalette.labelHint)
        case .active:
            return (PopopxEcoCopy.keyScheduleAuto, PopopxPalette.successInk)
        case .expiringSoon:
            return (PopopxEcoCopy.keyScheduleExpiring, PopopxPalette.dangerInk)
        case .expired:
            return (PopopxEcoCopy.keyScheduleExpired, PopopxPalette.dangerInk)
        case .revoked:
            return (PopopxEcoCopy.keyRevoked, PopopxPalette.dangerInk)
        case .unbounded:
            return (PopopxEcoCopy.keyNeverExpires, PopopxPalette.labelSecondary)
        }
    }

    private func scheduleDescription(for channelId: String) -> String {
        let schedule = manager.schedule(for: channelId)
        switch schedule {
        case .noChannel:
            return PopopxEcoCopy.keyNoChannel
        case .active:
            return PopopxEcoCopy.keyScheduleAuto
        case .expiringSoon:
            return PopopxEcoCopy.keyScheduleExpiring
        case .expired:
            return PopopxEcoCopy.keyScheduleExpired
        case .revoked:
            return PopopxEcoCopy.keyRevoked
        case .unbounded:
            return PopopxEcoCopy.keyNeverExpires
        }
    }

    private func fingerprint(of keyData: Data?) -> String? {
        guard let data = keyData, !data.isEmpty else { return nil }
        let hash = SHA256.hash(data: data)
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }

    private func requestRotation(for channelId: String) async {
        isRequestingRotation = true
        defer { isRequestingRotation = false }

        let outcome = await PopopxChannelRotationRequest.request(channelId: channelId)
        switch outcome {
        case .requested:
            toast.show(PopopxEcoCopy.cardSent, kind: .success)
            PopopxHaptics.notice(.success)
        case .queued:
            toast.show(PopopxEcoCopy.cardWaiting, kind: .mesh)
            PopopxHaptics.impact(.light)
        case .noIssuer:
            toast.show(PopopxEcoCopy.deepLinkNeedsContact, kind: .danger)
            PopopxHaptics.notice(.warning)
        case .sendFailed:
            toast.show(PopopxEcoCopy.cardFailed, kind: .danger)
            PopopxHaptics.notice(.error)
        }
    }

    private func importURI() async {
        let success = manager.importPublicURI(uriText)
        if success {
            toast.show(PopopxEcoCopy.keyImportStored, kind: .success)
            PopopxHaptics.notice(.success)
            uriText = ""
        } else {
            toast.show(PopopxEcoCopy.keyImportFailed, kind: .danger)
            PopopxHaptics.notice(.error)
        }
    }
}

// MARK: - Supporting types

private enum ChannelKeyRoute: Hashable {
    case channel(String)
}

private struct RevokeTarget: Equatable {
    let channelId: String
    let epoch: Int
}

// MARK: - Previews

#if DEBUG
struct ChannelKeyManagementView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ChannelKeyManagementView()
        }
        .preferredColorScheme(.light)

        NavigationStack {
            ChannelKeyManagementView(channelId: "preview.channel")
        }
        .preferredColorScheme(.dark)
    }
}
#endif
