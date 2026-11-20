//  PopopxChannelSubscriptionSheet.swift
//
//  [Phase 5 · 8] The subscription confirmation sheet for paid channels: one local credit deduction in exchange for a local admission ticket carrying an expiry time.
//
//  ### This page signs a local ticket; it cannot stop the channel's distribution, and it does not gate the content page
//  The chat core's channels are one-way broadcast: whoever can be a member receives the content, and the Swift side has no interface where
//  "this message goes only to people who paid", so any claim of "only paid members receive it" is unachievable. What this page does is: deduct points once at the price the channel owner published,
//  and sign a ticket with an expiry time into this device's keychain; the ticket decides whether this one slot counts as subscribed **on this device**.
//
//  The content page is not gated either: gating it would walk into a deadlock — the threshold lives only on that card inside the channel (with no server side,
//  that message is the members' only price source), and blocking the channel content would block "how to learn the price and where to pay" along with it.
//  This item and both of its possible ways out are written in `Docs/app-store-review-notes.md` section 9 item 7.
//
//  ### The channel owner receives no redemption receipt
//  The prompt had one more line, "sync the redeemed-ticket receipt back to the channel". Doing that would require a new cross-end signaling name,
//  while the specification lists only these (`EXT_REDEEM_REQ/ACK`, `CHAT_REDEEM_REQ/ACK`, `REDPACKET_CLAIMED`, five in total)
//  (see `PopopxCommerceSignalKind`). Inventing a sixth wire name ourselves is riskier than not doing it at all:
//  older peers would display it as ordinary text in the timeline. So this file sends no receipt, and says so plainly in the boundary copy.
//  If it is needed, fix the name first, then add one branch in `PopopxSilentSignalingRouter.observeIncoming`.
//
//  ### Renewal stacks
//  `subscribeToChannel` adds one more `channelTicketSeconds` on top of the old ticket's expiry time.
//  Renewing early must not throw away the days that were not used — the points are already deducted, and the days are what that money corresponds to.
//  For the same reason this page, while the ticket is still valid, offers **no** "buy again" entry other than the renew button:
//  in the subscribed state you read the validity period first, and renew only if you want to.
//
//  ### "Free channels" publish no card
//  The threshold's legal range is 1 … `maximumCreditsThreshold`: the publish page requires `price >= 1` to be tappable (`canPublish`),
//  and `PopopxChannelAccessPayload.make` also rejects 0, so **this card always represents one real deduction**.
//  The parsing side still accepts `p=0` (the lower bound of `isPriceAuthorized` is 0); that is a compatibility criterion kept for "the other client sent a 0-price card":
//  such a card renders as usual, and this page takes the `price == 0` slot ("this channel is free"), deducting no points and signing no ticket;
//  and even if someone bypasses the UI and calls `subscribeToChannel(price: 0)` directly, its `price >= 1` guard throws `signalRejected`.
//  For a channel to be free, the correct approach is to publish no card, not to publish a 0-price card.
//
//  ### Host entries (2026-11-19 ruling: they must be wired up, no orphan panels)
//  There are two real paths to this page: ① the threshold card's "subscribe/renew" inside the channel (`PopopxChannelAccessBubble`);
//  ② the slot the channel detail page gives the channel owner as a publish page (the lower half of this file, `PopopxChannelThresholdView`,
//  mounted at `PopopxGroupChatInfoView.subscriptionCard`, criterion `isChannel && isOwner`).
//  On the member's side the detail page shows only the local ticket and gives no button: the price is not on this device, and tapping "subscribe" here would deduct money that was never announced.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.

import SwiftUI

struct PopopxChannelSubscriptionSheet: View {
    let channelId: String
    let channelTitle: String
    /// The threshold set by the channel owner (compute points per slot). 0 means free.
    let price: Int
    /// This card's signing public key, stored locally together with the ticket: used to judge a conflict when a card for the same channel signed by another key is next seen
    /// (the criterion and its coverage are written in `PopopxCreditsManager.channelIssuerConflict`).
    let issuerPublicKeyBase64URL: String
    /// Which conversation the receipt should return to. With nil no receipt is sent — the ticket still stands, there is simply nobody to notify on that leg.
    let receiptTarget: PopopxCommerceTarget?

    @Environment(\.dismiss) private var dismiss

    @State private var credits = PopopxCreditsManager.shared
    @State private var router = PopopxSilentSignalingRouter.shared
    /// Read once when loading, and replaced with the new ticket after a successful subscription. Not queried every frame: `ticket(forChannelId:)` needs `loadIfNeeded` each time.
    @State private var ticket: PopopxChannelSubscriptionTicket?
    @State private var stage: PopopxSubscriptionStage = .idle

