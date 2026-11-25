//  PopopxBadgeCapsuleView.swift
//
//  [Phase 5 · 1] The badge capsule in the top bar, with its three states and three exits.
//
//  ### Why the colors are not the three raw values from the prompt
//  The prompt named cyber cyan #00F0FF / emerald green #10B981 / cold mist gray #6B7280. This repo's red line is "every design value comes from
//  `Shared/Theme/PopopxTheme.swift`, and this file contains no raw color value or raw font size" (same as the self-description at `PopopxTelemetryHeader.swift:12-13`
//  ), and raw cyan-green does not meet the contrast bar in dark mode. So each value lands on the nearest brand tier by meaning:
//  - trial state → `PopopxPalette.meshInk` (0x00705F / 0x00D2B8, near-field cyan-green): it is the tier for "not yet on the proper path",
//    the same family as near-field/temporary, and it carries the breathing glow;
//  - lit state → `PopopxPalette.successInk` (0x1E7A34 / 0x30D158, emerald-green ink): the "emerald green" the prompt asked for,
//    taking the tier that comes with dark-mode adaptation rather than raw #10B981;
//  - dormant state → `PopopxPalette.labelSecondary` + `card` background: dormant is not a failure, so neither the wording nor the colors give a danger color
//    (the comment on `PopopxBadgePhase` is where this criterion comes from).
//  This way all three states are "readable same-family colors" in both light and dark; the cost is that they no longer equal the prompt's HEX digit for digit — that trade-off is written
//  into the acceptance report, and the user decides whether to go back to raw values.
//
//  ### Motion appears only when something really is changing
//  - trial-state breathing: it is a temporary state that must be noticed, and it goes completely still under Reduce Motion (criterion same as `PopopxStatusPill.restart()`,
//    `PopopxTelemetryHeader.swift:333-339`）；
//  - lit-state rotation: it turns a full 360° only on the one **local counter increment** (`onChange(of: rotationIndex)`), with no permanent spin —
//    an icon that is always turning is noise in accessibility terms, and "rotating" is itself a discrete event, so one turn lines up with exactly one fact.
//
//  ### Three exits, never overlapping
//  trial state → the pioneer trial modal (`PopopxTrialWelcomeModal`); lit state → badge details (`PopopxBadgeDetailSheet`);
//  dormant state → the purchase page (`PopopxBadgePaywallView`). The criterion is `phase` alone, in one place, so an entry as self-contradictory as "expired, yet details still open to show a countdown"
//  is impossible.
//
//  ### The extra right half in the wide-screen tier (a second exit, not a third state)
//  In the trial and lit states, when **not compact**, a solid indigo block is added on the right: "Buy" / "Renew", tapping it goes to the paywall.
//  The criterion for the three exits is still `phase` alone (`route()` not one word changed); this segment merely shows the "paywall" destination
//  **early** in the two non-dormant states, saving the step of "open the modal first, then look for the buy button".
//  Not added in the compact tier: on 393pt the top bar constantly takes the symbol-only 48pt, and widening it means touching that row's measured overflow boundary;
//  so on iPhone the purchase exit for these two states therefore lives in the modal and the detail page (each has a primary action straight to the paywall).
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.

import SwiftUI
import POPOPXChat

// MARK: - Pure presentation

/// The badge capsule body: takes only `phase` and `rotationIndex`, reads no singleton, so it can be previewed and verified apart from the runtime.
struct PopopxBadgeCapsule: View {
    let phase: PopopxBadgePhase
    var rotationIndex: Int = 0
    /// Falls back to "symbol only" when the top bar lacks width, criterion same as `PopopxDualStatusCapsule`'s three `ViewThatFits` tiers.
    var compact: Bool = false
    /// The second exit: the "buy / renew" segment on the capsule's right. **Its declaration must come before `action`, this is a hard constraint**:
    /// every existing call site is written as `PopopxBadgeCapsule(phase: …) { … }`, and the trailing closure binds to the last function-typed parameter,
    /// so putting `buyAction` after `action` would silently wire "open details / trial explanation" to "buy" at those call sites.
    /// It defaults to nil, so the two hosts in the top bar and the "Me" page (not changeable this round) need not change a single line.
    var buyAction: (() -> Void)? = nil
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var spin: Double = 0

