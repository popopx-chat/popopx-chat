//  PopopxTrialWelcomeModal.swift
//
//  [Phase 5 · 2] The pioneer-node trial badge claim panel: 3 days, once, limited to this device.
//
//  ### This panel is responsible for exactly one thing: explain the eligibility, then hand over
//  The one and only criterion for claiming or not claiming is `PopopxBadgeManager.canClaimPioneerTrial` (`record == nil` and no
//  `.trialGuard` in the Keychain). Without eligibility this place **does not offer a button that can only report an error** (this repo's standing rule: an entry whose capability is not wired is either disabled or
//  the whole row is absent, as in `PopopxPlusMenu`'s handling of the three closures, PopopxTelemetryHeader.swift:425-444),
//  instead it says out loud "why it cannot be claimed".
//
//  ### Three lines of honest boundaries
//  - "one claim per device" is guaranteed by the DeviceCheck token or this device's install fingerprint; **both only ever apply on this device**:
//    after a system reinstall, after flashing, or once that one Keychain slot holding the fingerprint is cleared, this layer has no second way to refuse a second claim —
//    a real server-side denylist would require uploading a device identifier, which conflicts with the architectural red line of "zero server-side ledger, no identifiers collected". So the copy says
//    "one claim per device", not "a second claim is impossible".
//  - The fallback after expiry is "back to the free public SMP nodes", not being cut off: contacts, message history, groups and channels are all untouched.
//    This sentence must be hard-written into the panel, because it is the one thing a user genuinely wants to know before pressing "claim".
//  - The trial badge and the paid badge use the same `PopopxBadgeRecord` slot: a paid activation **overwrites** source,
//    and the expiry takes whichever of the two is later (`PopopxBadgeManager.activate`'s merge rule), so there is no
//    trade-off of "wasting three trial days first in order to buy the real badge".
//
//  ### The second exit: tiers and prices (`onOpenPaywall`)
//  All three states keep a permanent `.secondary` button below the free step that opens the paywall. This leg exists not to be "one more entry":
//  the capsule in the top bar has a fixed width on iPhone (only the symbol, see `PopopxBadgeCapsule`'s `showsBuySegment`),
//  so a user in the trial state who wants to buy and can only guess would read "falls back to free nodes in 3 days" on this page and never find the next step.
//  Swapping panels goes through the host's single `.sheet(item:)` carrier, not a second sheet — so there is no sheet nested in a sheet.
//
//  Commerce-side nouns always go through `PopopxCommerceCopy` (all-language catalogues); the long explanatory sentences stay in this file's file-private `Copy`
//  written in Chinese — this is this round's localisation ruling: only strings about money, refunds and compliance go into `.lproj`.
//
//  ⚠️ Xcode project integration: this file must be dragged by hand into the POPOPX (iOS) target. The red line forbids scripting changes to project.pbxproj.

import SwiftUI
import POPOPXChat

struct PopopxTrialWelcomeModal: View {
    /// Where the "badge details" exit goes. If the host provides it, swap to the details panel (the `.sheet(item:)` of `PopopxBadgeSheetHost`),
    /// and if it is not given, fall back to the original close-only — the P0 of device round 3 was that this button previously only had `dismiss()`, and tapping it looked like nothing happened.
    var onOpenDetail: (() -> Void)? = nil
    /// Where the "tiers and prices" exit goes. Declared **after** `onOpenDetail`: both are optional closures,
    /// and which comes first only affects how the call site is written, while the host site (`PopopxBadgeSheetHost`) is written with labels,
    /// so adding a parameter here changes the meaning of no existing call site. Default nil = this panel only handles the free leg.
    var onOpenPaywall: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var badge = PopopxBadgeManager.shared
    @State private var toast = PopopxToastModel()
    @State private var isClaiming = false
    /// The one-sentence reason when the claim fails. `nil` = it never failed; not a boolean plus a string, to avoid the empty state of "a boolean but no reason".
    @State private var failure: String?

