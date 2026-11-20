//
//  ProfileCardBubbleView.swift
//  POPOPX (iOS)
//
//  [Encrypted personal profile · module 4 of 1] The card shown in the conversation for a profile: it only reports "which tier this profile is in right now",
//  and not one word of the body appears here.
//
//  This card is the entry point on the **receiving** side. The mount point is on the `PopopxBubbleMount` side (the lead engineer adds
//  `case profile(PopopxProfilePayload, target: PopopxProfileReadKey)` and routes here), and this file's
//  `init` shape aligns cell by cell with `PopopxSecureBubbleMount` (PopopxMessageBubble.swift:430-432):
//  payload + locating key + send/receive direction + channel + the timestamp of that message.
//
//  ### The card carries no body text of its own
//  The claim that the card's title, subtitle and text blocks **only appear in the reader** needs a discount: the title `manifest.title` is
//  arbitrary text written by the peer, and it goes to the screen as it is — that is what the product wants ("Zhang San's card", that recognisability is this card's entire
//  purpose), but it also means the privacy-tier card carries a title written by the peer. What really stays out of the bubble in the privacy tier is the body text and the original media.
//
//  ### The card does not decide "expired" by itself, it only makes three projections
//  1. It reads `ProfileStorageManager.readState(_:ttlSeconds:now:)` (an actor, so it goes through `.task`).
//  2. It layers on two rules that only the presentation layer knows: **the 24-hour unread fallback** (`unreadAutoBurnAfter`, see the comment below),
//     and the account of keys already burned within this conversation (`ProfileReaderHost.isBurned` — the destruction path calls `forgetRead`,
//     and once the record is gone `readState` returns to `.unread`; without that step the card would grow "not opened yet" back again).
//  3. It draws the phase. The criteria themselves (wall clock, clock rollback, rounding up) all live in the storage layer and none of them is rewritten here.
//
//  ### Why every card asks the clock, and why that is not expensive
//  `readState` is one actor hop plus one in-memory table read (`ProfileStorageManager` caches the state table in memory,
//  see its :477-493), and its own file header states that "read timing is asked by the bubble once per second". While counting it is asked every 1 second,
//  unread every 2 seconds, and once burned the clock stops; `.task` is cancelled automatically when the view disappears, so rows that are not visible are never asked.
//  The persistent tier and the outgoing tier **do not ask this clock at all** — `readState` is only meaningful for `.ephemeral` (the gate at :520-523).
//
//  ### The card manages its own surface colour
//  `PopopxBubbleInk` is `private` in the bubble file (:475) and unreachable across files — that is a measured fact rather than a guess,
//  and `PopopxSecureCardBubble` at PopopxSecureSheetView.swift:448-452 records the same thing. So this file
//  ships its own fixed surface constants instead of taking the bubble's ink.
//
//  ⚠️ Xcode project integration: this file must be dragged by hand into the POPOPX (iOS) target — the red line forbids scripting changes to project.pbxproj.
//

import SwiftUI
import UIKit

// MARK: - The profile card in the conversation

/// The card shown in the conversation for one profile message.
///
/// One button for the whole card: opening goes through `ProfileReaderHost.shared.present(...)`, and a refusal always gives visible feedback (one line inside the card
/// plus one haptic); it is never silent.
@MainActor
struct ProfileCardBubbleView: View {
    /// How long a privacy card that was sent but never opened is displayed as already expired.
    ///
    /// This is **a presentation-layer policy**, so the constant sits in this file rather than in the storage layer: `ProfileStorageManager`'s clock only runs once
    /// `firstOpenedAt` exists (the privacy semantics are "timing starts after opening"), and the product cannot allow a view-once item
    /// to sit in the conversation readable forever just because the recipient never opens it. The reader side references the same value
    /// (`ProfileReaderHost.openingClock`), so the two places never hold a second table.
    static let unreadAutoBurnAfter: TimeInterval = 86_400

