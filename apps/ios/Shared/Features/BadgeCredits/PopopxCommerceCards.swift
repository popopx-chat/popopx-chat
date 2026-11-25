//  PopopxCommerceCards.swift
//
//  [Phase 6 · 1] Three cards in the conversation flow: gift card, red packet and channel threshold. They are the only entries in this ecosystem that 'get tapped a second time',
//  so their criteria always read the model layer, leaving no state in the view that could be rewritten on its own.
//
//  ### Cards bring their own surface; they do not take the bubble's ink colour
//  Handled the same way as `ProfileCardBubbleView` / `PopopxSecureBubbleMount`
//  (see the comments on those two branches in `Shared/Features/ChatRoom/PopopxMessageBubble.swift:426-444`):
//  'something you can tap' must look clearly different from the plain text around it, so it carries its own background and a hairline stroke,
//  rather than swapping text colour with the bubble's sent/received sides — doing that grows it into the bubble and it no longer reads as a control.
//
//  ### Where the state comes from
//  - Gift card: `PopopxCreditsManager.hasRedeemed(voucherId:)` is the long-lived fact of having been redeemed on this device;
//    this round's final state is read from `PopopxSilentSignalingRouter.outcomesByVoucher[voucherId]`,
//    **not** the global `lastOutcome` — with two vouchers hanging in two conversations at once, the global one crosses the wires.
//  - Red packet: both `hasClaimed(packetId:)` and `pendingPacket(packetId:)` live in the ledger.
//    The former is 'I have opened it', the latter is 'this one I sent'.
//
//  ### A red packet you sent yourself cannot be opened by you
//  Sending already deducted the credits. If the card on this device's timeline could still be tapped to 'open', the same person would both be charged once and receive a share —
//  this criterion must also exist at the view layer, even though `claimRedPacket`'s replay protection would also block the same packetId.
//
//  ### The receipt is best-effort
//  After opening, this device credits immediately (that share of credits belongs to the opener), then sends a silent receipt to the sender, used only to compute a refund.
//  When the receipt does not arrive, this cell keeps a 'resend receipt' button for the life of the process; after a restart it no longer prompts,
//  because 'was the receipt delivered' has no locally persistable criterion — better one prompt fewer than pretending to know.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. Red lines forbid a script from modifying project.pbxproj.

import SwiftUI

// MARK: - Context and routing

/// The conversation context the cards need, handed over complete by the mounting side in one go.
struct PopopxCommerceCardContext: Hashable {
    /// The destination of the conversation the card sits in. With nil the gift card and the red packet are read-only: redemption and opening both reply a message into this conversation.
    let target: PopopxCommerceTarget?
    /// Whether the card is on the side the other party sent it from.
    let incoming: Bool
    /// The threshold card signs a local credential for the conversation it sits in, so the mounting side carries the conversation's display key and name down together.
    /// Only the `channel` branch reads these two fields (the gift card and red packet do not use them); the empty-string default is so that existing construction sites are not disturbed.
    let chatId: String
    let chatTitle: String
    /// Whether this conversation is a channel. The threshold card only counts when it lands in a channel: the criterion uses the same value as the channel info page's cell
    /// (`GroupInfo.isChannel`), which the mounting side copies over verbatim from `chat.chatInfo.groupInfo`.
    /// The false default keeps the 'mounting side gave no context' fallback path parked in the cell it originally had —
    /// that path's `chatId` is an empty string too, so 'here you can only read' blocks it first and this line never gets to speak.
    let isChannel: Bool

    init(target: PopopxCommerceTarget?, incoming: Bool, chatId: String = "", chatTitle: String = "",
         isChannel: Bool = false) {
        self.target = target
        self.incoming = incoming
        self.chatId = chatId
        self.chatTitle = chatTitle
        self.isChannel = isChannel
    }
}

/// Which card a text message should render as inside the conversation flow.
enum PopopxCommerceContent: Hashable {
    case gift(PopopxGiftCardPayload)
    case creditGift(PopopxCreditGiftPayload)
    case packet(PopopxRedPacketPayload)
    case channel(PopopxChannelAccessPayload)

