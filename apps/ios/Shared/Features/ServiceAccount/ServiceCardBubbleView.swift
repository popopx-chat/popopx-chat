//
//  ServiceCardBubbleView.swift
//  POPOPX (iOS)
//
//  The three-style dynamic business card bubble: `standard` (announcements, deep-indigo badge + hairline stroke),
//  `receipt` (orders/bills/appointments, a key/value grid with mono emphasis on numeric values), `security`
//  (DevOps alerts and SSO authorisation confirmations, warning-red or radar-teal shield badge).
//
//  ### Why the card re-reads the store instead of holding its own state
//  The peer can update a card in place (a vote's progress bar moves, an SSO request flips to "approved") without
//  sending a new message. `PopopxEcoStore.rendered(card:)` returns the newest known state for the same `cardId`,
//  so the bubble that was created from the original `create` frame automatically shows the latest state when the
//  store mutates. This view holds no mutable copy of the card — it only reads.
//
//  ### Why the buttons are separate accessibility elements, not one combined label
//  The brief asks for "one coherent element (title, body, progress, then actions)". The house precedent for interactive
//  cards is `.accessibilityElement(children: .contain)` (PopopxMessageBubble.swift:345): a combined label over a
//  subtree that contains real buttons would merge their tap actions into the whole row, and VoiceOver could no longer
//  open them. So the content block (title, body, fields, progress, status) speaks as one element with a combined
//  label, and the action buttons follow it in reading order, each with its own label. The user hears "title, body,
//  progress, status" then swipes to each button — that is "then actions" in reading order, and the buttons remain
//  tappable.
//
//  ### Why the issuer-verification check reads the session, not a signature on the card
//  The product brief says "one from an issuer whose signature could not be verified must degrade to a readable, inert
//  state". But `PopopxServiceCard` carries no signature field — the wire format's only per-issuer trust fact is the
//  pairwise session the service account issued at follow time (`PopopxEcoSessionStore`). So "issuer verified" is
//  approximated by "this device holds a session for this service account's contactId". A card from a service account
//  with which no session exists cannot be tied to a verified issuer, and its buttons go inert with the
//  `cardUnverifiedIssuer` line. The approximation is honest: the session is the only credential this device holds
//  that the server could not forge for a stranger.
//
//  ### Why the price chip reuses PopopxCommerceCopy rather than inventing a new member
//  The eco copy table lacks a "cost" string (only `creditsPaidFormat` for the past-tense receipt). The mandate is
//  "use only existing PopopxEcoCopy members; do not invent; do not hardcode". `PopopxCommerceCopy.creditsAmountFormat`
//  ("%lld Compute Credits") and `creditsName` ("POPOPX Compute Credits") both exist, are already translated in 16
//  catalogs, and satisfy the mandated currency name. Reusing them is cheaper and more honest than opening a new
//  wording for one chip.
//

import SwiftUI

// MARK: - Public entry point

/// The three-style dynamic business card bubble.
///
/// The mandated public API is the only surface the mounting side needs: the card payload (the original `create` frame
/// the message carried) and the local contact id of the service account that sent it. The store and the router are
/// read from their singletons inside the view, not injected, because the mounting side has no opinion about them.
struct ServiceCardBubbleView: View {
    private let baseCard: PopopxServiceCard
    private let contactId: Int64

    init(card: PopopxServiceCard, contactId: Int64) {
        self.baseCard = card
        self.contactId = contactId
    }

    // The store and router are `@Observable` singletons; reading them through `@State` keeps the view's dependency
    // tracking alive, so a peer update to `cards` or `lockedActions` re-renders the bubble.
    @State private var store = PopopxEcoStore.shared
    @State private var router = PopopxEcoRouter.shared
    @State private var credits = PopopxCreditsManager.shared