    private static let trialDays = Int(PopopxCommerceLimits.trialSeconds / 86_400)

    var body: some View {
        PopopxSheetContainer(Copy.title, subtitle: Copy.subtitle) {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                    hero
                    benefits
                    if badge.canClaimPioneerTrial || badge.record?.source == .pioneerTrial {
                        boundaries
                    }
                    if let failure {
                        notice(failure, tint: .danger)
                    }
                }
                .padding(.horizontal, PopopxMetrics.gutter)
                .padding(.bottom, PopopxMetrics.spaceL)
            }
        } footer: {
            footerRow
        }
        .popopxToast(toast)
    }

    // MARK: Hero visual

    /// An enlarged capsule-state preview: let the user see what the top bar will look like before pressing "claim".
    private var hero: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            PopopxBadgeCapsule(phase: badge.record?.source == .pioneerTrial
                                ? badge.phase
                                : .trial(expiresAt: Date().addingTimeInterval(PopopxCommerceLimits.trialSeconds))) {}
                .allowsHitTesting(false)
            Text(verbatim: Copy.heroNote(Self.trialDays))
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PopopxMetrics.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopopxPalette.meshInk.opacity(0.10), in: .rect(cornerRadius: PopopxMetrics.radiusCard))
    }

    private var benefits: some View {
        PopopxSectionCard(Copy.benefitsTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                bullet("chart.bar.xaxis", Copy.benefitStatusPanel)
                bullet("lock.shield", Copy.benefitRoute)
                bullet("clock.arrow.circlepath", Copy.benefitFallback(Self.trialDays))
                bullet("square.and.arrow.down.on.square", Copy.benefitKeepHistory)
            }
        }
    }

    private var boundaries: some View {
        PopopxSectionCard(Copy.boundaryTitle, footnote: Copy.boundaryFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                bullet("iphone", Copy.boundaryDevice)
                bullet("person.crop.circle.badge.xmark", Copy.boundaryNoAccount)
                bullet("tray.full", Copy.boundaryOneTime)
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Image(systemName: symbol)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.meshInk)
                .frame(width: PopopxMetrics.spaceXL)
            Text(verbatim: text)
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func notice(_ text: String, tint: PopopxIconTint) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(tint.fill)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
        .padding(PopopxMetrics.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.fill.opacity(0.10), in: .rect(cornerRadius: PopopxMetrics.radiusControl))
    }

    // MARK: Exits

    @ViewBuilder private var footerRow: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            if badge.record?.source == .pioneerTrial {
                // Already claimed on this device: the only role left to this panel is "make clear it is still running", and the exit is the details.
                PopopxButton(Copy.openDetail, systemImage: "eye", role: .secondary) {
                    if let onOpenDetail {
                        onOpenDetail()
                    } else {
                        dismiss()
                    }
                }
            } else if badge.canClaimPioneerTrial {
                PopopxButton(Copy.claim(Self.trialDays), systemImage: "sparkles", isLoading: isClaiming) {
                    await claim()
                }
            } else {
                // No eligibility: do not place a button that can only report an error, only explain.
                PopopxButton(Copy.close, role: .secondary) {
                    dismiss()
                }
            }

            // The paid exit is **permanent in all three states**, and always ordered after the free step, using `.secondary`:
            // the trial still has 3 days left while the tier choice already exists; giving no exit on this page is the same as making the user gamble on the top bar;
            // but making the paid action the primary button would turn this page from "explain the free road" into a checkout counter.
            // When the host gives no `onOpenPaywall` the whole row is absent (entries whose capability is not wired are never placed; see the rule on lines 7-9 of the file header).
            if let onOpenPaywall {
                PopopxButton(PopopxCommerceCopy.choosePlanAction, systemImage: "creditcard", role: .secondary) {
                    onOpenPaywall()
                }
            }
        }
    }

    private func claim() async {
        guard !isClaiming else { return }
        isClaiming = true
        defer { isClaiming = false }
        let issued = await PopopxBadgeManager.shared.issuePioneerTrialIfNeeded()
        if issued != nil {
            PopopxHaptics.notice(.success)
            toast.show(Copy.toastClaimed, kind: .encrypted)
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        } else {
            // Reaching here leaves only two possibilities: the guard was already written under concurrency, or that one Keychain write failed.
            // Both collapse into the single sentence "this device could not record the claim", without pretending to know which one, and without retrying the write a second time.
            failure = Copy.claimFailed
            PopopxHaptics.notice(.error)
        }
    }
}