    /// One decision used for bubble routing: if it resembles none of these, return nil and let the message take the plain-text branch.
    /// The order has nothing to do with correctness (every host differs from each other, so at most one parse can succeed); the channel comes last because it looks least like 'a card you tap'.
    static func detect(in text: String) -> PopopxCommerceContent? {
        if let packet = PopopxRedPacketPayload.parse(from: text) { return .packet(packet) }
        if let gift = PopopxGiftCardPayload.parse(from: text) { return .gift(gift) }
        if let creditGift = PopopxCreditGiftPayload.parse(from: text) { return .creditGift(creditGift) }
        if let channel = PopopxChannelAccessPayload.parse(from: text) { return .channel(channel) }
        return nil
    }

    /// VoiceOver's sentence is owned by this file: the wording and the numbers printed on the card must come from one source,
    /// otherwise the bubble and the card each tell a different story (the same reason holds for those two branches in `PopopxMessageBubble.swift:211-217`).
    /// It reads out only the quota and the number of shares, no signature and no voucher id — those strings read aloud would only become noise.
    var spokenText: String {
        switch self {
        case let .gift(payload):
            payload.note.isEmpty
                ? String(format: NSLocalizedString("Badge gift card, %lld days, tap to redeem.", comment: "POPOPX commerce VoiceOver"), payload.period.days)
                : String(format: NSLocalizedString("Badge gift card, %1$lld days, message: %2$@. Tap to redeem.", comment: "POPOPX commerce VoiceOver"), payload.period.days, payload.note)
        case let .creditGift(payload):
            payload.note.isEmpty
                ? String(format: NSLocalizedString("Compute Credits gift card, %lld credits, tap to redeem.", comment: "POPOPX commerce VoiceOver"), payload.creditsAmount)
                : String(format: NSLocalizedString("Compute Credits gift card, %1$lld credits, message: %2$@. Tap to redeem.", comment: "POPOPX commerce VoiceOver"), payload.creditsAmount, payload.note)
        case let .packet(payload):
            payload.recipients > 1
                ? String(format: NSLocalizedString("Compute Credits red packet, %1$lld credits split %2$lld ways. Tap to open.", comment: "POPOPX commerce VoiceOver"), payload.amount, payload.recipients)
                : String(format: NSLocalizedString("Compute Credits red packet, %lld credits. Tap to open.", comment: "POPOPX commerce VoiceOver"), payload.amount)
        case let .channel(payload):
            String(format: NSLocalizedString("Channel subscription threshold, %lld Compute Credits per period. Tap to subscribe.", comment: "POPOPX commerce VoiceOver"), payload.price)
        }
    }
}

// MARK: - Card surface

/// The layer these cards share: card background, hairline stroke, left-aligned content column.
private struct PopopxCommerceCardSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            content
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
    }
}

private struct PopopxCommerceCardHeader: View {
    let systemImage: String
    let title: String
    let caption: String
    let ink: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            Image(systemName: systemImage)
                .font(PopopxType.emphasis)
                .foregroundStyle(ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(verbatim: title)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.label)
                Text(verbatim: caption)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PopopxMetrics.spaceS)
        }
    }
}

/// The refused-state line: one icon plus one sentence, no large red block — the commonest failure in these cards is 'expired / used',
/// which is not an error, and a danger background would shout an ordinary state as an incident.
private struct PopopxCommerceCardNote: View {
    let systemImage: String
    let text: String
    let ink: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: systemImage)
                .font(PopopxType.microTag)
                .foregroundStyle(ink)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Gift card

/// A badge gift card received in a conversation. Tapping 'redeem' emits a `CHAT_REDEEM_REQ`, and the final state waits for the ACK.
struct PopopxGiftCardBubble: View {
    let payload: PopopxGiftCardPayload
    let context: PopopxCommerceCardContext

    @State private var credits = PopopxCreditsManager.shared
    @State private var router = PopopxSilentSignalingRouter.shared
    @State private var opening = false
    /// It holds only the 'fails on the spot' kinds (signature check fails, cannot be sent out). When the request starts successfully it is nil,
    /// so the final state always comes from `outcomesByVoucher`, and the two sources never cover each other up.
    @State private var immediate: PopopxRedemptionOutcome?