    var body: some View {
        Group {
            if showsBuySegment {
                twoPartPill
            } else {
                singlePill
            }
        }
        .onAppear { restartBreathing() }
        .onChange(of: phase) { _, _ in restartBreathing() }
        .onChange(of: rotationIndex) { _, _ in rotateOnce() }
    }

    /// The original whole-capsule-tappable capsule: not one word changed. When `showsBuySegment` is false this is the path taken,
    /// and the top bar's measured sizes (48 high, `spaceM` horizontal padding, solid color chip, tiered stroke and glow) stay exactly as they were.
    private var singlePill: some View {
        Button(action: tapped) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                symbol
                if !compact {
                    Text(verbatim: label)
                        .font(PopopxType.secondary.weight(isLive ? .semibold : .regular))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? PopopxMetrics.spaceS : PopopxMetrics.spaceM)
            .frame(height: PopopxMetrics.space2XL)
            .frame(minWidth: compact ? PopopxMetrics.space2XL : 0)
            .background(isLive ? tint.opacity(0.10) : PopopxPalette.card, in: .capsule)
            .overlay {
                // Stroke comes in two tiers: dormant is a 0.5pt gray edge, the two "alive" tiers are a 1.5pt solid edge in the same color
                // (`PopopxMetrics.stroke`). Width and opacity are tiered together, which is what lets a 48pt-high top bar row
                // crowded with five elements tell at a glance that "this one has something running".
                Capsule().strokeBorder(tint.opacity(isLive ? 0.85 : 0.25),
                                       lineWidth: isLive ? PopopxMetrics.stroke : PopopxMetrics.hairline)
            }
            // Faint outer glow: only for the two active tiers, radius one step of `space2XS`. Dormant does not glow,
            // and in dark mode this same-color halo is exactly the main cue for "lit up".
            .shadow(color: isLive ? tint.opacity(0.35) : .clear, radius: PopopxMetrics.space2XS)
            .contentShape(.capsule)
            // Same as the text-bearing tier in `PopopxStatusPill`: the capsule's width must not be clamped below the color chip + short phrase inside it,
            // otherwise the 1.5pt active stroke together with the glow gets pressed into a horizontal ellipse. The compact tier's content 40 plus `minWidth` 48
            // still clamps out as a 48 square, so this row has no effect on the top bar's 393pt budget.
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(hint)
        .accessibilityIdentifier("popopx.header.badge")
    }

    // MARK: Two-segment form (the purchase exit for the trial / lit states)

    /// This segment is added only in the **wide-screen tier with text**: on 393pt the top bar constantly retreats to the symbol-only 48pt
    /// (the measured criterion is at `Shared/Navigation/PopopxTelemetryHeader.swift:582-583`), so widening the compact tier
    /// means touching that boundary line which has already overflowed. That is why the trial/lit purchase exit on iPhone lands
    /// in the modal and the detail page (`PopopxTrialWelcomeModal` / `PopopxBadgeDetailSheet`), not here.
    /// Dormant state gets none either: tapping the whole capsule already is the paywall, so hanging another "buy" segment would be a duplicate entry.
    private var showsBuySegment: Bool {
        !compact && buyAction != nil && phase.capsuleState != .dormant
    }