// MARK: - Copy

private extension PopopxTrialWelcomeModal {
    enum Copy {
        static let title = PopopxCommerceCopy.trialBadgeName
        static let subtitle = NSLocalizedString("Run it for three days first: no account, no card, nothing to pay.", comment: "trial welcome modal")

        static func heroNote(_ days: Int) -> String { String(format: NSLocalizedString("Once claimed, this capsule grows in the top bar and keeps breathing for %lld days.", comment: "trial welcome modal"), days) }

        static let benefitsTitle = NSLocalizedString("What these three days look like", comment: "trial welcome modal")
        static let benefitStatusPanel = NSLocalizedString("Badge details is a read-only node status panel on this device: tier, expiry, reconciliation summary, local counters.", comment: "trial welcome modal")
        static let benefitRoute = NSLocalizedString("Encrypted relay routing: relay nodes never see the conversation, they only carry ciphertext.", comment: "trial welcome modal")
        static func benefitFallback(_ days: Int) -> String { String(format: NSLocalizedString("When it expires on day %lld the badge falls back to the free public SMP relay automatically and the connection stays up.", comment: "trial welcome modal"), days) }
        static let benefitKeepHistory = NSLocalizedString("Contacts, message history, groups and channels are all left untouched.", comment: "trial welcome modal")

        static let boundaryTitle = NSLocalizedString("Boundaries", comment: "trial welcome modal")
        static let boundaryFootnote = NSLocalizedString("Only what this layer really guarantees.", comment: "trial welcome modal")
        static let boundaryDevice = NSLocalizedString("The claim is kept in its own Keychain item on this device (readable only here, valid after the first unlock). No device identifier is uploaded.", comment: "trial welcome modal")
        static let boundaryNoAccount = NSLocalizedString("No account needed, and no Apple payment.", comment: "trial welcome modal")
        static let boundaryOneTime = NSLocalizedString("One claim per device.", comment: "trial welcome modal")

        static func claim(_ days: Int) -> String { String(format: NSLocalizedString("Claim the %lld-day trial badge", comment: "trial welcome modal"), days) }
        static let openDetail = NSLocalizedString("See badge details", comment: "trial welcome modal")
        static let close = NSLocalizedString("Got it", comment: "trial welcome modal")
        static let toastClaimed = NSLocalizedString("Trial badge lit", comment: "trial welcome modal")
        static let claimFailed = NSLocalizedString("This device could not record the claim — try again later, or check the device's free storage.", comment: "trial welcome modal")
    }
}

// MARK: - Previews

/// The preview reads the real singleton: `PopopxBadgeManager`'s `init` only reads that one `PopopxBadgeRecord` from the Keychain
/// (`PopopxBadgeManager.swift:65-71`), no network and no heartbeat, so in the simulator it is inert —
/// which branch is shown depends on whether this device has claimed. After one claim on a real device, this panel shows the "already claimed" branch.
struct PopopxTrialWelcomeDormant_Previews: PreviewProvider {
    static var previews: some View {
        PopopxTrialWelcomeModal()
            .preferredColorScheme(.dark)
    }
}

struct PopopxTrialWelcomeLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxTrialWelcomeModal()
            .preferredColorScheme(.light)
    }
}