    var body: some View {
        PopopxCommerceCardSurface {
            PopopxCommerceCardHeader(
                systemImage: "giftcard.fill",
                title: Copy.title(payload.period.days),
                caption: payload.note.isEmpty ? Copy.caption : Copy.note(payload.note),
                ink: PopopxPalette.meshInk
            )
            Divider().overlay(PopopxPalette.separator)
            state
        }
        .onAppear { credits.loadIfNeeded() }
    }

    @ViewBuilder private var state: some View {
        if !payload.isSignatureValid {
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: Copy.rejected, ink: PopopxPalette.dangerInk)
        } else if credits.hasRedeemed(voucherId: payload.voucherId) {
            PopopxCommerceCardNote(systemImage: "checkmark.seal.fill", text: Copy.redeemedHere, ink: PopopxPalette.successInk)
        } else if !context.incoming {
            PopopxCommerceCardNote(systemImage: "arrow.up.right", text: Copy.sentByYou, ink: PopopxPalette.labelSecondary)
        } else {
            switch context.target {
            case .none:
                PopopxCommerceCardNote(systemImage: "eye", text: Copy.readOnly, ink: PopopxPalette.labelSecondary)
            case .some(.group):
                // Gift-card ACKs are accounted by chatId, so a second person in the group would settle somebody else's entry; the router therefore refuses to pass it at the entry.
                PopopxCommerceCardNote(systemImage: "person.2", text: Copy.groupUnsupported, ink: PopopxPalette.labelSecondary)
            case .some(.contact):
                awaitingOrAction
            }
        }
    }

    @ViewBuilder private var awaitingOrAction: some View {
        switch resolvedOutcome {
        case .some(.redeemed(let period, _)):
            PopopxCommerceCardNote(systemImage: "checkmark.seal.fill",
                                   text: Copy.redeemed(period.days),
                                   ink: PopopxPalette.successInk)
        case let .some(.failed(error)):
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: gloss(error), ink: PopopxPalette.dangerInk)
        // `.redeemedCredits` shares the "still offers the button" branch rather than printing a success line: outcomes are keyed by voucher id,
        // and a voucher id belongs to exactly one family, so a credit outcome landing on a badge card means the table is confused —
        // and a button the vault will refuse is a smaller lie than this card claiming somebody else's number.
        case .some(.initiated), .some(.redeemedCredits), .none:
            PopopxButton(opening ? Copy.sending : Copy.redeem,
                         systemImage: opening ? nil : "key.fill",
                         role: .secondary,
                         fullWidth: true,
                         isLoading: opening) {
                await redeem()
            }
        }
    }

    private var resolvedOutcome: PopopxRedemptionOutcome? {
        immediate ?? router.outcomesByVoucher[payload.voucherId]
    }

    private func redeem() async {
        guard case let .contact(contactId) = context.target else { return }
        opening = true
        immediate = nil
        let outcome = await router.redeemInChat(payload, contactId: contactId)
        if case .initiated = outcome {
            PopopxHaptics.notice(.warning)
        } else {
            immediate = outcome
            PopopxHaptics.notice(.error)
        }
        opening = false
    }

    private func gloss(_ error: PopopxBadgeCreditsError) -> String {
        switch error {
        case .connectionUnavailable: Copy.glossUnreachable
        case .voucherAlreadyRedeemed: Copy.glossAlready
        case .signalRejected: Copy.rejected
        default: error.errorDescription ?? Copy.glossGeneric
        }
    }
}

// MARK: - Compute-credit gift card

/// A compute-credit gift card received in a conversation. Same shape as `PopopxGiftCardBubble` on purpose — the two families differ in what they
/// hand over (a number vs a deadline) and in nothing else, so one screenful read the other way round would be a design bug, not a difference.
struct PopopxCreditGiftBubble: View {
    let payload: PopopxCreditGiftPayload
    let context: PopopxCommerceCardContext