    /// One capsule, two tap areas: the left half is still the original "see the explanation / see the details", the right half is the brand-indigo solid "buy / renew".
    /// The right half deliberately uses `brand` (none of the top bar's three tiers tint with it) instead of darkening `tint` one step — inside one capsule
    /// "money" and "status" must split into two things at a glance, and a darker green only reads as "a greener status".
    private var twoPartPill: some View {
        HStack(spacing: 0) {
            Button(action: tapped) {
                HStack(spacing: PopopxMetrics.spaceXS) {
                    symbol
                    Text(verbatim: label)
                        .font(PopopxType.secondary.weight(isLive ? .semibold : .regular))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .foregroundStyle(tint)
                .padding(.leading, PopopxMetrics.spaceM)
                .padding(.trailing, PopopxMetrics.spaceS)
                .frame(height: PopopxMetrics.space2XL)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint(hint)
            .accessibilityIdentifier("popopx.header.badge")

            Button(action: buyTapped) {
                Text(verbatim: buyLabel)
                    .font(PopopxType.microTag.weight(.semibold))
                    .foregroundStyle(PopopxPalette.onBrand)
                    .padding(.horizontal, PopopxMetrics.spaceS)
                    .frame(height: PopopxMetrics.spaceXL)
                    .background(PopopxPalette.brand, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(buyLabel)
            .accessibilityHint(PopopxBadgeCapsuleCopy.hintBuy)
            .padding(.trailing, PopopxMetrics.space2XS)
        }
        .frame(height: PopopxMetrics.space2XL)
        // Reaching this tier means it must be one of the two active tiers (`showsBuySegment` already excludes dormant), so neither background nor edge needs tiering again.
        .background(tint.opacity(0.10), in: .capsule)
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.85), lineWidth: PopopxMetrics.stroke)
        }
        .shadow(color: tint.opacity(0.35), radius: PopopxMetrics.space2XS)
    }

    /// The trial-state phrase is "buy", the lit-state phrase is "renew": same position, same action (both go to the paywall),
    /// but the word to read is not the same in the two states — with 2 days of trial left, "buy" reads as if you must give up the trial right now.
    private var buyLabel: String {
        switch phase.capsuleState {
        case .trialPulsing: PopopxBadgeCapsuleCopy.buy
        case .activeLit: PopopxBadgeCapsuleCopy.renew
        case .dormant: PopopxBadgeCapsuleCopy.buy
        }
    }

    // MARK: Presentation fragments

    /// The two active tiers put the symbol inside a solid disc: `mesh`+`onMesh`, `success`+`onSuccess` are, within the brand tiers,
    /// the only two "bright ground / dark ink" pairings (in light mode white text over `#00A896` is only 2.98:1, a measurement the file header records),
    /// so the ink on the solid disc must come from those two pairs and cannot reuse the capsule's own `*Ink`.
    @ViewBuilder private var symbol: some View {
        Group {
            switch phase.capsuleState {
            case .trialPulsing:
                Image(systemName: "sparkles")
                    .opacity(breathing ? 0.45 : 1)
                    .scaleEffect(breathing ? 0.85 : 1)
            case .activeLit:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .rotationEffect(.degrees(spin))
                    .animation(.linear(duration: 0.9), value: spin)
            case .dormant:
                Image(systemName: "circle.dashed")
            }
        }
        .font(PopopxType.microTag)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(isLive ? chipInk : tint)
        // nil rather than 0: `.frame(width: 0)` would squash the dormant `circle.dashed` out of existence.
        .frame(width: isLive ? PopopxMetrics.spaceL : nil, height: isLive ? PopopxMetrics.spaceL : nil)
        // When a long nickname squeezes the top bar narrow, this frame only clamps to a smaller proposal, and the solid chip together with the `.circle` background below it
        // would both turn into a horizontal ellipse (the "outer ring deformation" of device round 3). Lock this one square; whether the text tier should yield is still decided by
        // `ViewThatFits`, and the top bar's degradation rules are unchanged.
        .fixedSize()
        .background(isLive ? chipFill : Color.clear, in: .circle)
    }

    /// Dormant is not a failure: no danger color, only neutral ink (criterion same as the file header's third item).
    private var isLive: Bool { phase.capsuleState != .dormant }

    private var tint: Color {
        switch phase.capsuleState {
        case .trialPulsing: PopopxPalette.meshInk
        case .activeLit: PopopxPalette.successInk
        case .dormant: PopopxPalette.labelSecondary
        }
    }

    private var chipFill: Color {
        switch phase.capsuleState {
        case .trialPulsing: PopopxPalette.mesh
        case .activeLit: PopopxPalette.success
        case .dormant: Color.clear
        }
    }

    private var chipInk: Color {
        switch phase.capsuleState {
        case .trialPulsing: PopopxPalette.onMesh
        case .activeLit: PopopxPalette.onSuccess
        case .dormant: PopopxPalette.labelSecondary
        }
    }

    /// The top bar holds only short phrases: trial state shows a clock, lit state shows days, dormant state says "free node" rather than "not activated".
    /// Since device round 2 on 2026-11-20 these go through terminology entries (source text is the Key, 16 translations, wording same as `PopopxTelemetryCopy`);
    /// on 393pt the top bar takes the symbol-only tier, so these two phrases appear only on wide screens, but VoiceOver and wide screens must both be able to read them.
    private var label: String {
        switch phase {
        case .dormant:
            return PopopxBadgeCapsuleCopy.dormant
        case let .trial(expiresAt):
            return PopopxBadgeCapsuleCopy.trial(PopopxBadgeCapsuleCopy.clock(expiresAt.timeIntervalSinceNow))
        case let .active(_, expiresAt):
            // Round up: with 1 minute left you cannot say "0 days", that reads as if it already expired.
            let days = max(1, Int(ceil(max(0, expiresAt.timeIntervalSinceNow) / 86_400)))
            return PopopxBadgeCapsuleCopy.active(PopopxBadgeCapsuleCopy.daysClock(days))
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .dormant: PopopxBadgeCapsuleCopy.a11yDormant
        case let .trial(expiresAt):
            PopopxBadgeCapsuleCopy.a11yTrial(PopopxBadgeCapsuleCopy.clock(expiresAt.timeIntervalSinceNow))
        case let .active(_, expiresAt):
            PopopxBadgeCapsuleCopy.a11yActive(PopopxBadgeCapsuleCopy.clock(expiresAt.timeIntervalSinceNow))
        }
    }

    private var hint: String {
        switch phase.capsuleState {
        case .dormant: PopopxBadgeCapsuleCopy.hintDormant
        case .trialPulsing: PopopxBadgeCapsuleCopy.hintTrial
        case .activeLit: PopopxBadgeCapsuleCopy.hintActive
        }
    }

    private func tapped() {
        PopopxHaptics.selection()
        action()
    }

    /// Right half: the haptic is the same tier as the left half (that is a choice, not a confirmation), and there is only one action — go to the paywall.
    private func buyTapped() {
        PopopxHaptics.selection()
        buyAction?()
    }

    /// Breathing belongs only to the trial state; the other two states return to their resting position as soon as the page appears, leaving no residue of the previous state.
    private func restartBreathing() {
        guard phase.capsuleState == .trialPulsing, !reduceMotion else {
            breathing = false
            return
        }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathing = true }
    }