    let payload: PopopxProfilePayload
    /// This row's locating key. `nil` = the mount point could not obtain the conversation identity: the card **must not** guess a key and read someone else's timer,
    /// so it draws itself as the untappable "cannot locate the owning conversation".
    let target: PopopxProfileReadKey?
    let incoming: Bool
    let channel: PopopxBubbleChannel
    /// The timestamp of that message, which serves only the 24-hour fallback above.
    let createdAt: Date

    /// Which tier the card is currently drawing. The initial value is `.pending`: before `readState` answers it must not draw "not opened yet" first,
    /// otherwise an already-burned card would flash an "can be opened" door for one frame before the answer.
    @State private var phase: Phase = .pending
    /// The sentence for a refused open. It stays inside the card instead of floating a toast: the bubble is in a list, and a toast that floats to the top of the screen is gone,
    /// while this sentence has to still be visible to the user two seconds later.
    @State private var refusal: String?
    /// Whether media has already been deleted for this tier (deduplication within the view instance, so that every redraw does not send a delete to the storage layer).
    @State private var didRemoveMedia = false
    /// The in-flight request of that one "open".
    @State private var openTask: Task<Void, Never>?
    /// The local ledger: it exists only to answer the question "should this card charge first"; all the point deduction goes through its methods, and the card never computes a balance itself.
    @State private var credits = PopopxCreditsManager.shared
    /// The only exit of the unlock receipt. The card does not assemble signalling text itself — that is the router layer's responsibility.
    @State private var signaling = PopopxSilentSignalingRouter.shared
    /// The unlock awaiting the user's nod. It is the **only** truth: the dialog's visibility is derived from it (the Binding below),
    /// so there is no intermediate frame of "the dialog is still up but the key is already empty", nor the reverse.
    @State private var pendingUnlock: PopopxProfileReadKey?

    /// The card's visible phase. It is not a one-to-one map of `PopopxProfileReadState`: this adds two presentation-layer rules
    /// (the 24-hour fallback, and this conversation's burned account) and drops the storage layer's details (the start instant).
    enum Phase: Hashable {
        case pending
        case sealed
        case counting(remainingSeconds: Int)
        case destroyed
        case unlocated
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                headline
                statusLine
                priceLine
                if let refusal {
                    refusalLine(refusal)
                }
            }
            .padding(.horizontal, PopopxMetrics.spaceM)
            .padding(.vertical, PopopxMetrics.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(.rect(cornerRadius: PopopxMetrics.radiusCard, style: .continuous))
            .background(surfaceFill)
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                    .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isOpenable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier(incoming ? "popopx.bubble.profile" : "popopx.bubble.profile.outgoing")
        .popopxAnimation(PopopxSpring.fluid, value: phase, reduceMotion: reduceMotion)
        // `.task(id:)` rather than a bare `.task`: when the payload or the locating key changes identity, the previous clock must be stopped.
        .task(id: PollIdentity(payload: payload, target: target)) { await poll() }
        // The moment the refusal sentence appears it has to be read out by the screen reader. No live region is used here: in this SDK's SwiftUI
        // `accessibilityLiveRegion` does not exist (measured: `xcrun -sdk iphonesimulator swiftc -typecheck`
        // reports "no member"), and this sentence is "the content changed while the user touched nothing" — exactly what announcement is for.
        // The same sentence is also folded into `accessibilityText`, so when focus is already on the card, re-reading the label makes it audible too.
        .onChange(of: refusal, initial: false) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        .alert(Copy.unlockTitle, isPresented: unlockPromptShown) {
            Button(Copy.unlockConfirm(unlockPrice)) { confirmUnlock() }
            Button(Copy.unlockCancel, role: .cancel) {}
        } message: {
            Text(Copy.unlockMessage(price: unlockPrice, balance: credits.balance))
        }
    }

    /// The identity value `.task(id:)` needs. A tuple cannot conform to `Equatable` (Swift tuples do not participate in protocol conformance),
    /// so the payload and the locating key each carry one — both are `Hashable`.
    private struct PollIdentity: Equatable {
        let payload: PopopxProfilePayload
        let target: PopopxProfileReadKey?
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Layout

    private var headline: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            Image(systemName: markSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(markInk)
                .frame(width: PopopxMetrics.space2XL - PopopxMetrics.spaceS)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(title)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(ink)
                    .lineLimit(2)
                badge
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            trailingMark
        }
    }