    @State private var credits = PopopxCreditsManager.shared
    @State private var router = PopopxSilentSignalingRouter.shared
    @State private var opening = false
    @State private var immediate: PopopxRedemptionOutcome?

    var body: some View {
        PopopxCommerceCardSurface {
            PopopxCommerceCardHeader(
                systemImage: "giftcard.fill",
                title: Copy.creditTitle,
                caption: payload.note.isEmpty ? Copy.creditCaption : Copy.note(payload.note),
                ink: PopopxPalette.meshInk
            )
            amountLine
            Divider().overlay(PopopxPalette.separator)
            state
        }
        .onAppear { credits.loadIfNeeded() }
    }

    /// The face value, printed with the same formatter the red packet and the ledger use, so "100 Compute Credits" is one sentence in this app and not three.
    private var amountLine: some View {
        Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, payload.creditsAmount))
            .font(PopopxType.metric)
            .foregroundStyle(PopopxPalette.label)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var state: some View {
        if !payload.isSignatureValid {
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: Copy.rejected, ink: PopopxPalette.dangerInk)
        } else if credits.hasRedeemed(voucherId: payload.voucherId) {
            PopopxCommerceCardNote(systemImage: "checkmark.seal.fill", text: Copy.redeemedHere, ink: PopopxPalette.successInk)
        } else if !context.incoming {
            PopopxCommerceCardNote(systemImage: "arrow.up.right", text: Copy.sentByYou, ink: PopopxPalette.labelSecondary)
        } else {
            switch context.target {
            case .none:
                PopopxCommerceCardNote(systemImage: "eye", text: Copy.readOnly, ink: PopopxPalette.labelSecondary)
            case .some(.group):
                PopopxCommerceCardNote(systemImage: "person.2", text: Copy.creditGroupUnsupported, ink: PopopxPalette.labelSecondary)
            case .some(.contact):
                awaitingOrAction
            }
        }
    }

    @ViewBuilder private var awaitingOrAction: some View {
        switch resolvedOutcome {
        case .some(.redeemedCredits(let amount, _)):
            PopopxCommerceCardNote(systemImage: "checkmark.seal.fill",
                                   text: Copy.creditRedeemed(amount),
                                   ink: PopopxPalette.successInk)
        case let .some(.failed(error)):
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: gloss(error), ink: PopopxPalette.dangerInk)
        // A badge outcome on a credit card is the same impossible pairing as the reverse case in `PopopxGiftCardBubble`: the button stays,
        // and the vault remains the only thing that decides whether a second redemption can happen.
        case .some(.redeemed), .some(.initiated), .none:
            PopopxButton(opening ? Copy.sending : Copy.redeem,
                         systemImage: opening ? nil : "key.fill",
                         role: .secondary,
                         fullWidth: true,
                         isLoading: opening) {
                await redeem()
            }
        }
    }

    private var resolvedOutcome: PopopxRedemptionOutcome? {
        immediate ?? router.outcomesByVoucher[payload.voucherId]
    }

    private func redeem() async {
        guard case let .contact(contactId) = context.target else { return }
        opening = true
        immediate = nil
        let outcome = await router.redeemCreditInChat(payload, contactId: contactId)
        if case .initiated = outcome {
            PopopxHaptics.notice(.warning)
        } else {
            immediate = outcome
            PopopxHaptics.notice(.error)
        }
        opening = false
    }

    private func gloss(_ error: PopopxBadgeCreditsError) -> String {
        switch error {
        case .connectionUnavailable: Copy.glossUnreachable
        case .voucherAlreadyRedeemed: Copy.glossAlready
        case .signalRejected: Copy.rejected
        case .creditVoucherUnavailable: PopopxCommerceCopy.errorCreditVoucherUnavailable
        default: error.errorDescription ?? Copy.glossGeneric
        }
    }
}

// MARK: - Red packet

/// A credits red packet inside a conversation. The one you sent shows the number of shares; only the one someone else sent offers 'open'.
struct PopopxRedPacketBubble: View {
    let payload: PopopxRedPacketPayload
    let context: PopopxCommerceCardContext