    /// One 360°: change only `spin`, with the animation attached to the symbol's `.animation(_:value:)`.
    /// "Subtract 360 first, then zero it with withAnimation" inside the same transaction gets merged into a single assignment, and the turn is lost.
    private func rotateOnce() {
        guard !reduceMotion else { return }
        spin -= 360
    }
}

// MARK: - Mounting components

/// The one in the top bar: the two visual tiers are still chosen by `ViewThatFits`, while the tier and the sheet carrier are attached **outside** the candidates.
///
/// Device round 9's "tap the header badge, then tap 'see badge details' with no response" had two layers of causes:
/// 1. The previous version put the wrapper carrying its own `.popopxBadgeSheets` (`PopopxBadgeCapsuleView`, deleted this round) entirely inside
///    the two `ViewThatFits` candidates, so candidate one and candidate two each had a presentation layer, and which one `sheet` wrote to was decided by the layout result.
/// 2. Even keeping only one copy, that copy and the host page (`ChatsListView`'s `.popopxBadgeSheets($badgeSheet)`) were still
///    **two sheets on the same chain**: when the host raises the trial modal, the header copy writing `.detail` again is a sheet inside a sheet,
///    and the system silently drops the second presentation, which looks exactly like "tapping did nothing".
/// So the carrier is not attached here, and `sheet` is handed in by the host: the whole page has only the host's single `.popopxBadgeSheets`,
/// and switching panels among the three states is always just changing that same value.
struct PopopxBadgeHeaderEntry: View {
    @State private var badge = PopopxBadgeManager.shared
    @Binding var sheet: PopopxBadgeSheet?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            capsule(compact: false)
            capsule(compact: true)
        }
    }

    private func capsule(compact: Bool) -> some View {
        PopopxBadgeCapsule(
            phase: badge.phase,
            rotationIndex: badge.record?.rotationIndex ?? 0,
            compact: compact,
            buyAction: { sheet = .paywall }
        ) {
            sheet = PopopxBadgeSheet.entry(for: badge.phase.capsuleState)
        }
    }
}

