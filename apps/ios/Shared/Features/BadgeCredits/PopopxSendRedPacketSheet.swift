//  PopopxSendRedPacketSheet.swift
//
//  [Phase 5 · 7] Sending a credit red packet: debit on this device → sign a card → deliver it into the current chat.
//
//  ### Only four face values, and only divisors for the share count
//  Apple's 3.1.1 reading of virtual-currency gifting is hard: **random amounts carry a gambling character**. So from end to end this page
//  has no "enter an amount" entry at all, only the four tiers in `PopopxCommerceLimits.redPacketAmounts`.
//  The share count is likewise not free-form: it lists only **divisors of the face value**, so each share is a whole number of points by construction,
//  and the `amount % recipientCount == 0` criterion in `PopopxCreditsManager.sendRedPacket`
//  becomes unreachable from this panel's side — there is never a button that can only report an error.
//
//  ### Why an even group split must add a field to the payload
//  The URI written in the spec is `popopx://redpacket?id=&amount=&note=&sig=`. Those four fields express a one-to-one red packet
//  (`amount` being that one share) but not an even group split: the claiming side only has this card to look at, and it must know how big its own share
//  is. Either let the recipient divide by "the head count he assumes" (which anyone can alter), or stuff the count into `note`
//  (that is user text, not an account entry). So the payload gains an `n`, and it **enters the signed original**:
//  altering the share count is just as much a "signature check failed" as altering the amount. This deviation from the spec is written up in `Docs/app-store-review-notes.md`.
//
//  ### A packet that cannot be sent is not refunded, only resent
//  The points are already debited at the `sendRedPacket` step. When the SMP send fails the money is already in this order,
//  and refunding now then letting the user resend equals the same packetId being debited twice, or the first share being claimed while a second copy goes out.
//  So this page keeps the failed order: payload unchanged, packetId unchanged, and "send again" just redelivers the same message.
//  The real fallback is in `refundSettledPackets`: refund once every share is claimed, or refund the remainder when the grace period (`packetClaimGraceSeconds`) expires.
//
//  ### What this layer cannot guarantee, the interface must not pretend it does
//  There is no server-side ledger, so **replay protection on the claiming side exists only in the claimer's own ledger** (the same packetId is credited once).
//  The receipts the sender receives are used only to compute refunds, not to establish title. Therefore:
//  - group packet receipts are deduplicated per member (`recordClaim(packetId:memberKey:)`), so one person resending does not push others out of their shares;
//  - this page promises only "sent" and "returned if nobody claims it"; it does not promise "the other side certainly received it".
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts modifying project.pbxproj.

import SwiftUI

// MARK: - Destination

/// Where the red packet is sent, and how many people it can be split among at most there.
///
/// All three fields are scalars: the host computes them from `ChatInfo` and hands them in, so this panel never knows SMP's chat types
/// (`ChatInfo` is an enum with associated values; pattern-matching here would nail this file to POPOPXChat,
/// and would also force previews to build a real chat).
struct PopopxPacketDestination: Hashable {
    let displayName: String
    let target: PopopxCommerceTarget
    /// How many shares this chat can receive at most. Always 1 for a one-to-one chat; for a group it is the member count minus yourself.
    let recipientCap: Int

    static func contact(id: Int64, name: String) -> PopopxPacketDestination {
        PopopxPacketDestination(displayName: name, target: .contact(id), recipientCap: 1)
    }

    /// `memberCount` includes yourself. **The minus one is because you are the one sending**; when the member count is unavailable it is treated as 1,
    /// better to send a single-share packet than to send an order nobody can finish claiming and that hangs for thirty days.
    ///
    /// After the 2026-11-19 ruling, **the send entry no longer builds destinations for group chats** (`popopxPacketDestination` in `ComposeView`
    /// accepts only one-to-one chats, for the reasons written in that cell's comment: with no server-side ledger, concurrent splitting in a group could at worst credit too much).
    /// This case is kept for two reasons, neither of which is "might be useful later":
    /// ① the share-count family of entries still has to be understood — a card with `n>1` minted on someone else's device comes in,
    ///    `PopopxPendingRedPacket.recipientCount` and the refund criterion are computed from it, and deleting this branch would mean miscounting a received packet;
    /// ② previews use it to show the "split evenly into N shares" cell, which would otherwise never appear in CI's layout evidence.
    static func group(id: Int64, name: String, memberCount: Int) -> PopopxPacketDestination {
        PopopxPacketDestination(
            displayName: name,
            target: .group(id),
            recipientCap: max(1, min(memberCount - 1, PopopxCommerceLimits.maximumPacketRecipients))
        )
    }