    @State private var credits = PopopxCreditsManager.shared
    @State private var router = PopopxSilentSignalingRouter.shared
    @State private var opening = false
    @State private var receiptStuck = false

    var body: some View {
        PopopxCommerceCardSurface {
            PopopxCommerceCardHeader(
                systemImage: context.incoming ? "gift.fill" : "giftcard.fill",
                title: Copy.title,
                caption: payload.note.isEmpty ? Copy.caption : Copy.note(payload.note),
                ink: PopopxPalette.danger
            )
            amountLine
            Divider().overlay(PopopxPalette.separator)
            state
        }
        .onAppear { credits.loadIfNeeded() }
    }

    private var amountLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, payload.amount))
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.label)
            Text(verbatim: Copy.split(payload.recipients))
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
            Spacer(minLength: PopopxMetrics.spaceS)
        }
    }

    @ViewBuilder private var state: some View {
        if !payload.isSelfSignatureValid || !payload.isAmountAuthorized || payload.amountPerRecipient == nil {
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: Copy.rejected, ink: PopopxPalette.dangerInk)
        } else if credits.hasClaimed(packetId: payload.packetId) {
            claimedRow
        } else if !context.incoming {
            senderRow
        } else if context.target == nil {
            PopopxCommerceCardNote(systemImage: "eye", text: Copy.readOnly, ink: PopopxPalette.labelSecondary)
        } else {
            PopopxButton(Copy.open, systemImage: "gift", role: .secondary,
                         fullWidth: true, isLoading: opening) {
                await open()
            }
        }
    }

    /// The already-opened cell: the amount comes from the payload itself, not a number this device noted ad hoc — after a restart it must still tell the same number.
    private var claimedRow: some View {
        Group {
            PopopxCommerceCardNote(
                systemImage: "checkmark.circle.fill",
                text: Copy.claimed(payload.amountPerRecipient ?? 0),
                ink: PopopxPalette.successInk
            )
            if receiptStuck {
                PopopxButton(Copy.resendReceipt, systemImage: "arrow.clockwise", role: .ghost,
                             fullWidth: false) {
                    await resendReceipt()
                }
            }
        }
    }

    /// Sender's view: the share count shows only when 'this one was sent from this device'; somebody else's packetId means nothing here.
    @ViewBuilder private var senderRow: some View {
        if let packet = credits.pendingPacket(packetId: payload.packetId) {
            PopopxCommerceCardNote(
                systemImage: packet.isFullyClaimed ? "checkmark.seal" : "hourglass",
                text: Copy.sent(packet.claimedCount, packet.recipientCount),
                ink: PopopxPalette.labelSecondary
            )
        } else {
            PopopxCommerceCardNote(systemImage: "arrow.up.right", text: Copy.sentByYou, ink: PopopxPalette.labelSecondary)
        }
    }

    // MARK: Actions

    private func open() async {
        guard let share = payload.amountPerRecipient else {
            opening = false
            return
        }
        opening = true
        do {
            // Credit first, then send the receipt: that share of credits belongs to the opener, and the receipt only affects how much the sender is refunded; it must not in turn decide whether this credit lands.
            let credited = try credits.claimRedPacket(
                packetId: payload.packetId, amountPerRecipient: share, note: payload.note
            )
            if credited {
                PopopxHaptics.notice(.success)
                let delivered = await sendReceipt()
                receiptStuck = !delivered
            } else {
                // Blocked by replay protection (the same packetId was already credited): show it as opened and do not send the receipt again.
                PopopxHaptics.notice(.warning)
            }
        } catch {
            PopopxHaptics.notice(.error)
        }
        opening = false
    }

    private func resendReceipt() async {
        let delivered = await sendReceipt()
        receiptStuck = !delivered
        PopopxHaptics.notice(receiptStuck ? .error : .success)
    }

    private func sendReceipt() async -> Bool {
        guard let target = context.target else { return false }
        return await router.sendRedPacketReceipt(packetId: payload.packetId, to: target)
    }
}

// MARK: - Channel subscription threshold