    /// The badge. The three tiers are mutually exclusive: privacy tier = lock shield + time limit; persistent + full media = deep indigo-violet; persistent (or degraded) + Cabin plain text = teal.
    private var badge: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: badgeSymbol)
                .font(PopopxType.microTag)
                .accessibilityHidden(true)
            Text(badgeText)
                .font(PopopxType.microTag)
                .lineLimit(1)
        }
        .foregroundStyle(badgeInk)
        .padding(.vertical, PopopxMetrics.space2XS)
        .padding(.horizontal, PopopxMetrics.spaceXS)
        .background(badgeFill, in: .rect(cornerRadius: PopopxMetrics.radiusChip, style: .continuous))
    }

    @ViewBuilder private var trailingMark: some View {
        if isOpenable {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondaryInk)
                .accessibilityHidden(true)
        } else {
            // The untappable tier keeps no chevron: a chevron pointing at itself promises an action that does not exist.
            EmptyView()
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch phase {
        case .pending:
            line(Copy.loading, ink: secondaryInk)
        case .sealed:
            line(payload.isEphemeral ? Copy.ephemeralUnopened(payload.ttlText) : Copy.standardHint, ink: secondaryInk)
        case let .counting(remaining):
            line(Copy.counting(remaining), ink: remaining <= 5 ? PopopxPalette.danger : secondaryInk)
        case .destroyed:
            line(Copy.destroyed, ink: secondaryInk)
        case .unlocated:
            line(Copy.unlocated, ink: secondaryInk)
        }
    }

    /// The on-card preview of the paid tier. It appears only while that charge is still unpaid: after an unlock, writing it again would become a promise of charging a second time.
    /// It uses the brand colour rather than secondary grey — this row answers "what will happen when I tap", and that is the most important factual sentence on this card right now.
    @ViewBuilder private var priceLine: some View {
        if unlockRequired, let price = payload.manifest.unlockCredits {
            line(Copy.price(price), ink: PopopxPalette.brand)
        }
    }

    private func line(_ text: String, ink: Color) -> some View {
        Text(text)
            .font(PopopxType.caption)
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refusalLine(_ text: String) -> some View {
        Label {
            Text(text)
                .font(PopopxType.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.shield")
        }
        .foregroundStyle(PopopxSurface.dangerInk)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Copy values

    private var title: String {
        let collapsed = payload.manifest.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? Copy.untitled : collapsed
    }

    private var badgeText: String {
        switch phase {
        case .destroyed:
            return Copy.destroyedBadge
        case .unlocated:
            return payload.manifest.sendMode.cardLabel
        case .pending, .sealed, .counting:
            if payload.isEphemeral { return Copy.ephemeralBadge }
            return payload.manifest.deliveryMode.badgeLabel
        }
    }

    private var badgeSymbol: String {
        if phase == .destroyed { return "flame" }
        return payload.isEphemeral
            ? "lock.shield.fill"
            : (payload.manifest.deliveryMode == .fullMedia ? "person.text.rectangle" : "antenna.radiowaves.left.and.right")
    }

    private var markSymbol: String {
        switch phase {
        case .destroyed: return "flame"
        case .unlocated: return "questionmark.folder"
        case .pending, .sealed, .counting:
            return payload.isEphemeral ? "lock.shield.fill" : "person.text.rectangle.fill"
        }
    }

    // MARK: Surface and ink

    /// The privacy tier uses the fixed deep indigo-violet surface (this card, like the top-secret tier, is a door you have to walk through to see anything),
    /// while the persistent tier uses a card face that flips with the mode (it is a thing meant to be consulted repeatedly and should not look like a safe).
    private var surfaceFill: Color {
        payload.isEphemeral ? PopopxSurface.ephemeralFill : PopopxPalette.card
    }

    private var ink: Color {
        payload.isEphemeral ? PopopxSurface.ink : PopopxPalette.label
    }

    private var secondaryInk: Color {
        payload.isEphemeral ? PopopxSurface.inkSecondary : PopopxPalette.labelSecondary
    }

    private var markInk: Color {
        if phase == .destroyed { return PopopxSurface.inkTertiary }
        return payload.isEphemeral ? PopopxPalette.brand : PopopxPalette.labelSecondary
    }

    private var badgeFill: Color {
        if phase == .destroyed { return Color.popopx(0xFFFFFF, opacity: 0.10) }
        if payload.isEphemeral { return PopopxPalette.brand }
        switch payload.manifest.deliveryMode {
        case .fullMedia:
            // The palette's own colour is used directly and the hexadecimal is not rewritten here: the card's and the bubble's indigo-violet must be the same value.
            return PopopxPalette.brand
        case .meshTextOnly:
            return PopopxPalette.mesh
        }
    }

    private var badgeInk: Color {
        if phase == .destroyed { return PopopxSurface.inkSecondary }
        if payload.isEphemeral { return PopopxPalette.onBrand }
        switch payload.manifest.deliveryMode {
        case .fullMedia:
            return PopopxPalette.onBrand
        case .meshTextOnly:
            // When teal is used as a background the ink must switch to the dark one: white on `mesh` is only 2.98:1 (the same criterion as PopopxTheme.swift:82-85).
            return PopopxPalette.onMesh
        }
    }

    // Accessibility and criteria

    /// Only the two tiers "not opened yet / counting" can be opened. Burned and unlocatable are always untappable.
    private var isOpenable: Bool {
        guard target != nil else { return false }
        switch phase {
        case .sealed, .counting: return true
        case .pending, .destroyed, .unlocated: return false
        }
    }

    /// Whether this card must charge first right now. The criterion is only the local ledger's cell: `hasUnlocked` looks up the three fields together
    /// (whose card, which conversation, which row), so "unlocked in another conversation" is not treated as paid here too.
    private var unlockRequired: Bool {
        guard let price = payload.manifest.unlockCredits, price > 0, let key = target else { return false }
        return !credits.hasUnlocked(profileId: payload.manifest.profileId, chatId: key.chatId, itemId: key.itemId)
    }

    /// The price to write on the dialog. It is read only while `pendingUnlock != nil`, and that key can only be set up by `open()` in
    /// the `unlockCredits > 0` branch, so existence does not need to be checked a second time here.
    private var unlockPrice: Int { payload.manifest.unlockCredits ?? 0 }

    /// The dialog's visibility does not store a second truth: it reads `pendingUnlock`, and clearing it is how it closes.
    /// Storing one copy in each place would leave the frame "the dialog is still up but the key is empty", where the confirm button has nowhere to land.
    private var unlockPromptShown: Binding<Bool> {
        Binding(
            get: { pendingUnlock != nil },
            set: { shown in if !shown { pendingUnlock = nil } }
        )
    }

    private var accessibilityText: String {
        var parts: [String] = []
        parts.append(payload.isEphemeral ? Copy.modeEphemeral : Copy.modeStandard)
        parts.append(title)
        switch phase {
        case .pending: parts.append(Copy.loading)
        case .sealed: parts.append(payload.isEphemeral ? payload.ttlText : Copy.standardHint)
        case let .counting(remaining): parts.append(Copy.countingSpoken(remaining))
        case .destroyed: parts.append(Copy.destroyed)
        case .unlocated: parts.append(Copy.unlocated)
        }
        if let channelSpoken { parts.append(channelSpoken) }
        // The paid tier is part of this card too: the screen reader has to read the price out before it gets to the "open" hint.
        if unlockRequired, let price = payload.manifest.unlockCredits { parts.append(Copy.price(price)) }
        // The refusal line inside the card is also part of this card (the whole card is one accessibility element, and its subviews are ignored).
        if let refusal { parts.append(refusal) }
        return parts.joined(separator: "，")
    }

    private var accessibilityHint: String {
        guard isOpenable else { return "" }
        return incoming ? Copy.hintOpen : Copy.hintOpenOutgoing
    }

    /// The one sentence about the channel. Its criterion comes from `PopopxBubbleChannel`'s four tiers (PopopxMessageBubble.swift:53-62),
    /// and the hop count does not enter this sentence: the corner badge already prints it at the bubble's lower edge, so this only states the carrying medium.
    private var channelSpoken: String? {
        switch channel {
        case .smp: return NSLocalizedString("Delivered online over the encrypted route", comment: "card accessibility, delivery channel")
        case .mesh: return NSLocalizedString("Delivered offline over the mesh", comment: "card accessibility, delivery channel")
        case .awaitingRelay: return NSLocalizedString("Still waiting in the relay queue", comment: "card accessibility, delivery channel")
        case .none: return nil
        }
    }

    // MARK: Interaction

    private func open() {
        guard isOpenable, let key = target else { return }
        // The paid tier asks about money before talking about opening: once `present` is up it is the reader's foreground, and by then the retreat "the user has not nodded yet" is gone.
        // The criterion uses `hasUnlocked` rather than one of this view's state cells: the same card can be forwarded, and can appear once more in another conversation,
        // and those three fields (who, which conversation, which row) are the complete answer to "was this unlock paid for".
        if let price = payload.manifest.unlockCredits, price > 0,
           !credits.hasUnlocked(profileId: payload.manifest.profileId, chatId: key.chatId, itemId: key.itemId) {
            refusal = nil
            pendingUnlock = key
            return
        }
        // It is recorded on `openTask` rather than casually discarded: one tap corresponds to one in-flight open request,
        // and a redraw must not turn it into an orphan (when the view identity changes `.task` stops the polling, and this one is taken over by the next tap).
        openTask = Task {
            // Reading `isPresented` here is only to give one immediate feedback; the real mutual-exclusion criterion is inside `present`,
            // and that criterion is the only trustworthy source (this read from the card can go stale at any time).
            if ProfileReaderHost.shared.isPresented {
                refusal = PopopxProfilePresentFailure.sessionAlreadyOpen.reasonText
                PopopxHaptics.notice(.warning)
                return
            }
            refusal = nil
            let failure = await ProfileReaderHost.shared.present(
                payload: payload,
                target: key,
                incoming: incoming,
                createdAt: createdAt
            )
            if Task.isCancelled { return }
            if let failure {
                // Failure/refusal always gives visible feedback: one line inside the card plus one haptic, never silent.
                refusal = failure.reasonText
                PopopxHaptics.notice(.warning)
            }
            // Even after it opened, re-read: the card must flip from "not opened yet" to "counting" at once rather than waiting for the next tick.
            await pollOnce(key: key)
        }
    }

    /// The points are spent only after the user nods, and the reader opens only after the spend succeeded. The reverse is "money paid but content never seen", the ugliest failure in this family.
    ///
    /// Only the local ledger knows about spending points: `PopopxCreditsManager` is the only thing that may change the balance, the card never touches its wallet,
    /// and calls only this one method, so "tapping the same card twice does not charge twice" is guaranteed by the three guards inside `unlockProfile`.
    private func confirmUnlock() {
        guard let key = pendingUnlock, let price = payload.manifest.unlockCredits else { return }
        pendingUnlock = nil
        do {
            _ = try credits.unlockProfile(profileId: payload.manifest.profileId,
                                          chatId: key.chatId, itemId: key.itemId, price: price)
            PopopxHaptics.notice(.success)
            open()
            sendUnlockReceipt(key: key)
        } catch {
            // One line inside the card is enough: the `errorDescription` sentences already say clearly "how many points are short",
            // and copying the balance over here again would only produce a second number.
            refusal = Copy.unlockFailed(error.localizedDescription)
            PopopxHaptics.notice(.error)
        }
    }

    /// The unlock receipt: tell the profile owner "this card has been unlocked". It is the sixth kind added beyond the five existing silent signals
    /// (`PopopxCommerceSignalKind.profileUnlocked`), receive-only — the receiving side deletes the row and touches no interface.
    ///
    /// **Best effort**: the money is spent and the content is open, so this one failing to send does not affect that transaction, and it is neither retried nor reported to the user.
    /// Scheduled after `open()`: a receipt must not delay the reader's first frame.
    ///
    /// Both gates are necessary, not fuses:
    /// - `incoming`: the outgoing cell is a card I sent myself, the "viewer" is on the peer's device, and there is no one to notify here.
    /// - `getContactChat`: in a group chat `PopopxProfileReadKey.chatId` carries the **group number**, while the landing point needs the
    ///   **contact number**, and the two numbering spaces each start at 1 and can very well collide on the same number. Using a group number as contactId would send this
    ///   machine row to somebody entirely unrelated, so it is better to send one fewer: one receipt fewer only means the profile owner does not know,
    ///   while sending it to the wrong person adds a row in someone else's conversation that nobody will ever see.
    private func sendUnlockReceipt(key: PopopxProfileReadKey) {
        guard incoming, ChatModel.shared.getContactChat(key.chatId) != nil else { return }
        let profileId = payload.manifest.profileId
        Task { _ = await signaling.sendProfileUnlockReceipt(profileId: profileId, contactId: key.chatId) }
    }

    // MARK: The clock

    /// The phase polling. `.task(id:)`'s lifetime is its lifetime: the clock stops when the view disappears.
    private func poll() async {
        guard payload.isEphemeral, incoming else {
            // Neither the persistent tier nor the outgoing tier asks this clock: the former has no clock, and the latter's clock is on the peer's device.
            phase = target == nil ? .unlocated : .sealed
            return
        }
        guard let key = target else {
            phase = .unlocated
            return
        }
        while !Task.isCancelled {
            await pollOnce(key: key)
            if Task.isCancelled { return }
            switch phase {
            case .destroyed:
                await removeMediaIfNeeded()
                return
            case .counting:
                try? await Task.sleep(for: .seconds(1))
            case .sealed, .pending:
                // Even unread must keep a tick: the 24-hour fallback, and the cell flipping after the burn finishes inside the reader,
                // can both only be seen by re-reading. 2 seconds is enough, and rows that are not visible never even get here.
                try? await Task.sleep(for: .seconds(2))
            case .unlocated:
                return
            }
        }
    }

    /// Read the state once and layer the two presentation rules on top.
    private func pollOnce(key: PopopxProfileReadKey) async {
        let now = Date()
        let state = await ProfileStorageManager.shared.readState(key, ttlSeconds: payload.manifest.ttlSeconds, now: now)
        if Task.isCancelled { return }
        phase = project(state, now: now)
    }

    private func project(_ state: PopopxProfileReadState, now: Date) -> Phase {
        guard let key = target else { return .unlocated }
        // Burned within this conversation means burned: after the destruction path's `forgetRead`, `readState` would fall back to `.unread`,
        // and without that step the card would grow the "not opened yet" door again.
        if ProfileReaderHost.shared.isBurned(key) { return .destroyed }
        if state.blocksReading { return .destroyed }
        switch state {
        case .unread:
            // The 24-hour unread fallback: display it as already expired rather than keeping a door people can still push open.
            if now.timeIntervalSince1970 - createdAt.timeIntervalSince1970 > Self.unreadAutoBurnAfter {
                return .destroyed
            }
            return .sealed
        case let .counting(_, remaining):
            return remaining > 0 ? .counting(remainingSeconds: remaining) : .destroyed
        case .expired, .clockRewound:
            return .destroyed
        }
    }

    /// An expired card deletes its associated media (the displayed state "burned by the peer" must be real, leaving no original that can still be dug out).
    ///
    /// It deletes only on the receiving direction, and does **not** call `forgetRead`: the read record is the only source of the `.expired` cell,
    /// and wiping it would flip the card back to "not opened yet". The one `forgetRead` in the destruction path is the reader's responsibility,
    /// because it also deletes the DB row at the same time — the card has no such context.
    private func removeMediaIfNeeded() async {
        guard incoming, !didRemoveMedia else { return }
        didRemoveMedia = true
        await ProfileStorageManager.shared.removeAllMedia(profileId: payload.manifest.profileId)
    }
}

// MARK: - The card's fixed surface

/// The surface colour of this card cell. Its name is kept separate from the reader's set because the card has to **follow the bubble's edge**:
/// it lives permanently in the list, so both the light and the dark variant have to be verified for contrast, whereas the reader's screen black is constant.
private enum PopopxSurface {
    /// The privacy tier's card face: one step lighter than the top-secret tier, so that two "doors you must open" do not grow into the same control in the list.
    static let ephemeralFill = Color.popopx(light: 0x2A1B4C, dark: 0x1B1132)
    static let ink = Color.popopx(0xF4F4F6)
    static let inkSecondary = Color.popopx(0xA6A6B0)
    static let inkTertiary = Color.popopx(0x8A8A94)
    /// The red of the refusal sentence: on the card face it uses `dangerInk` (`danger` does not guarantee contrast on a deep purple background).
    static let dangerInk = Color.popopx(0xFF453A)
}

// MARK: - Copy

private enum Copy {
    static let untitled = NSLocalizedString("Untitled profile page", comment: "card title fallback")
    static let loading = NSLocalizedString("Reading this device's state…", comment: "card placeholder line")
    static let unlocated = NSLocalizedString("Cannot locate the chat this card belongs to", comment: "card state line")
    static let destroyed = NSLocalizedString("This card was destroyed; nothing is kept on this device", comment: "card state line")
    static let destroyedBadge = NSLocalizedString("Destroyed", comment: "card badge")
    static let ephemeralBadge = NSLocalizedString("Burn after reading", comment: "card badge")
    static let standardHint = NSLocalizedString("Permanent profile page · tap to read any time", comment: "card hint line")
    static let modeEphemeral = NSLocalizedString("Burn-after-reading card", comment: "card accessibility mode")
    static let modeStandard = NSLocalizedString("Permanent card", comment: "card accessibility mode")
    static let hintOpen = NSLocalizedString("Tap to open and read", comment: "card accessibility hint")
    static let hintOpenOutgoing = NSLocalizedString("Tap to view the copy you sent", comment: "card accessibility hint, outgoing")

    static func ephemeralUnopened(_ ttlText: String) -> String {
        String(format: NSLocalizedString("Burn after reading · open for %@", comment: "card state line"), ttlText)
    }

    static func counting(_ seconds: Int) -> String { String(format: NSLocalizedString("%lld seconds left for this read", comment: "card countdown"), seconds) }
    static func countingSpoken(_ seconds: Int) -> String { String(format: NSLocalizedString("Counting down, %lld seconds left", comment: "card countdown, spoken"), seconds) }

    // The paid tier. The number is inserted straight into the sentences rather than wrapped in `PopopxCommerceCopy.creditsAmountFormat`: that one is for
    // the money wording in the all-language catalogues, and by the localisation ruling these two sentences stay inside the file — transcribing them in two places will sooner or later disagree.
    static func price(_ value: Int) -> String { String(format: NSLocalizedString("Reading this costs %lld Compute Credits", comment: "card price line"), value) }
    static let unlockTitle = NSLocalizedString("Unlock this profile page", comment: "unlock alert title")
    static func unlockConfirm(_ value: Int) -> String { String(format: NSLocalizedString("Spend %lld Compute Credits", comment: "unlock alert button"), value) }
    static let unlockCancel = NSLocalizedString("Cancel", comment: "unlock alert button")
    static func unlockMessage(price: Int, balance: Int) -> String {
        String(format: NSLocalizedString("The sender set a gate of %1$lld Compute Credits on this copy; your balance is %2$lld Compute Credits. The unlock record is written only into this device's keychain.", comment: "unlock alert body"), price, balance)
    }
    static func unlockFailed(_ reason: String) -> String { String(format: NSLocalizedString("Not unlocked: %@", comment: "card refusal line"), reason) }
}

// MARK: - Previews

#if DEBUG
struct ProfileCardBubbleView_Previews: PreviewProvider {
    static var previews: some View {
        ProfileCardBubbleView(
            payload: PopopxProfilePayload(manifest: .blank()),
            target: PopopxProfileReadKey(chatId: 1, itemId: 1),
            incoming: true,
            channel: .smp,
            createdAt: .now
        )
        .padding()
        .background(PopopxPalette.base)
    }
}
#endif