    /// Selectable share counts: divisors of the face value that do not exceed this chat's head-count limit. Ascending, and the first is always 1.
    func recipientOptions(for amount: Int) -> [Int] {
        guard amount > 0 else { return [1] }
        let ceiling = max(1, min(recipientCap, PopopxCommerceLimits.maximumPacketRecipients))
        var options: [Int] = []
        for count in 1...ceiling where amount % count == 0 {
            options.append(count)
        }
        return options
    }
}

// MARK: - Panel

struct PopopxSendRedPacketSheet: View {
    let destination: PopopxPacketDestination

    @Environment(\.dismiss) private var dismiss

    @State private var credits = PopopxCreditsManager.shared
    @State private var router = PopopxSilentSignalingRouter.shared
    @State private var amount = PopopxCommerceLimits.redPacketAmounts[0]
    @State private var recipients = 1
    @State private var note = ""
    @State private var stage: PopopxPacketStage = .idle

    var body: some View {
        PopopxSheetContainer(PopopxCommerceCopy.redPacketTitle, subtitle: Copy.subtitle(destination.displayName)) {
            content
        } footer: {
            footer
        }
        .task { credits.loadIfNeeded() }
    }

    // MARK: Layout

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                balanceCard
                amountCard
                if recipientOptions.count > 1 {
                    recipientsCard
                }
                noteCard
                statusCard
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
        .onChange(of: amount) { _, newValue in
            // Changing tier has to pull the share count back into the legal domain: the 5 shares chosen on the 50-point tier still hold there but not on the 10-point tier.
            let options = destination.recipientOptions(for: newValue)
            recipients = options.contains(recipients) ? recipients : 1
        }
    }

    private var balanceCard: some View {
        PopopxSectionCard(Copy.balanceTitle, footnote: Copy.balanceFootnote) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: PopopxCommerceCopy.creditsBalance)
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                Spacer(minLength: PopopxMetrics.spaceS)
                Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, credits.balance))
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.label)
            }
            if credits.balance < amount {
                Divider().overlay(PopopxPalette.separator)
                Text(verbatim: String(format: PopopxCommerceCopy.errorInsufficientCreditsFormat, amount, credits.balance))
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var amountCard: some View {
        PopopxSectionCard(Copy.amountTitle, footnote: PopopxCommerceCopy.redPacketFixedAmountsStatement) {
            PopopxSegmentedControl(
                PopopxCommerceLimits.redPacketAmounts.map { .init(selection: $0, title: "\($0)") },
                title: { Copy.tierTitle($0) },
                selection: $amount
            )
        }
    }

    private var recipientsCard: some View {
        PopopxSectionCard(Copy.recipientsTitle, footnote: Copy.recipientsFootnote) {
            VStack(spacing: PopopxMetrics.space2XS) {
                ForEach(recipientOptions, id: \.self) { count in
                    PopopxRadioRow(
                        Copy.splitTitle(count),
                        note: Copy.splitNote(amount / count),
                        selected: recipients == count
                    ) {
                        recipients = count
                        PopopxHaptics.selection()
                    }
                }
            }
        }
    }

    private var noteCard: some View {
        PopopxSectionCard(Copy.noteTitle, footnote: Copy.noteFootnote) {
            PopopxTextField(Copy.noteLabel, prompt: Copy.notePrompt, text: $note, systemImage: "text.badge.plus")
                .onChange(of: note) { _, value in
                    let limit = PopopxCommerceLimits.maximumNoteCharacters
                    if value.count > limit { note = String(value.prefix(limit)) }
                }
        }
    }

    @ViewBuilder private var statusCard: some View {
        switch stage {
        case .idle, .busy:
            boundariesCard
        case let .sent(packet):
            resultCard(
                symbol: "giftcard.fill",
                color: PopopxPalette.successInk,
                headline: Copy.sentHeadline(packet.amount, packet.recipientCount),
                detail: Copy.sentDetail(packet.recipientCount, packet.claimedCount)
            )
        case .undelivered:
            resultCard(
                symbol: "exclamationmark.arrow.triangle.2.circlepath",
                color: PopopxPalette.dangerInk,
                headline: Copy.undeliveredHeadline,
                detail: Copy.undeliveredDetail
            )
        case let .refused(error):
            resultCard(
                symbol: "xmark.circle",
                color: PopopxPalette.dangerInk,
                headline: Copy.refusedHeadline,
                detail: gloss(error)
            )
        }
    }

    private func resultCard(symbol: String, color: Color, headline: String, detail: String) -> some View {
        PopopxSectionCard {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                    Image(systemName: symbol)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(color)
                    Text(verbatim: headline)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(color)
                }
                Text(verbatim: detail)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            if case let .undelivered(_, payload) = stage {
                PopopxButton(Copy.retry, systemImage: "arrow.clockwise", isLoading: false) {
                    await resend(payload)
                }
            } else if case .sent = stage {
                PopopxButton(Copy.again, systemImage: "plus", role: .secondary) { reset() }
            } else {
                PopopxButton(Copy.send(total), systemImage: "giftcard.fill",
                             isLoading: stage == .busy) {
                    await send()
                }
                .disabled(!canSend)
            }
            PopopxButton(Copy.close, role: .ghost) { dismiss() }
        }
    }

    // MARK: Actions

    private var recipientOptions: [Int] { destination.recipientOptions(for: amount) }
    private var total: Int { amount }
    private var canSend: Bool {
        stage != .busy && credits.balance >= amount && recipientOptions.contains(recipients)
    }

    private func send() async {
        guard canSend else { return }
        stage = .busy
        let packet: PopopxPendingRedPacket
        do {
            packet = try credits.sendRedPacket(amount: amount, recipientCount: recipients, note: note)
        } catch let error as PopopxBadgeCreditsError {
            stage = .refused(error)
            PopopxHaptics.notice(.error)
            return
        } catch {
            stage = .refused(.keychainUnavailable)
            PopopxHaptics.notice(.error)
            return
        }
        // A payload that cannot be built = this device's signing key is unavailable right now. The points are already debited, so this order must never be forgotten:
        // it stays in `pendingPackets`, and when the grace period expires `refundSettledPackets` returns it.
        guard let payload = PopopxRedPacketPayload.make(
            packetId: packet.packetId, amount: packet.amount,
            recipients: packet.recipientCount, note: packet.note
        ) else {
            stage = .refused(.verificationFailed)
            PopopxHaptics.notice(.error)
            return
        }
        await deliver(packet, payload)
    }

    /// Redelivering the same payload: no new debit and no change of packetId.
    private func resend(_ payload: PopopxRedPacketPayload) async {
        guard case let .undelivered(packet, _) = stage else { return }
        stage = .busy
        await deliver(packet, payload)
    }

    private func deliver(_ packet: PopopxPendingRedPacket, _ payload: PopopxRedPacketPayload) async {
        if await router.sendRedPacket(payload, to: destination.target) {
            stage = .sent(packet)
            PopopxHaptics.notice(.success)
        } else {
            stage = .undelivered(packet, payload)
            PopopxHaptics.notice(.warning)
        }
    }

    private func reset() {
        stage = .idle
        note = ""
        recipients = 1
    }

    private func gloss(_ error: PopopxBadgeCreditsError) -> String {
        switch error {
        case let .insufficientCredits(balance, required): Copy.glossShortfall(required, balance)
        case .keychainUnavailable: Copy.glossKeychain
        case .verificationFailed: Copy.glossSigning
        default: error.errorDescription ?? Copy.glossGeneric
        }
    }
}