/// The threshold the channel owner publishes inside the channel. Members see the price and 'subscribe'; the owner sees 'the threshold you published'.
///
/// Three things are true on this card: the price comes from the payload, the signature is checked with the public key carried in the payload, and the deduction goes through
/// `PopopxCreditsManager.subscribeToChannel` (the criterion `1…maximumCreditsThreshold` is checked once more on that side too).
/// one thing it is not: this card **does not change whom the channel can broadcast to** (these channels are one-way broadcasts and the Swift side has no per-person filtering API),
/// so it is the local admission gate; that sentence is written in the subscribe panel's boundary items, not promised again here.
///
/// ### Which two halves anti-impersonation can deliver, and which half it cannot
/// Can do: the card does not count when it lands in a non-channel conversation (`context.isChannel`, and that branch sits before the deduction),
/// and subscribing is refused when "the key recorded by this device's last payment" does not match this message's signing public key (`channelIssuerConflict`).
/// Cannot do: **recognizing from this message whether the one who sent it is an admin of this channel**. On the member side the direction of a channel message is
/// `CIDirection.channelRcv`, and that case carries no `GroupMember` (`ChatTypes.swift:4421-4422`,
/// `groupMemberId` is nil for it: :4440-4442), and the core never hands the author's authoritative public key to Swift either,
/// while this module's signing key is a different P256 key set, so the two sides have no comparable value.
/// So the role can only be judged on the publishing half (`sendChannelAccess`); the forgery window before the first payment is a recorded residual risk.
struct PopopxChannelAccessBubble: View {
    let payload: PopopxChannelAccessPayload
    let context: PopopxCommerceCardContext

    @State private var credits = PopopxCreditsManager.shared
    @State private var showSubscribe = false

    var body: some View {
        PopopxCommerceCardSurface {
            PopopxCommerceCardHeader(
                systemImage: context.incoming ? "lock.fill" : "lock.open.fill",
                title: Copy.channelHeadline,
                caption: Copy.caption(PopopxCommerceFormat.date(payload.publishedAtMs)),
                ink: PopopxPalette.brand
            )
            priceLine
            Divider().overlay(PopopxPalette.separator)
            state
        }
        .onAppear { credits.loadIfNeeded() }
        .sheet(isPresented: $showSubscribe) {
            // the panel queries the old ticket and stacks the days itself (`subscribeToChannel` adds one more period on top of the expiry time),
            // so here only "this conversation + this price" is handed down, without carrying an extra state.
            PopopxChannelSubscriptionSheet(
                channelId: context.chatId,
                channelTitle: context.chatTitle,
                price: payload.price,
                issuerPublicKeyBase64URL: payload.issuerPublicKeyBase64URL,
                receiptTarget: context.target
            )
            .presentationDetents([.large])
        }
    }

    private var priceLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, payload.price))
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.label)
            Text(verbatim: Copy.perPeriod(PopopxCommerceLimits.channelTicketSeconds / 86_400))
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
            Spacer(minLength: PopopxMetrics.spaceS)
        }
    }

    @ViewBuilder private var state: some View {
        if !payload.isPriceAuthorized {
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: Copy.priceRejected, ink: PopopxPalette.dangerInk)
        } else if !payload.isIssuerSignatureValid {
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: Copy.channelRejected, ink: PopopxPalette.dangerInk)
        } else if !context.incoming {
            // The channel owner's own copy: this branch does not deduct its own credits and has no ticket to look at.
            PopopxCommerceCardNote(systemImage: "arrow.up.right", text: Copy.published, ink: PopopxPalette.labelSecondary)
        } else if context.chatId.isEmpty {
            // The host gave no conversation key (the default fallback path). Then "subscribe" would sign a credential whose key is the empty string,
            // and the empty string is the same key across all channels - one deduction and elsewhere it also shows subscribed. Read-only is preferable.
            PopopxCommerceCardNote(systemImage: "eye", text: Copy.readOnlyChannel, ink: PopopxPalette.labelSecondary)
        } else if !context.isChannel {
            // The threshold card lands in a non-channel conversation (direct chat, private group, forwarded screenshot).
            // This branch must sit before the deduction: a forged `popopx://channel` pasted into a direct chat could have deducted credits right here.
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: Copy.notAChannel, ink: PopopxPalette.dangerInk)
        } else if credits.channelIssuerConflict(channelId: context.chatId,
                                                issuerPublicKeyBase64URL: payload.issuerPublicKeyBase64URL) {
            // Not the same key as the publisher recorded by this device's last payment. The coverage and the criterion are both in
            // the `PopopxCreditsManager.channelIssuerConflict` section, not promised again here.
            PopopxCommerceCardNote(systemImage: "xmark.seal", text: Copy.issuerMismatch, ink: PopopxPalette.dangerInk)
        } else if let ticket = credits.ticket(forChannelId: context.chatId) {
            PopopxCommerceCardNote(
                systemImage: "checkmark.seal.fill",
                text: Copy.activeUntil(PopopxCommerceFormat.date(ticket.expiresAtMs)),
                ink: PopopxPalette.successInk
            )
            PopopxButton(Copy.renew, systemImage: "arrow.clockwise", role: .secondary,
                         fullWidth: true) {
                showSubscribe = true
            }
        } else {
            PopopxButton(Copy.subscribe, systemImage: "lock.open", role: .primary,
                         fullWidth: true) {
                showSubscribe = true
            }
        }
    }
}