    @State private var outcome: ServiceCardOutcome?
    @State private var pendingConfirmation: PopopxEcoAction?
    @State private var expiredNow = false
    @State private var issuerVerified: Bool?
    @State private var showsStore = false
    @State private var toast = PopopxToastModel()

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let card = store.rendered(card: baseCard)

        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            // The content block speaks as one element: title, body, fields, progress, status. The action buttons
            // follow in reading order and speak their own titles, so VoiceOver reads "content, then actions".
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                header(for: card)
                if let body = card.body, !body.isEmpty {
                    Text(verbatim: body)
                        .font(PopopxType.body)
                        .foregroundStyle(PopopxPalette.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !card.fields.isEmpty {
                    fieldsGrid(card.fields, style: card.style)
                }
                if let progress = card.progress {
                    progressBar(progress)
                }
                statusLine(card: card)
            }
            .serviceCardAccessibilityLabel(spoken)
            actionsRow(card: card)
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay(cardStroke(for: card.style))
        .popopxCardElevation(colorScheme: colorScheme)
        .popopxAnimation(PopopxSpring.fluid, value: card.updatedAtMs, reduceMotion: reduceMotion)
        .accessibilityElement(children: .contain)
        .onAppear {
            credits.loadIfNeeded()
            store.loadIfNeeded()
        }
        .task {
            // The session read touches the Keychain; doing it once on appear, rather than in the render body,
            // keeps the view's hot path free of `SecItemCopyMatching` calls.
            issuerVerified = PopopxEcoSessionStore.hasSession(for: contactId)
        }
        .task(id: card.expiresAtMs) {
            // One-shot expiry: when the card's deadline passes while on screen, flip the local flag so the buttons
            // go inert without waiting for a new frame. A card with no expiry stays live forever.
            guard let expiresAtMs = card.expiresAtMs else { return }
            let nowMs = Int64(Date.now.timeIntervalSince1970 * 1_000)
            guard expiresAtMs > nowMs else {
                expiredNow = true
                return
            }
            let nanoseconds = UInt64(expiresAtMs - nowMs) * 1_000_000
            try? await Task.sleep(nanoseconds: nanoseconds)
            if !Task.isCancelled {
                expiredNow = true
            }
        }
        .confirmationDialog(
            PopopxEcoCopy.cardConfirmTitle,
            isPresented: pendingConfirmationBinding,
            presenting: pendingConfirmation
        ) { action in
            Button(PopopxEcoCopy.cardConfirmSend) {
                Task { @MainActor in await fire(action) }
            }
            Button(PopopxEcoCopy.cardConfirmCancel, role: .cancel) {
                pendingConfirmation = nil
            }
        } message: { action in
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(verbatim: action.title)
                if action.kind == .payCredits, let amount = action.amount {
                    Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, amount))
                        .foregroundStyle(PopopxPalette.labelSecondary)
                }
            }
        }
        .sheet(isPresented: $showsStore) {
            PopopxCreditsStoreView()
        }
        .popopxToast(toast)
        .onChange(of: card.updatedAtMs) { _, _ in
            // The peer updated the card: whatever status line was showing (waiting, paid, failed) is now stale.
            outcome = nil
        }
    }

    // MARK: Derived

    private var pendingConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        )
    }

    // MARK: Derived

    private var cardIsLive: Bool {
        let nowMs = Int64(Date.now.timeIntervalSince1970 * 1_000)
        return baseCard.isLive(nowMs: nowMs) && !expiredNow
    }

    private var cardIsInert: Bool {
        !cardIsLive
    }

    // MARK: Header

    @ViewBuilder
    private func header(for card: PopopxServiceCard) -> some View {
        let tint = badgeTint(for: card.style, card: card)
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            Image(systemName: badgeSymbol(for: card.style))
                .font(PopopxType.emphasis)
                .foregroundStyle(tint.ink)
                .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                .background(tint.fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(verbatim: card.title)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
                if !cardIsLive {
                    Text(verbatim: PopopxEcoCopy.cardExpired)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                } else if issuerVerified == false {
                    Text(verbatim: PopopxEcoCopy.cardUnverifiedIssuer)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.dangerInk)
                }
            }
            Spacer(minLength: PopopxMetrics.spaceS)
        }
    }

    private func badgeTint(for style: PopopxServiceCard.Style, card: PopopxServiceCard) -> PopopxIconTint {
        switch style {
        case .standard:
            return .brand
        case .receipt:
            return .neutral
        case .security:
            // The frame carries no alert/authorisation subtype, so the shield colour is derived from the actions:
            // a destructive action or an expired security card reads red, an authorisation request awaiting a
            // decision reads teal.
            if !cardIsLive || card.actions.contains(where: { $0.visual == .destructive }) {
                return .danger
            }
            return .mesh
        }
    }

    private func badgeSymbol(for style: PopopxServiceCard.Style) -> String {
        switch style {
        case .standard:
            return "bell.badge"
        case .receipt:
            return "list.bullet.rectangle"
        case .security:
            return "lock.shield.fill"
        }
    }

    @ViewBuilder
    private func cardStroke(for style: PopopxServiceCard.Style) -> some View {
        RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard, style: .continuous)
            .strokeBorder(strokeColor(for: style), lineWidth: PopopxMetrics.hairline)
    }

    private func strokeColor(for style: PopopxServiceCard.Style) -> Color {
        switch style {
        case .standard:
            return PopopxPalette.brand.opacity(0.35)
        case .receipt:
            return PopopxPalette.separator
        case .security:
            return PopopxPalette.separator
        }
    }

    // MARK: Fields grid

    @ViewBuilder
    private func fieldsGrid(_ fields: [PopopxServiceCard.Field], style: PopopxServiceCard.Style) -> some View {
        Grid(alignment: .leading, horizontalSpacing: PopopxMetrics.spaceS, verticalSpacing: PopopxMetrics.spaceXS) {
            ForEach(fields) { field in
                GridRow {
                    Text(verbatim: field.label)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .gridColumnAlignment(.leading)
                    Text(verbatim: field.value)
                        .font(field.mono == true ? PopopxType.metric : PopopxType.meta)
                        .foregroundStyle(PopopxPalette.label)
                        .gridColumnAlignment(.trailing)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if style == .receipt && field.id != fields.last?.id {
                    GridRow {
                        Divider()
                            .gridCellColumns(2)
                            .overlay(PopopxPalette.separator)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Progress bar

    @ViewBuilder
    private func progressBar(_ progress: PopopxServiceCard.Progress) -> some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                Text(verbatim: String(format: PopopxEcoCopy.cardProgressFormat, progress.label, progress.percent))
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                if let detail = progress.detail {
                    Text(verbatim: detail)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            // The bar does not use GeometryReader: `scaleEffect(anchor: .leading)` alone can shrink a Capsule by the
            // percent while the layout width is unaffected (the same precedent as ProfileReaderView.swift:980).
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(PopopxPalette.separator)
                Capsule()
                    .fill(PopopxPalette.brand)
                    .scaleEffect(x: max(0.002, CGFloat(progress.percent)  / 100.0), y: 1, anchor: .leading)
            }
            .frame(height: PopopxMetrics.space2XS)
            .popopxAnimation(PopopxSpring.fluid, value: progress.percent, reduceMotion: reduceMotion)
        }
    }

    // MARK: Status line

    @ViewBuilder
    private func statusLine(card: PopopxServiceCard) -> some View {
        if let outcome {
            outcomeLine(outcome)
        } else if !cardIsLive {
            inertNote(symbol: "exclamationmark.circle", text: PopopxEcoCopy.cardExpired, ink: PopopxPalette.labelSecondary)
        } else if issuerVerified == false {
            inertNote(symbol: "exclamationmark.shield", text: PopopxEcoCopy.cardUnverifiedIssuer, ink: PopopxPalette.dangerInk)
        }
    }

    @ViewBuilder
    private func outcomeLine(_ outcome: ServiceCardOutcome) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: outcome.symbol)
                .font(PopopxType.microTag)
                .foregroundStyle(outcome.ink)
                .accessibilityHidden(true)
            Text(verbatim: outcome.text)
                .font(PopopxType.caption)
                .foregroundStyle(outcome.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if outcome.showsStoreJump {
                Button {
                    // Drain the router's one-shot request so a screen-level host that also drains it does not
                    // double-present the store sheet. If another host already took it, the user still asked for
                    // the store, so present locally regardless.
                    _ = PopopxEcoRouter.shared.takeCreditTopUpRequest()
                    showsStore = true
                } label: {
                    Text(verbatim: PopopxEcoCopy.cardOpenStore)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.brand)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func inertNote(symbol: String, text: String, ink: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: symbol)
                .font(PopopxType.microTag)
                .foregroundStyle(ink)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions row

    @ViewBuilder
    private func actionsRow(card: PopopxServiceCard) -> some View {
        let liveActions = cardIsInert ? [] : card.actions.filter(\.isLive)
        if liveActions.isEmpty {
            // No actions, or the card is inert: nothing to draw.
            EmptyView()
        } else if liveActions.count == 1 {
            actionButton(liveActions[0], card: card, fullWidth: true)
        } else if liveActions.count == 2 {
            HStack(spacing: PopopxMetrics.spaceXS) {
                ForEach(liveActions) { action in
                    actionButton(action, card: card, fullWidth: true)
                }
            }
        } else {
            // Three or four actions: stack vertically so Dynamic Type at XXL does not crush the labels.
            VStack(spacing: PopopxMetrics.spaceXS) {
                ForEach(liveActions) { action in
                    actionButton(action, card: card, fullWidth: true)
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: PopopxEcoAction, card: PopopxServiceCard, fullWidth: Bool) -> some View {
        let isLocked = PopopxEcoStore.shared.isActionLocked(cardId: card.cardId, actionId: action.id)
        // Security hardening: only payCredits actions require issuer verification
        let requiresVerification = action.kind == .payCredits
        let unverifiedPayBlocked = requiresVerification && issuerVerified == false
        let role = buttonRole(for: action.visual)
        Button {
            if action.requiresConfirmation {
                pendingConfirmation = action
            } else {
                Task { @MainActor in await fire(action) }
            }
        } label: {
            actionLabel(action, isLocked: isLocked, showSecurityBadge: unverifiedPayBlocked)
        }
        .buttonStyle(PopopxPressButtonStyle(feedback: role == .destructive ? .medium : .light))
        .disabled(isLocked || cardIsInert || unverifiedPayBlocked)
        .opacity(isLocked || cardIsInert || unverifiedPayBlocked ? 0.45 : 1)
        .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: PopopxMetrics.minHitTarget)
        .accessibilityLabel(Text(verbatim: action.title))
        .accessibilityValue(Text(verbatim: actionAccessibilityValue(action: action, isLocked: isLocked, unverifiedPayBlocked: unverifiedPayBlocked)))
    }

    @ViewBuilder
    private func actionLabel(_ action: PopopxEcoAction, isLocked: Bool, showSecurityBadge: Bool) -> some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            if isLocked {
                Image(systemName: "lock")
                    .font(PopopxType.meta)
                    .accessibilityHidden(true)
            }
            if showSecurityBadge {
                Image(systemName: "exclamationmark.shield")
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .accessibilityHidden(true)
            }
            Text(verbatim: action.title)
                .font(PopopxType.emphasis)
            if action.kind == .payCredits, let amount = action.amount {
                Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, amount))
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.onBrand.opacity(0.85))
            }
        }
        .padding(.horizontal, PopopxMetrics.spaceM)
        .padding(.vertical, PopopxMetrics.spaceS)
        .frame(maxWidth: .infinity)
        .background(buttonFill(for: action.visual), in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .overlay {
            if action.visual == .secondary {
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                    .strokeBorder(PopopxPalette.labelHint, lineWidth: PopopxMetrics.divider)
            }
        }
        .foregroundStyle(buttonInk(for: action.visual))
        .contentShape(RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl))
    }

    private func buttonRole(for visual: PopopxEcoAction.Visual) -> PopopxButtonRole {
        switch visual {
        case .primary: return .primary
        case .secondary: return .secondary
        case .destructive: return .destructive
        }
    }

    private func buttonFill(for visual: PopopxEcoAction.Visual) -> Color {
        switch visual {
        case .primary: return PopopxPalette.brand
        case .secondary: return PopopxPalette.card
        case .destructive: return PopopxPalette.dangerFill
        }
    }

    private func buttonInk(for visual: PopopxEcoAction.Visual) -> Color {
        switch visual {
        case .primary: return PopopxPalette.onBrand
        case .secondary: return PopopxPalette.label
        case .destructive: return PopopxPalette.onDanger
        }
    }

    private func actionAccessibilityValue(action: PopopxEcoAction, isLocked: Bool, unverifiedPayBlocked: Bool) -> String {
        if unverifiedPayBlocked { return PopopxEcoCopy.cardUnverifiedIssuer }
        if isLocked { return PopopxEcoCopy.cardWaiting }
        if action.kind == .payCredits, let amount = action.amount {
            return String(format: PopopxCommerceCopy.creditsAmountFormat, amount)
        }
        return ""
    }

    // MARK: Action dispatch

    @MainActor
    private func fire(_ action: PopopxEcoAction) async {
        let card = PopopxEcoStore.shared.rendered(card: baseCard)
        let result = await PopopxEcoActionRunner.run(action, on: card, contactId: contactId, store: .shared, router: .shared)
        apply(result: result, action: action)
    }

    @MainActor
    private func apply(result: PopopxEcoActionResult, action: PopopxEcoAction) {
        let outcome = ServiceCardOutcome(result: result, action: action)
        self.outcome = outcome
        if let notice = outcome.toastNotice {
            toast.show(notice.text, kind: notice.kind)
        }
        if let haptic = outcome.haptic {
            PopopxHaptics.notice(haptic)
        }
        // For `.noSession`, the runner told us this device holds no pairwise session with this issuer. The card
        // cannot be tied to a verified issuer, so flip the local inert flag. The buttons go dark on the next render.
        if case .noSession = result {
            issuerVerified = false
        }
    }

    // MARK: Spoken text

    /// The sentence VoiceOver reads for the content block. The action buttons follow in reading order and speak
    /// their own titles, so this sentence does not repeat them.
    private var spoken: String {
        let card = PopopxEcoStore.shared.rendered(card: baseCard)
        var parts = [PopopxEcoCopy.cardSpokenPrefix, card.title]
        if let body = card.body, !body.isEmpty { parts.append(body) }
        for field in card.fields {
            parts.append("\(field.label): \(field.value)")
        }
        if let progress = card.progress {
            parts.append(String(format: PopopxEcoCopy.cardProgressFormat, progress.label, progress.percent))
            if let detail = progress.detail { parts.append(detail) }
        }
        if !cardIsLive { parts.append(PopopxEcoCopy.cardExpired) }
        if issuerVerified == false { parts.append(PopopxEcoCopy.cardUnverifiedIssuer) }
        if let outcome { parts.append(outcome.text) }
        return parts.joined(separator: "，")
    }
}

// MARK: - Outcome mapping

/// The visible outcome of one action tap. Each `PopopxEcoActionResult` case maps to one of these; none falls through.
private struct ServiceCardOutcome: Equatable {
    let symbol: String
    let text: String
    let ink: Color
    let haptic: PopopxHapticNotice?
    let showsStoreJump: Bool
    let toastNotice: PopopxToastMessage?

    init(result: PopopxEcoActionResult, action: PopopxEcoAction) {
        switch result {
        case .sentCallback:
            if action.kind == .payCredits, let amount = action.amount {
                self.init(
                    symbol: "checkmark.seal.fill",
                    text: String(format: PopopxEcoCopy.creditsPaidFormat, amount),
                    ink: PopopxPalette.successInk,
                    haptic: .success,
                    showsStoreJump: false,
                    toastNotice: nil
                )
            } else {
                self.init(
                    symbol: "arrow.up.right",
                    text: PopopxEcoCopy.cardSent,
                    ink: PopopxPalette.successInk,
                    haptic: .success,
                    showsStoreJump: false,
                    toastNotice: nil
                )
            }
        case .paidAwaitingReply:
            self.init(
                symbol: "circle.dashed",
                text: PopopxEcoCopy.cardWaiting,
                ink: PopopxPalette.labelSecondary,
                haptic: nil,
                showsStoreJump: false,
                toastNotice: nil
            )
        case .needsCredits:
            self.init(
                symbol: "exclamationmark.circle",
                text: PopopxEcoCopy.cardBalanceShort,
                ink: PopopxPalette.dangerInk,
                haptic: .warning,
                showsStoreJump: true,
                toastNotice: nil
            )
        case .openedH5:
            self.init(
                symbol: "arrow.up.right",
                text: PopopxEcoCopy.done,
                ink: PopopxPalette.brand,
                haptic: .success,
                showsStoreJump: false,
                toastNotice: nil
            )
        case .openedChannel:
            self.init(
                symbol: "antenna.radiowaves.left.and.right",
                text: PopopxEcoCopy.done,
                ink: PopopxPalette.meshInk,
                haptic: .success,
                showsStoreJump: false,
                toastNotice: nil
            )
        case .locked:
            self.init(
                symbol: "lock",
                text: PopopxEcoCopy.cardWaiting,
                ink: PopopxPalette.labelSecondary,
                haptic: nil,
                showsStoreJump: false,
                toastNotice: nil
            )
        case .expired:
            self.init(
                symbol: "exclamationmark.circle",
                text: PopopxEcoCopy.cardExpired,
                ink: PopopxPalette.labelSecondary,
                haptic: .warning,
                showsStoreJump: false,
                toastNotice: nil
            )
        case .ignored:
            self.init(
                symbol: "slash.circle",
                text: PopopxEcoCopy.cardFailed,
                ink: PopopxPalette.labelSecondary,
                haptic: .warning,
                showsStoreJump: false,
                toastNotice: nil
            )
        case .noSession:
            self.init(
                symbol: "exclamationmark.shield",
                text: PopopxEcoCopy.cardUnverifiedIssuer,
                ink: PopopxPalette.dangerInk,
                haptic: .warning,
                showsStoreJump: false,
                toastNotice: nil
            )
        case .sendFailed:
            self.init(
                symbol: "exclamationmark.circle",
                text: PopopxEcoCopy.cardFailed,
                ink: PopopxPalette.dangerInk,
                haptic: .error,
                showsStoreJump: false,
                toastNotice: PopopxToastMessage(text: PopopxEcoCopy.cardFailed, kind: .danger)
            )
        }
    }

    private init(symbol: String, text: String, ink: Color, haptic: PopopxHapticNotice?, showsStoreJump: Bool, toastNotice: PopopxToastMessage?) {
        self.symbol = symbol
        self.text = text
        self.ink = ink
        self.haptic = haptic
        self.showsStoreJump = showsStoreJump
        self.toastNotice = toastNotice
    }
}

// MARK: - Accessibility wrapper

extension View {
    /// The spoken sentence for the card's content block. Applied as an accessibility label on the content subtree,
    /// so VoiceOver reads title, body, progress and status as one element before moving to the action buttons.
    func serviceCardAccessibilityLabel(_ spoken: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spoken))
    }
}