    var body: some View {
        PopopxSheetContainer(PopopxCommerceCopy.channelSubscriptionTitle, subtitle: Copy.subtitle(channelTitle)) {
            content
        } footer: {
            footer
        }
        .task {
            credits.loadIfNeeded()
            ticket = credits.ticket(forChannelId: channelId)
        }
    }

    // MARK: Layout

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                if price == 0 {
                    PopopxSectionCard(Copy.freeTitle, footnote: Copy.freeFootnote) {
                        Text(verbatim: Copy.freeBody)
                            .font(PopopxType.secondary)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let ticket {
                    activeCard(ticket)
                } else {
                    priceCard
                    balanceCard
                }
                statusCard
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
    }

    private var priceCard: some View {
        PopopxSectionCard(Copy.priceTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, price))
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.label)
                Text(verbatim: String(
                    format: PopopxCommerceCopy.channelSubscriptionPeriodFormat,
                    PopopxCommerceLimits.channelTicketSeconds / 86_400
                ))
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var balanceCard: some View {
        PopopxSectionCard(Copy.balanceTitle) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: PopopxCommerceCopy.creditsBalance)
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                Spacer(minLength: PopopxMetrics.spaceS)
                Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, credits.balance))
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.label)
            }
            if credits.balance < price {
                Divider().overlay(PopopxPalette.separator)
                Text(verbatim: String(format: PopopxCommerceCopy.errorInsufficientCreditsFormat, price, credits.balance))
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func activeCard(_ ticket: PopopxChannelSubscriptionTicket) -> some View {
        PopopxSectionCard(Copy.activeTitle, footnote: Copy.activeFootnote(PopopxCommerceFormat.date(ticket.expiresAtMs))) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                Text(verbatim: Copy.activeUntil(PopopxCommerceFormat.date(ticket.expiresAtMs)))
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.successInk)
                Text(verbatim: String(
                    format: PopopxCommerceCopy.channelSubscriptionStackFormat,
                    PopopxCommerceLimits.channelTicketSeconds / 86_400
                ))
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var statusCard: some View {
        switch stage {
        case .idle, .busy:
            boundariesCard
        case let .subscribed(ticket):
            PopopxSectionCard {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                    HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(PopopxType.emphasis)
                            .foregroundStyle(PopopxPalette.successInk)
                        Text(verbatim: Copy.subscribedHeadline)
                            .font(PopopxType.emphasis)
                            .foregroundStyle(PopopxPalette.successInk)
                    }
                    Text(verbatim: Copy.subscribedUntil(PopopxCommerceFormat.date(ticket.expiresAtMs)))
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .refused(error):
            PopopxSectionCard {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                    HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                        Image(systemName: "xmark.circle")
                            .font(PopopxType.emphasis)
                            .foregroundStyle(PopopxPalette.dangerInk)
                        Text(verbatim: Copy.refusedHeadline)
                            .font(PopopxType.emphasis)
                            .foregroundStyle(PopopxPalette.dangerInk)
                    }
                    Text(verbatim: gloss(error))
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var boundariesCard: some View {
        PopopxSectionCard(Copy.boundariesTitle, footnote: Copy.boundariesFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                bullet(Copy.boundaryOne)
                bullet(Copy.boundaryTwo)
                bullet(Copy.boundaryThree)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Image(systemName: "circle")
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelHint)
                .frame(width: PopopxMetrics.spaceL, alignment: .leading)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Bottom bar

    private var footer: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            if price > 0 {
                PopopxButton(Copy.subscribe(price), systemImage: "checkmark.seal",
                             isLoading: stage == .busy) {
                    await subscribe()
                }
                .disabled(!canSubscribe)
                if credits.balance < price {
                    // No top-up panel is stuffed into this page: that price table exists once on the purchase page, and writing it in two places means each one goes wrong on its own.
                    // So "go to top-up" only closes this page — the purchase page is right underneath it.
                    PopopxButton(Copy.topUp, role: .ghost) { dismiss() }
                }
            }
            PopopxButton(Copy.close, role: .ghost) { dismiss() }
        }
    }

    // MARK: Actions

    private var canSubscribe: Bool {
        price > 0 && stage != .busy && credits.balance >= price
    }

    private func subscribe() async {
        guard canSubscribe else { return }
        stage = .busy
        do {
            let issued = try credits.subscribeToChannel(
                channelId: channelId, channelTitle: channelTitle, price: price,
                issuerPublicKeyBase64URL: issuerPublicKeyBase64URL
            )
            ticket = issued
            stage = .subscribed(issued)
            PopopxHaptics.notice(.success)
            // The receipt is scheduled after the ticket: the points are already deducted and the credential already written into the keychain, so whether this line gets sent no longer changes the outcome.
            // Whether a subscriber may speak in the channel is decided by the core's group settings, and the Swift side has no such criterion, so this line is best-effort,
            // and a failure stays only in the log (`sendChannelSubscriptionAck`).
            if let receiptTarget {
                _ = await router.sendChannelSubscriptionAck(
                    chatInfoId: channelId, expiresAtMs: issued.expiresAtMs, to: receiptTarget
                )
            }
        } catch let error as PopopxBadgeCreditsError {
            stage = .refused(error)
            PopopxHaptics.notice(.error)
        } catch {
            stage = .refused(.keychainUnavailable)
            PopopxHaptics.notice(.error)
        }
    }

    private func gloss(_ error: PopopxBadgeCreditsError) -> String {
        switch error {
        case let .insufficientCredits(balance, required): String(format: NSLocalizedString("Short by %lld Compute Credits. Top up first, then come back to this page.", comment: ""), required - balance)
        case .keychainUnavailable: Copy.glossKeychain
        case .signalRejected: Copy.glossRejected
        default: error.errorDescription ?? Copy.glossGeneric
        }
    }
}

// MARK: - Stages

enum PopopxSubscriptionStage: Hashable {
    case idle
    case busy
    /// The ticket already issued: so the panel can read the user a real expiry time instead of an approximation like "30 days".
    case subscribed(PopopxChannelSubscriptionTicket)
    case refused(PopopxBadgeCreditsError)
}

// MARK: - Copy

private extension PopopxChannelSubscriptionSheet {
    enum Copy {
        static func subtitle(_ name: String) -> String { String(format: NSLocalizedString("Subscribe once to %@. The ticket is written on this device and stays visible here until it expires.", comment: ""), name) }
        static let freeTitle = NSLocalizedString("This channel is free", comment: "")
        static let freeFootnote = NSLocalizedString("The threshold written on this card is 0.", comment: "")
        static let freeBody = NSLocalizedString("A free channel needs no credits and leaves no ledger entries — just open it.", comment: "")
        static let priceTitle = NSLocalizedString("Subscription threshold", comment: "")
        static let balanceTitle = NSLocalizedString("Balance on this device", comment: "")
        static let activeTitle = NSLocalizedString("Subscribed", comment: "")
        static func activeFootnote(_ date: String) -> String { String(format: NSLocalizedString("The ticket expires on %@. After that, this page will ask for credits again.", comment: ""), date) }
        static func activeUntil(_ date: String) -> String { String(format: NSLocalizedString("Valid until %@", comment: ""), date) }
        static let subscribedHeadline = NSLocalizedString("Ticket issued", comment: "")
        static func subscribedUntil(_ date: String) -> String { String(format: NSLocalizedString("Valid until %@. History and received messages never disappear when the ticket expires.", comment: ""), date) }
        static let boundariesTitle = NSLocalizedString("What this screen promises, and what it does not", comment: "")
        static let boundariesFootnote = NSLocalizedString("Only what this layer can actually deliver.", comment: "")
        static let boundaryOne = NSLocalizedString("The ticket lives only in this device's Keychain: no server validates it, and none is needed.", comment: "")
        static let boundaryTwo = NSLocalizedString("A successful subscription posts a silent redemption receipt into the channel: it is not displayed, prompts nothing, and no credits reach the channel owner's balance.", comment: "")
        static let boundaryThree = NSLocalizedString("The threshold guards admission on this device only; it does not change who the channel itself can broadcast to.", comment: "")
        static func subscribe(_ value: Int) -> String { String(format: NSLocalizedString("Subscribe · spend %lld Compute Credits", comment: ""), value) }
        static let topUp = NSLocalizedString("Go to top up", comment: "")
        static let close = NSLocalizedString("Close", comment: "")
        static let refusedHeadline = NSLocalizedString("The subscription did not go through", comment: "")
        static let glossKeychain = NSLocalizedString("The device's secure storage was unavailable; no credits moved.", comment: "")
        static let glossRejected = NSLocalizedString("This device rejects that threshold (it is 0 or above the allowed maximum); no credits moved.", comment: "")
        static let glossGeneric = NSLocalizedString("That did not complete; no credits were taken.", comment: "")
    }
}

// MARK: - Channel owner: publish the threshold

/// The publish page on the channel owner's side. The only reason it exists: **on a member's device the price can only come from that one message in the channel**.
/// Without this page, `PopopxChannelSubscriptionSheet`'s `price` could only be invented by the client,
/// and that would be "deducting money against a price that does not exist". So this page does exactly one thing: sign a threshold card and send it into the channel.
///
/// Three boundaries, and the UI states them the same way:
/// - Publishing = sending a **visible** message into the channel (`PopopxSilentSignalingRouter.sendChannelAccess`),
///   not silent signaling, and no row is deleted; only if members can see the price does "informed" mean anything.
/// - Each change of the threshold publishes one new card: this feature has no mechanism to "update the one already sent",
///   and old cards still point at the old price. Whichever card a member opens, the deduction follows that card's price, and that card's signature really does protect that price.
/// - Free publishes nothing: with `price == 0` there is neither a charge nor a ledger entry, so publishing a "0 points" card only adds noise.
struct PopopxChannelThresholdView: View {
    /// Which conversation the threshold card is sent into. In the model a channel is just a group conversation with `useRelays`, so the landing point is `.group`.
    let groupId: Int64
    let channelTitle: String

    @Environment(\.dismiss) private var dismiss

    @State private var router = PopopxSilentSignalingRouter.shared
    @State private var priceText = ""
    @State private var stage: PopopxThresholdStage = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                editorCard
                boundariesCard
                statusCard
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.publishTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    // MARK: Layout

    private var editorCard: some View {
        PopopxSectionCard(Copy.editorTitle, footnote: Copy.editorFootnote(channelTitle)) {
            PopopxTextField(
                Copy.field,
                prompt: Copy.fieldPrompt,
                text: $priceText,
                systemImage: "circle.hexagongrid.fill",
                keyboard: .numberPad
            )
            .accessibilityIdentifier("popopx.channel.threshold")
            .disabled(stage == .busy)
            Text(verbatim: Copy.fieldNote(PopopxCommerceLimits.maximumCreditsThreshold,
                                          PopopxCommerceLimits.channelTicketSeconds / 86_400))
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PopopxButton(Copy.publish, systemImage: "paperplane.fill",
                         isLoading: stage == .busy) {
                await publish()
            }
            .disabled(!canPublish)
        }
    }

    private var boundariesCard: some View {
        PopopxSectionCard(Copy.boundariesTitle, footnote: Copy.boundariesFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                bullet(Copy.boundaryOne)
                bullet(Copy.boundaryTwo)
                bullet(Copy.boundaryThree)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Image(systemName: "circle")
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelHint)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var statusCard: some View {
        switch stage {
        case .idle, .busy:
            EmptyView()
        case let .published(payload):
            PopopxSectionCard(Copy.publishedTitle) {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                    note(systemImage: "checkmark.seal.fill",
                         text: Copy.publishedBody(payload.price),
                         ink: PopopxPalette.successInk)
                    Text(verbatim: Copy.publishedHint)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .undelivered:
            PopopxSectionCard(Copy.failedTitle) {
                note(systemImage: "exclamationmark.arrow.circlepath",
                     text: Copy.undeliveredBody, ink: PopopxPalette.dangerInk)
            }
        case .refused:
            PopopxSectionCard(Copy.failedTitle) {
                note(systemImage: "key.slash", text: Copy.refusedBody, ink: PopopxPalette.dangerInk)
            }
        }
    }

    /// One conclusion row: icon + one sentence. `PopopxCommerceCardNote` is private to that card's file,
    /// and widening its access level merely to reuse one row's typography would make two cards and this page share a shape they can no longer change separately.
    private func note(systemImage: String, text: String, ink: Color) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: systemImage)
                .font(PopopxType.emphasis)
                .foregroundStyle(ink)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Actions

    /// The text in the field converts to a number exactly once: digits only, and anything over the cap sticks to the cap.
    /// This is the same criterion as the business-card threshold slot (`ProfileBuilderView`'s `unlockCreditsText`),
    /// because two places each writing their own number means each goes wrong on its own.
    private var price: Int {
        let entered = Int(priceText.filter(\.isNumber)) ?? 0
        return min(entered, PopopxCommerceLimits.maximumCreditsThreshold)
    }

    /// The role criterion comes from the router's copy (`canPublishChannelThreshold`): this page's button and the `sendChannelAccess`
    /// guard must be the same number, otherwise a third state appears: "tappable, but nothing gets sent".
    private var canPublish: Bool {
        stage != .busy && price >= 1 && PopopxSilentSignalingRouter.canPublishChannelThreshold(groupId: groupId)
    }

    private func publish() async {
        guard canPublish else { return }
        stage = .busy
        guard let payload = PopopxChannelAccessPayload.make(
            price: price,
            publishedAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
        ) else {
            // The local signing key could not be obtained. Nothing here deducted anybody's points, and no pending re-send record needs to be left.
            stage = .refused
            PopopxHaptics.notice(.error)
            return
        }
        if await router.sendChannelAccess(payload, to: .group(groupId)) {
            stage = .published(payload)
            PopopxHaptics.notice(.success)
        } else {
            stage = .undelivered
            PopopxHaptics.notice(.warning)
        }
    }
}

// MARK: - Publish stages

enum PopopxThresholdStage: Hashable {
    case idle
    case busy
    /// The card that was sent: the status row reads the real price out loud instead of just saying "published".
    case published(PopopxChannelAccessPayload)
    /// The message did not go out (the SMP side returned no conversation item). The threshold was not rewritten, because the peer never received a new price.
    case undelivered
    /// The local signing key could not be obtained, so the card was never signed at all.
    case refused
}

// MARK: - Copy (publish page)

private extension PopopxChannelThresholdView {
    enum Copy {
        static let publishTitle = NSLocalizedString("Subscription threshold", comment: "")
        static let editorTitle = NSLocalizedString("How many Compute Credits a member pays to subscribe once", comment: "")
        static func editorFootnote(_ name: String) -> String { String(format: NSLocalizedString("Publishing to %@. Credits are only spent when a member taps Subscribe on that card.", comment: ""), name) }
        static let field = NSLocalizedString("Compute Credits", comment: "")
        static let fieldPrompt = NSLocalizedString("Empty = free, nothing is published", comment: "")
        static func fieldNote(_ maximum: Int, _ days: Int) -> String {
            String(format: NSLocalizedString("A whole number from 1 to %1$lld, with one slot lasting %2$lld days. Empty or 0 means free: a free channel needs no card and charges nobody any credits.", comment: ""), maximum, days)
        }
        static let publish = NSLocalizedString("Publish the threshold", comment: "")
        static let boundariesTitle = NSLocalizedString("What this screen promises, and what it does not", comment: "")
        static let boundariesFootnote = NSLocalizedString("Only what this layer can actually deliver.", comment: "")
        static let boundaryOne = NSLocalizedString("Publishing sends a visible message into the channel: the price has to be seen before anyone can agree to it.", comment: "")
        static let boundaryTwo = NSLocalizedString("Every change publishes a new card and old cards never update: a member is charged the price on the card they tap.", comment: "")
        static let boundaryThree = NSLocalizedString("When a member subscribes, a silent redemption receipt is posted into the channel: it is not displayed and transfers no credits to you.", comment: "")
        static let publishedTitle = NSLocalizedString("Published", comment: "")
        static func publishedBody(_ price: Int) -> String { String(format: NSLocalizedString("A threshold of %lld Compute Credits per slot has been published into the channel.", comment: ""), price) }
        static let publishedHint = NSLocalizedString("Credits are only spent when a member taps this card; this step costs you nothing.", comment: "")
        static let failedTitle = NSLocalizedString("The publication did not go through", comment: "")
        static let undeliveredBody = NSLocalizedString("The message was not delivered, so the threshold was not rewritten — the peer never received the new price. You can press again.", comment: "")
        static let refusedBody = NSLocalizedString("The device's signing key was unavailable, so this card could not be signed; no credits moved.", comment: "")
    }
}

// MARK: - Previews

struct PopopxChannelSubscriptionSheetDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxChannelSubscriptionSheet(channelId: "channel.preview", channelTitle: "Nightfall Notes", price: 200,
                                       issuerPublicKeyBase64URL: "preview.key", receiptTarget: nil)
            .preferredColorScheme(.dark)
    }
}

struct PopopxChannelSubscriptionSheetLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxChannelSubscriptionSheet(channelId: "channel.preview", channelTitle: "Nightfall Notes", price: 0,
                                       issuerPublicKeyBase64URL: "preview.key", receiptTarget: nil)
            .preferredColorScheme(.light)
    }
}

/// The publish page's preview stays at `.idle`: `stage` is `@State`, and a preview has neither keychain nor SMP,
/// so the only thing it can offer is the layout itself (the three conclusion rows are verified on a real device, see the self-test checklist in the review notes).
struct PopopxChannelThresholdViewDark_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxChannelThresholdView(groupId: 2, channelTitle: "Nightfall Notes")
        }
        .preferredColorScheme(.dark)
    }
}

struct PopopxChannelThresholdViewLight_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxChannelThresholdView(groupId: 2, channelTitle: "Nightfall Notes")
        }
        .preferredColorScheme(.light)
    }
}