// MARK: - Copy

private enum Copy {
    // gift card
    static func title(_ days: Int) -> String { String(format: NSLocalizedString("%1$lld-day %2$@", comment: "POPOPX gift card bubble title"), days, PopopxCommerceCopy.badgeProductName) }
    static let caption = NSLocalizedString("A badge voucher sent by the other person", comment: "POPOPX gift card bubble")
    static func note(_ text: String) -> String { String(format: NSLocalizedString("Message: %@", comment: "POPOPX commerce card note"), text) }
    static let redeem = NSLocalizedString("Redeem", comment: "POPOPX gift card bubble")
    static let sending = NSLocalizedString("Waiting for the other side…", comment: "POPOPX gift card bubble")
    static let redeemedHere = NSLocalizedString("This voucher has already been redeemed on this device.", comment: "POPOPX gift card bubble")
    static let sentByYou = NSLocalizedString("This is the one you sent.", comment: "POPOPX commerce card")
    static let readOnly = NSLocalizedString("Read only here: redeeming has to happen in the chat with this contact.", comment: "POPOPX commerce card")
    static let groupUnsupported = NSLocalizedString("Badge vouchers can only be redeemed in a one-to-one chat.", comment: "POPOPX commerce card")
    static let rejected = NSLocalizedString("The signature does not verify: this is not the voucher that was issued.", comment: "POPOPX commerce card")
    static func redeemed(_ days: Int) -> String { String(format: NSLocalizedString("Badge lit for %lld days.", comment: "POPOPX gift card bubble"), days) }
    static let glossUnreachable = NSLocalizedString("Cannot reach the other device: the link may already have expired.", comment: "POPOPX commerce card")
    static let glossAlready = NSLocalizedString("This voucher has already been redeemed.", comment: "POPOPX commerce card")
    static let glossGeneric = NSLocalizedString("This did not complete; you can try again later.", comment: "POPOPX commerce card")

    // compute-credit gift card. The sentences that name the thing the user holds are their own; every sentence that only states a state
    // ("already redeemed on this device", "cannot reach the other device") is reused from the gift card above, because a near-duplicate
    // source sentence in one shared table buys nothing and costs one more translation to keep in step.
    static let creditTitle = NSLocalizedString("Compute Credits gift card", comment: "POPOPX credit gift card bubble")
    static let creditCaption = NSLocalizedString("A Compute Credits gift card sent by the other person", comment: "POPOPX credit gift card bubble")
    static func creditRedeemed(_ credits: Int) -> String { String(format: NSLocalizedString("%lld Compute Credits added.", comment: "POPOPX credit gift card bubble"), credits) }
    static let creditGroupUnsupported = NSLocalizedString("Compute Credits gift cards can only be redeemed in a one-to-one chat.", comment: "POPOPX credit gift card bubble")