// MARK: - The single sheet carrier for the three exits

/// The badge's three exits (paywall / trial explanation / details).
///
/// Previously these three were three `.sheet(isPresented:)` attached at the same level: in device round 3 tapping "see badge details" did nothing,
/// because that button inside the trial modal could only `dismiss()` — raising another sheet at the same level is a sheet inside a sheet,
/// and the system silently drops the second presentation, so the UI looked like "tapping did nothing". After consolidating into one `.sheet(item:)`,
/// switching panels is just changing `item`: the sheet neither closes nor swaps, and its content switches in place to the detail page.
enum PopopxBadgeSheet: String, Identifiable {
    case paywall
    case trial
    case detail

    var id: String { rawValue }

    /// The single criterion mapping three states → three exits: both the top bar and the "Me" page read this one, and no longer switch on their own.
    static func entry(for state: PopopxBadgeCapsuleState) -> PopopxBadgeSheet {
        switch state {
        case .dormant: .paywall
        case .trialPulsing: .trial
        case .activeLit: .detail
        }
    }
}

/// Carrier content: `detents` keeps each of the original three sheets' tier unchanged (the paywall takes `.large` just like the gift card).
struct PopopxBadgeSheetHost: View {
    @Binding var sheet: PopopxBadgeSheet?

    var body: some View {
        switch sheet {
        case .paywall:
            PopopxBadgePaywallView()
                .presentationDetents([.large])
        case .trial:
            // The trial modal's "see tiers and prices" line changes `item` directly: the same sheet stays open and unswapped, content switching in place to the paywall.
            // This is the capability bought by closing off device round 3's "tapping 'see badge details' did nothing" — do not retreat to a second `.sheet`.
            PopopxTrialWelcomeModal(onOpenDetail: { sheet = .detail },
                                    onOpenPaywall: { sheet = .paywall })
                .presentationDetents([.medium, .large])
        case .detail:
            PopopxBadgeDetailSheet(onOpenPaywall: { sheet = .paywall })
                .presentationDetents([.medium, .large])
        case .none:
            EmptyView()
        }
    }
}

extension View {
    /// Attach the badge's three exits to the caller: the host needs only one `PopopxBadgeSheet?` state,
    /// and **the whole page may attach it only once** — `PopopxBadgeHeaderEntry` uses the binding of that host copy,
    /// so attaching another copy in the top bar would make two sheets on the same chain (the second cause, see that component's notes above).
    /// The parameter must not be named `sheet` — that would shadow `View.sheet(item:)` itself, and the compiler would only say "this is not a function".
    func popopxBadgeSheets(_ badgeSheet: Binding<PopopxBadgeSheet?>) -> some View {
        sheet(item: badgeSheet) { _ in PopopxBadgeSheetHost(sheet: badgeSheet) }
    }
}

// MARK: - Previews

private struct PopopxBadgeCapsuleGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
            PopopxBadgeCapsule(phase: .trial(expiresAt: Date().addingTimeInterval(82_000))) {}
            PopopxBadgeCapsule(phase: .active(source: .appleSubscription,
                                              expiresAt: Date().addingTimeInterval(1_200_000)),
                               rotationIndex: 1) {}
            PopopxBadgeCapsule(phase: .dormant) {}
            PopopxBadgeCapsule(phase: .active(source: .creditsExchange,
                                              expiresAt: Date().addingTimeInterval(3_600)),
                               compact: true) {}
            // The two states of the two-segment tier: the preview must show the left/right boundary and the color difference at a glance,
            // otherwise this path could only wait for a real device to reveal "the right half never rendered at all".
            PopopxBadgeCapsule(phase: .trial(expiresAt: Date().addingTimeInterval(82_000)),
                               buyAction: {}) {}
            PopopxBadgeCapsule(phase: .active(source: .storePass,
                                              expiresAt: Date().addingTimeInterval(1_200_000)),
                               buyAction: {}) {}
        }
        .padding(PopopxMetrics.spaceM)
        .background(PopopxPalette.base)
    }
}

struct PopopxBadgeCapsuleDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgeCapsuleGallery()
            .preferredColorScheme(.dark)
    }
}

struct PopopxBadgeCapsuleLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxBadgeCapsuleGallery()
            .preferredColorScheme(.light)
    }
}

// MARK: - Top bar short phrases

/// All the wording of this capsule in the top bar. The source is the English original sentence, and the English original sentence is the Key (written the same way as `PopopxTelemetryCopy`):
/// `en.lproj` is not written by convention, the fallback Key is already English, and each of the 16 translation directories writes its own translation.
///
/// The 2026-11-20 device round 2 ruling on "residual Chinese" was **translate only this one place in the top bar**, so this collects only what the top bar reads:
/// three status phrases, three VoiceOver phrases, three hints and that remaining time; the other BadgeCredits modules (the credit-deduction modal, the detail page)
/// keep their Chinese Copy exactly as they are, and `PopopxBadgeCopy.remainingClock` still serves the detail page as before.
private enum PopopxBadgeCapsuleCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX badge capsule")
    }

    static let dormant = key("Free node")
    static func trial(_ left: String) -> String { String(format: key("Trial %@"), left) }
    static func active(_ left: String) -> String { String(format: key("Encrypted routing · %@"), left) }

    static let a11yDormant = key("POPOPX privacy node: free relay")
    static func a11yTrial(_ left: String) -> String {
        String(format: key("POPOPX pioneer node trial: %@ left"), left)
    }
    static func a11yActive(_ left: String) -> String {
        String(format: key("POPOPX dynamic privacy node is lit: %@ left"), left)
    }

    static let hintDormant = key("Tap to see how to turn it on")
    static let hintTrial = key("Tap to read what the trial includes")
    static let hintActive = key("Tap to open badge details")

    /// The words on the two-segment right half. Short to the point of two words is deliberate: this segment lives inside the top bar's row,
    /// and that row's width is measured (see the `showsBuySegment` comment) — the longer the phrase, the sooner it squeezes the whole capsule back to compact.
    static let buy = key("Buy")
    static let renew = key("Renew")
    static let hintBuy = key("Tap to open plans and prices")

    /// The top bar's remaining time keeps only the two largest units, and every combination is one complete Key: a two-part join like `"3 d 2 h"`
    /// would break across 16 word orders (Russian and Hungarian would invert it), so five short phrases are preferable.
    /// Units are written into the entries rather than the code, so each translation can follow its own abbreviation rules.
    static func clock(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int(ceil(max(0, interval) / 60)))
        let days = minutes / 1_440
        let hours = minutes % 1_440 / 60
        let mins = minutes % 60
        if days > 0 {
            return hours > 0
                ? String(format: key("%1$d d %2$d h"), days, hours)
                : daysClock(days)
        }
        if hours > 0 {
            return mins > 0
                ? String(format: key("%1$d h %2$d min"), hours, mins)
                : String(format: key("%d h"), hours)
        }
        return String(format: key("%d min"), mins)
    }

    static func daysClock(_ days: Int) -> String { String(format: key("%d d"), days) }
}