// MARK: - Stages

/// "sent" and "claimed" are two different things, so `.sent` carries the local order rather than a tick mark.
enum PopopxPacketStage: Hashable {
    case idle
    case busy
    case sent(PopopxPendingRedPacket)
    /// Points debited, message not delivered: the payload is kept for the user to redeliver.
    case undelivered(PopopxPendingRedPacket, PopopxRedPacketPayload)
    case refused(PopopxBadgeCreditsError)
}

// MARK: - Copy

private extension PopopxSendRedPacketSheet {
    enum Copy {
        static func subtitle(_ name: String) -> String { String(format: NSLocalizedString("Send Compute Credits to %@ as a red packet. The amount is fixed and split evenly.", comment: ""), name) }
        static let balanceTitle = NSLocalizedString("Balance on this device", comment: "")
        static let balanceFootnote = NSLocalizedString("The credits exist only on this device; every debit and every refund is written to the ledger on it.", comment: "")
        static let amountTitle = NSLocalizedString("Amount (total)", comment: "")
        static func tierTitle(_ value: Int) -> String { String(format: NSLocalizedString("%lld credits", comment: ""), value) }
        static let recipientsTitle = NSLocalizedString("How many people to split between", comment: "")
        static let recipientsFootnote = NSLocalizedString("Only the counts that divide the amount are listed, so every part is a whole number of credits.", comment: "")
        static func splitTitle(_ count: Int) -> String { count == 1 ? NSLocalizedString("Not split, one part", comment: "") : String(format: NSLocalizedString("Split evenly into %lld parts", comment: ""), count) }
        static func splitNote(_ each: Int) -> String { String(format: NSLocalizedString("%lld credits each", comment: ""), each) }
        static let noteTitle = NSLocalizedString("Note", comment: "")
        static let noteLabel = NSLocalizedString("Greeting", comment: "")
        static let notePrompt = NSLocalizedString("Wishing you prosperity", comment: "")
        static var noteFootnote: String { String(format: NSLocalizedString("Up to %lld characters. It travels with the red packet.", comment: ""), PopopxCommerceLimits.maximumNoteCharacters) }
        static let boundariesTitle = NSLocalizedString("What this screen promises, and what it does not", comment: "")
        static var boundariesFootnote: String {
            String(format: PopopxCommerceCopy.redPacketRefundStatementFormat,
                   PopopxCommerceLimits.packetClaimGraceSeconds / 86_400)
        }
        static let boundaryOne = PopopxCommerceCopy.redPacketFixedAmountsStatement
        static let boundaryTwo = NSLocalizedString("The packet has to reach the other device: while it is undelivered the credits stay on your entry here and can be resent unchanged.", comment: "")
        static var boundaryThree: String {
            String(format: PopopxCommerceCopy.redPacketRefundStatementFormat, PopopxCommerceLimits.packetClaimGraceSeconds / 86_400)
        }
        static let close = NSLocalizedString("Close", comment: "")
        static let again = NSLocalizedString("Send another", comment: "")
        static let retry = NSLocalizedString("Send again", comment: "")
        static func send(_ value: Int) -> String { String(format: NSLocalizedString("Send a red packet of %lld credits", comment: ""), value) }
        static func sentHeadline(_ value: Int, _ count: Int) -> String { String(format: NSLocalizedString("Sent %1$lld credits · %2$lld parts", comment: ""), value, count) }
        static func sentDetail(_ count: Int, _ claimed: Int) -> String {
            String(format: NSLocalizedString("Claimed %1$lld of %2$lld parts. The count follows the receipts and keeps updating after you close this screen.", comment: ""), claimed, count)
        }
        static let undeliveredHeadline = NSLocalizedString("This packet was not delivered", comment: "")
        static let undeliveredDetail = NSLocalizedString("The credits were taken for this packet and no second one was opened. Resend it unchanged, or try again later.", comment: "")
        static let refusedHeadline = NSLocalizedString("This packet did not go through", comment: "")
        static func glossShortfall(_ required: Int, _ balance: Int) -> String {
            String(format: NSLocalizedString("You are short %lld credits. Top up first, then come back to this screen.", comment: ""), required - balance)
        }
        static let glossKeychain = NSLocalizedString("The secure store on this device could not be reached, and no credits moved.", comment: "")
        static let glossSigning = NSLocalizedString("The signature could not be obtained: the credits stay with this packet and are returned automatically when the grace period ends.", comment: "")
        static let glossGeneric = NSLocalizedString("This did not complete, and no credits were taken.", comment: "")
    }
}

// MARK: - Previews

struct PopopxSendRedPacketSheetDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxSendRedPacketSheet(destination: .contact(id: 1, name: "Ah Xun"))
            .preferredColorScheme(.dark)
    }
}

struct PopopxSendRedPacketSheetLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxSendRedPacketSheet(destination: .group(id: 2, name: "Weekend Ride", memberCount: 9))
            .preferredColorScheme(.light)
    }
}