    // red packet
    static let open = NSLocalizedString("Open the packet", comment: "POPOPX red packet button")
    static let title = NSLocalizedString("Compute Credits red packet", comment: "POPOPX red packet card")
    static func split(_ count: Int) -> String { count > 1 ? String(format: NSLocalizedString("Split evenly %lld ways", comment: "POPOPX red packet card"), count) : NSLocalizedString("Single recipient", comment: "POPOPX red packet card") }
    static func claimed(_ share: Int) -> String { String(format: NSLocalizedString("Opened · %lld credits credited", comment: "POPOPX red packet card"), share) }
    static func sent(_ claimed: Int, _ total: Int) -> String { String(format: NSLocalizedString("Claimed %1$lld of %2$lld shares", comment: "POPOPX red packet card"), claimed, total) }
    static let resendReceipt = NSLocalizedString("Send the receipt again", comment: "POPOPX red packet card")

    // channel subscription threshold
    static let channelHeadline = NSLocalizedString("Channel subscription threshold", comment: "POPOPX channel card")
    static func caption(_ date: String) -> String { String(format: NSLocalizedString("Published by the channel owner on %@", comment: "POPOPX channel card"), date) }
    static func perPeriod(_ days: Int) -> String { String(format: NSLocalizedString("/ %lld days", comment: "POPOPX channel card price suffix"), days) }
    static let subscribe = NSLocalizedString("Subscribe", comment: "POPOPX channel card")
    static let renew = NSLocalizedString("Renew", comment: "POPOPX channel card")
    static func activeUntil(_ date: String) -> String { String(format: NSLocalizedString("Access valid until %@", comment: "POPOPX channel card"), date) }
    static let published = NSLocalizedString("This is the threshold you published: credits are charged only when a member taps it.", comment: "POPOPX channel card")
    static let channelRejected = NSLocalizedString("The signature does not verify: this is not the entry published by the channel owner.", comment: "POPOPX channel card")
    static let notAChannel = NSLocalizedString("This is not in a channel: a threshold card only counts inside a channel, so no credits are charged here.", comment: "POPOPX channel card")
    static let issuerMismatch = NSLocalizedString("The signing key does not match the publisher recorded on this device from your last payment: either someone forwarded this card, or the channel owner changed devices.", comment: "POPOPX channel card")
    static let priceRejected = NSLocalizedString("This threshold is outside the allowed range (from 1 to the maximum; free needs no published threshold).", comment: "POPOPX channel card")
    static let readOnlyChannel = NSLocalizedString("Read only here: this entry could not be matched to the channel it is in, so credits have to be charged in that channel.", comment: "POPOPX channel card")
}

// MARK: - Previews

/// Signatures in the previews are always fake strings: the card therefore stops at the "does not verify" case.
/// Every state in this card family comes from the Keychain ledger and runtime signatures, and a preview cannot produce the trustworthy one,
/// so this case is kept for the eye; the remaining states are verified on a real device (see the self-test checklist in `Docs/app-store-review-notes.md`).
struct PopopxCommerceCardsDark_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
            PopopxGiftCardBubble(
                payload: PopopxGiftCardPayload(voucherId: "voucher.preview", period: .monthly,
                                               note: "Shielding you for a month", mintedAtMs: 0, signature: "invalid"),
                context: PopopxCommerceCardContext(target: .contact(1), incoming: true)
            )
            PopopxRedPacketBubble(
                payload: PopopxRedPacketPayload(packetId: "packet.preview", amount: 50, recipients: 5,
                                                note: "Happy new year", signature: "invalid"),
                context: PopopxCommerceCardContext(target: .group(2), incoming: true)
            )
            PopopxChannelAccessBubble(
                payload: PopopxChannelAccessPayload(price: 200, publishedAtMs: 0,
                                                    issuerPublicKeyBase64URL: "preview", signature: "invalid"),
                context: PopopxCommerceCardContext(target: .group(2), incoming: true,
                                                   chatId: "#2", chatTitle: "Night flight notes", isChannel: true)
            )
        }
        .padding(PopopxMetrics.gutter)
        .background(PopopxPalette.base)
        .preferredColorScheme(.dark)
    }
}
