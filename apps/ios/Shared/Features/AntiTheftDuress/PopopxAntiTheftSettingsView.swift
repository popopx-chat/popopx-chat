//
//  PopopxAntiTheftSettingsView.swift
//  POPOPX (iOS)
//
//  [Physical anti-snatch + dual-password self-destruct · settings page] Module 1 (sensor/timeout/background lock) and module 3 (regular code +
//  duress code + post-self-destruct rebuild), the one and only configuration entry, plus a "one-tap rehearsal" page.
//  Mount point: Me → Privacy & security settings → this page (the host writes `PopopxAntiTheftSettingsView()`).
//
//  ### Why this page lives under "Me → Privacy & security" instead of opening a new entry point
//  When the owner looks for this feature, the questions in their head are "who can get into this app, and under what circumstances does it end itself", and these
//  two questions each already have their answers living in that one cell: `DEFAULT_PERFORM_LA` (ContentView.swift:46 reads it,
//  PrivacySettings.swift:28 writes it) governs "who can get in"; `DEFAULT_LA_SELF_DESTRUCT` + `SetAppPasscodeView`
//  (PrivacySettings.swift:512, :595, from :665 on) govern "which code triggers ending itself". Modules 1 and 3 are just the new increments of those two
//  things, not a third new thing. Opening a new top-level entry would create a second "security settings", and the cost of a second entry
//  here is far larger than on other pages: in a duress scenario the person is forced to find that switch within seconds, present in two places = found in neither,
//  and "the owner cannot find it themselves" is this feature's worst kind of failure. Module 1's bet "only add a layer, never change one" therefore
//  holds on the interface too: this page is added after Privacy & security, neither touching the upstream LA gate nor duplicating its switches.
//
//  ### Why the rehearsal page eats pure functions instead of "really simulating once"
//  "Really simulating once" is self-contradictory for these two features: a real simulation of the snatch must really lock the screen (interrupting the app
//  the owner is using right then), while a real simulation of the duress code must really wipe the data — the latter is irreversible, one rehearsal would be one accident.
//  So the rehearsal page only goes through `PopopxMotionCriteria.evaluate(samples:sensitivity:)` with two synthetic sample strings
//  (`syntheticSnatch()` / `syntheticFreeFall()`), and `PopopxDuressAuthManager.verify(pin:)`:
//  the first two are nonisolated static pure functions, the return value `PopopxMotionVerdict` is a value type, so the type itself cannot carry any
//  side effects; the latter's doc comment (`PopopxDuressAuthManager.verify(pin:)`) states "pure verification, zero side effects", and the road leading to erasure is
//  `submit`, which this page never calls. The real flow uses the very same `evaluate` (the one line in module 1's receive()),
//  so the threshold the rehearsal reports is not "the set shown for display", it is the set used at runtime — this is the precondition that lets the page prove itself.
//
//  ### Why dangerous operations all go through double confirmation instead of swipe gestures
//  The only irreversible actions on this page are writing the two codes into the Keychain (if you miswrite them and forget, the only way out is the 12 words
//  hand-copied on paper; the mnemonic itself has no recovery channel at all, and creating an identity requires no phone number/email) and deleting those two codes.
//  A swipe is a muscle-memory action — fast, continuous, no pause point — one accidental swipe in a pocket is enough to constitute "confirmation"; and neither consequence accepts that trigger probability.
//  So here it is uniformly the two-stage `PopopxButton(role: .destructive)` + `confirmationDialog`: the first stage is the explicit
//  red CTA (which itself carries one `.medium` haptic), the second stage is a system-level standalone dialog that must be tapped again and comes with a "Cancel".
//  Between the two inputs the screen content does not change, so the owner has all the time to change their mind. The third irreversible action is "regenerate a set" — what it voids is
//  the very sheet the owner hand-copied, so before those two stages it has one more: first pass an identity gate in the Keychain
//  (`proveIdentityForRegenerate()`, the same pair of methods as "view"), and only after that passes does the red CTA get its turn.
//  The "turn off dual passwords" cell goes through the same gate: its `didSet` will
//  delete the duress-code record (the `didSet` of `PopopxDuressAuthManager.duressEnabled`), so this page wraps it into an "ask once first" binding
//  instead of letting the switch take effect the moment it slides.
//
//  ### The mnemonic is the only "cleartext gate" this page opens, so all three of its actions carry cost explanations
//  The 12 English words are this module's only credential recoverable in cleartext: viewing it first requires verifying the owner in person, on the spot — entering the correct entry password,
//  or passing one Face ID while "Biometric quick unlock" is on — and the copy
//  on paper is equivalent to "whoever knows these 12 words can set a new entry password". So this page does only three things —
//  generate (together with the entry password, or by pressing once yourself), view (re-verified every single time, never cached), regenerate
//  (red double confirmation: the old sheet is voided on the spot, and the owner may well be holding it right then). And the consequences are stated in the open:
//  **resetting the entry password with the mnemonic also clears the emergency-erasure password to "not set"**
//  (`PopopxDuressAuthManager.resetEntryPinWithMnemonic`). That sentence is not a hint but a design decision — someone who can reset the password
//  should not simultaneously hold a self-destruct entry they do not know about. Resetting also does **not consume** the mnemonic; for "burn after use" you must press regenerate yourself.
//  Each of these three has one plain-language sentence on the page; implementation details are not left to speak for them.
//
//  ### Layout and dependencies
//  The skeleton copies Shared/Features/Me/PopopxMeView.swift: ScrollView + `PopopxSectionCard` grouping,
//  `PopopxPickerRow`/`PopopxToggleRow`/`PopopxRadioRow` inside the cards, one honest footer sentence, and the page itself
//  **does not install a NavigationStack** (the stack comes from the host, see the same ruling at PopopxMeView.swift:10-12).
//  Colors, font sizes, corner radii, spacing take only tokens from Shared/Theme/PopopxTheme.swift; notices only go through `PopopxToastModel`,
//  haptics only through `PopopxHaptics`; this page hardcodes no color or spacing anywhere and invents no new button or input field.
//
//  ### Wiring of the two switch rows (connected after the second refactor; each one's path to taking effect written out)
//  The "behavior criteria" and "simulated smoke bomb" cells still land on the same two keys from module 1
//  (`DEFAULT_ANTI_THEFT_BEHAVIOR_ENABLED`, `DEFAULT_ANTI_THEFT_DECOY_ENABLED`), but the two cells' respective
//  ways of taking effect differ, and mixing them into one pattern would leave one cell inert on the spot:
//  - Behavior criteria: binds the `PopopxBehaviorGuard.shared.enabled` instance itself (`@Bindable`), whose own `didSet`
//    writes the same key **and** calls `sync()`, so flipping it starts/stops the sensors immediately. An earlier version bound `@AppStorage`,
//    the key got written but the singleton never heard about it, waiting until the next launch — a security switch that looks on but is actually inert is worse than no switch.
//  - Simulated smoke bomb: module 4 reads that key fresh inside itself, does **not subscribe** to UserDefaults change notifications, and names the requirement in its comments:
//    "this row's action must call `refreshFromDisk()`". So it stays on `@AppStorage` (module 4 has no bindable
//    `@Observable` property), with one `onChange` added to make that one call.
//  Both keys are this module's single source of truth, so no second copy of the state can appear.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand — an iron rule forbids scripts from editing project.pbxproj.
//

import Foundation
import SwiftUI

// MARK: - Settings page

@MainActor
struct PopopxAntiTheftSettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// All of module 1's state: the switch, sensitivity, timeout tier, background instant lock, and the sensors' own diagnostic readouts.
    /// This is the only UI in the whole repo bound to it; writing it goes through `didSet` into UserDefaults, and this page stores no extra copy of the booleans.
    @Bindable private var motion = PopopxAntiTheftMotionGuard.shared

    /// All of module 3's state: the configuration status of the two codes, the biometrics switch, and the post-self-destruct rebuild mode.
    @Bindable private var duress = PopopxDuressAuthManager.shared

    @State private var toast = PopopxToastModel()

    /// Whether this device has biometric capability. `biometricsAvailable` creates a new `LAContext` on every read
    /// (`PopopxDuressAuthManager.biometricsAvailable` builds a fresh `LAContext` per read), so it is "ask once on entry" rather than "ask every frame".
    @State private var biometricsAvailable = false

    @State private var showsPinSheet = false
    @State private var showsTimeoutSheet = false

    /// The two dialogs of the two-stage confirmation.
    @State private var showsCommitDialog = false
    @State private var showsClearDialog = false
    @State private var showsDuressOffDialog = false

    /// Four passphrase input cells. The values exist only in this `@State`: they are cleared on a successful write, on dialog cancel, and on leaving this page.
    /// Nowhere on the whole page are their values sent into `logger`, `toast`, or `UIPasteboard`.
    @State private var normalPin = ""
    @State private var normalConfirm = ""
    @State private var duressPin = ""
    @State private var duressConfirm = ""

    /// Native entry-code migration: those two `...Active` flags are facts obtained by asking the Keychain when entering this page; when neither is true the entire
    /// card section below simply does not render, so someone who never enabled native credentials on this device is not randomly asked for a password. The two are mutually exclusive by construction
    /// (`nativeSelfDestructGhostActive`'s definition carries "the entry code is already gone"), so only one cell can ever appear at a time.
    ///
    /// They cannot reuse `pinField`: the two native codes are **digits only, 4 to 16 long** — the keyboard offers only 0-9 and hardwires
    /// `password.count < 16`（Shared/Views/LocalAuth/PasscodeEntry.swift:122-131），
    /// the submit key to additionally require no fewer than 4 digits (PasscodeView.swift:81 in the same directory); `pinField` truncates to 6 digits,
    /// and reusing it would make a 7-to-16-digit old code impossible to type in full, and the owner would run into that "but I definitely typed it right" rejection.
    /// What gets stored is the raw text (Shared/Views/LocalAuth/SetAppPasscodeView.swift:37 `set(passcode)`),
    /// so the comparison must be done by the owner typing it again; it cannot be derived from anywhere else.
    @State private var nativeEntryPasswordActive = false
    @State private var nativeSelfDestructGhostActive = false
    @State private var nativePasscode = ""
    @State private var nativeSelfDestructCode = ""

    /// Error text during the write: holds only the fifteen verbatim sentences of `PopopxDuressSetupError.errorDescription`,
    /// this page writes no synonymous copy of its own.
    @State private var pinFeedback: String?
    @State private var isWritingPins = false

    /// The switches for the module 2 and module 4 rows. How each row takes effect on the spot: see the "Wiring of the two switch rows" section at the file head:
    /// behavior criteria binds the singleton directly (its `didSet` is responsible for writing the key + `sync()`), the simulated content binds `@AppStorage` plus
    /// one `onChange` that calls module 4 to re-read from disk.
    ///
    /// The self-destruct direction is safe: `PopopxAntiTheftSwitches.eraseAllTraces()` first flips both singletons' `enabled` to false,
    /// then deletes this batch of keys, so the `didSet` write-back cannot resurrect the switches.
    @Bindable private var behavior = PopopxBehaviorGuard.shared
    @AppStorage(DEFAULT_ANTI_THEFT_DECOY_ENABLED) private var decoyEnabled = false

    // MARK: identity roll-call for "keep specified nicknames" (added in the second refactor)
    //
    // This tier stores `profileId` + `displayName` — identity information, not a preference, so the UI must never invent one
    // out of thin air as profile 0 to fudge past it. The list's only source of truth is the underlying `listUsersAsync()`, not `ChatModel.users`: the latter may still be
    // the copy read at launch, and getting one name wrong on this page means one real identity wrongly kept or wrongly deleted at self-destruct time.
    @State private var retainCandidates: [PopopxRetainCandidate] = []
    /// The fetched-once flag. Failure and "really only 0/1 identities" are merged into the same display in this version (the fool-proofing row),
    /// reason in the comments of `loadRetainCandidates()` — that is a merge in the safe direction, not laziness.
    @State private var retainLoaded = false
    @State private var showsRetainSheet = false

    // MARK: the mnemonic's three interface copies (values live only here, cleared on leaving the page / after a successful view)
    //
    // The 12 English words are **cleartext** and need "use and discard" even more than the two codes: unlike `PopopxDuressVerifier`,
    // which holds only derived values, this itself is the thing that directly opens the door. So nowhere on this page is it written into `logger`,
    // `UIPasteboard`, `toast`, or any persistent location, nor displayed on the card by default — it must first pass an identity gate
    // (type the current entry password correctly, or let Face ID recognize the owner while "Biometric quick unlock" is on),
    // before it appears once in this single `@State`. "Regenerate a set" goes through the same pair of gates, but it takes only the "proof",
    // not the words: voiding the old sheet does not require first putting the old sheet on the screen.
    @State private var showsMnemonicSheet = false
    /// The one-off entry-password inputs for "view" and "regenerate".
    @State private var mnemonicUnlockPin = ""
    /// The 12 words obtained after verification (the normalized word array returned by `revealMnemonic`, only for numbered display;
    /// comparison never uses this copy). Empty array = nothing currently displayed.
    @State private var mnemonicWords: [String] = []
    @State private var mnemonicFeedback: String?
    /// This cell's only single-flight switch: the three asks (password view, Face ID view, regenerate proof) share it,
    /// so while any one is running the other two buttons grey out on their own — only one proof should ever be in flight.
    @State private var isReadingMnemonic = false
    /// Regenerate = the old sheet is voided on the spot, so like "write the two codes" it is a red double confirmation.
    /// That confirmation only appears after the identity gate has passed; see `proveIdentityForRegenerate()`.
    @State private var showsMnemonicRegenDialog = false
    /// The new word set generated together with the entry password: after a successful setup it stays on the sheet, waiting for the owner to personally tap "I have copied it down".
    /// The sheet does not auto-close — closing it the moment it pops up would throw away the only chance to copy it down.
    @State private var freshMnemonic: [String]?

    init() {}

    var body: some View {
        wrapped
    }

    /// The cards themselves. Written separately from `wrapped` below in order to give the type checker two independent inference contexts:
    /// with nine cards + four sheets + four confirmation dialogs + `task`/`onChange` hung on the same chain, Swift reports
    /// "unable to type-check this expression in reasonable time", and the reported location points at some innocent line in the middle, a
    /// `Text(...)` — splitting the expression is the only fix, and not one line of behavior changes.
    private var pageContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                masterCard
                sensitivityCard
                inactivityCard
                duressCard
                mnemonicCard
                lockoutCard
                rebuildCard
                drillCard
                riskCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
            // Sensitivity, tier, and the dual-password configuration state all rewrite these cards' explanatory text. Under Reduce Motion it lands directly.
            .popopxAnimation(PopopxSpring.fluid, value: animationKey, reduceMotion: reduceMotion)
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.pageTitle)
        // This page is a pushed first-level subpage (Me → Privacy & security → this page); the title goes inline so the first card is not pushed off screen.
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Sheets and lifecycle hooks. At this layer `pageContent` is already a settled opaque type, so the long chain below
    /// does not have to infer the six cards' types along with it — the "unable to type-check this expression in reasonable
    /// time" recorded above for `pageContent` was reported on an innocent `Text(...)` line; the root cause was the whole chain having a single inference context. Not one line of behavior changed.
    private var wrapped: some View {
        pageContent
        .sheet(isPresented: $showsPinSheet) {
            pinSetupSheet
        }
        .sheet(isPresented: $showsTimeoutSheet) {
            timeoutSheet
        }
        .sheet(isPresented: $showsRetainSheet) {
            retainSheet
        }
        .sheet(isPresented: $showsMnemonicSheet) {
            mnemonicSheet
        }
        // Module 4 reads that key fresh and does not subscribe to change notifications, so undoing/loading the simulated content must go through this line telling it to re-read from disk.
        // Attached only to `decoyEnabled`: the other cell (behavior criteria) binds the singleton instance itself, and its `didSet` calls `sync()` on its own.
        .onChange(of: decoyEnabled) { _, _ in
            PopopxDecoyProfileGenerator.shared.refreshFromDisk()
        }
        // The red double confirmation before the write. This consequence is unrecoverable, so it must consist of a separate click with a "Cancel".
        .confirmationDialog(Copy.commitDialogTitle, isPresented: $showsCommitDialog, titleVisibility: .visible) {
            Button(Copy.commitDialogConfirm, role: .destructive) {
                Task { @MainActor in
                    await writePins()
                }
            }
            Button(Copy.cancel, role: .cancel) {
                clearPinFields()
            }
        } message: {
            Text(Copy.commitDialogMessage)
        }
        .confirmationDialog(Copy.clearDialogTitle, isPresented: $showsClearDialog, titleVisibility: .visible) {
            Button(Copy.clearDialogConfirm, role: .destructive) {
                clearAllPins()
            }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.clearDialogMessage)
        }
        .confirmationDialog(Copy.duressOffDialogTitle, isPresented: $showsDuressOffDialog, titleVisibility: .visible) {
            Button(Copy.duressOffDialogConfirm, role: .destructive) {
                duress.duressEnabled = false
                toast.show(Copy.duressOffDone, kind: .danger)
            }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.duressOffDialogMessage)
        }
        // What "regenerate" destroys is the sheet in the owner's hands, yet on the page the action looks like nothing but a button tap.
        // So it needs a second, independent click with a "Cancel" that reads the consequences aloud — the same question as "write the two codes".
        // This click is ordered **after** identity verification: `proveIdentityForRegenerate()` first proves the person pressing it holds the owner's
        // credentials, then this proves they know what they are about to void. Neither gate caches, so pressing again after a cancel asks all over again.
        .confirmationDialog(Copy.mnemonicRegenTitle, isPresented: $showsMnemonicRegenDialog, titleVisibility: .visible) {
            Button(Copy.mnemonicRegenConfirm, role: .destructive) {
                Task { @MainActor in
                    await regenerateMnemonic()
                }
            }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.mnemonicRegenMessage)
        }
        .popopxToast(toast)
        .task {
            // Every time this page is entered, ask the Keychain for the true configuration instead of trusting the cached one in memory
            // (`refreshConfiguration`'s own doc comment states why it must re-read rather than trust the in-memory cache).
            duress.refreshConfiguration()
            biometricsAvailable = duress.biometricsAvailable
            // Whether the native entry code / ghost self-destruct code still exists is likewise asked only once, in this line: they are Keychain reads,
            // and putting them in body would make every redraw hit the Keychain once.
            nativeEntryPasswordActive = PopopxDuressAuthManager.nativeEntryPasswordActive
            nativeSelfDestructGhostActive = PopopxDuressAuthManager.nativeSelfDestructGhostActive
            // Same for the identity list: the owner may well be exactly the person who "first creates an alternate profile on the home page, then comes in and picks this tier",
            // and judging "only one identity" from the previous list would lock them out.
            await loadRetainCandidates()
        }
        .onChange(of: showsPinSheet) { _, opened in
            if !opened { clearPinFields() }
        }
        // Closing the view sheet = the 12 cleartext words disappear from the interface. The next view requires verifying the entry password all over again;
        // nowhere on this page is the word set cached into a `didSet`, UserDefaults, or any "seen before" state.
        .onChange(of: showsMnemonicSheet) { _, opened in
            if !opened { clearMnemonicFields() }
        }
    }

    /// The animation's trigger key: several states that affect the cards' text are merged into one string, avoiding hanging one animation per state.
    ///
    /// The last three items were added this round: mnemonic "set / not set", the ten-strike wipe switch, the current failure count,
    /// and all three rewrite the explanatory sentences inside the cards. Miss any one and that cell keeps the previous sentence after its state has already changed
    /// — this page has no other refresh moment (`task` runs only once on entry), so this key is the only driver.
    ///
    /// **The remaining cooldown seconds are deliberately kept out of this key**: they are the difference between `Date` and the stored moment — only the wall clock moves,
    /// the state does not; putting it in the key would neither actually change every second (nothing drives a redraw) nor stop misleading later readers into thinking it ticks.
    /// That row's per-second refresh is handled by `cooldownRow`'s own `TimelineView`.
    private var animationKey: String {
        "\(motion.enabled)-\(motion.sensitivity.wireValue)-\(duress.normalConfigured)-\(duress.duressConfigured)-\(duress.retentionStrategy.segmentIndex)-\(duress.retentionStrategy.retainedProfileId ?? -1)-\(duress.mnemonicConfigured)-\(duress.wipeOnTenthFailure)-\(duress.failedAttemptCount)"
    }

    // MARK: master switch

    private var masterCard: some View {
        PopopxSectionCard(Copy.groupMaster, footnote: Copy.masterFootnote) {
            PopopxToggleRow(
                Copy.enabledRow,
                note: motion.enabled ? Copy.enabledNoteOn : Copy.enabledNoteOff,
                systemImage: "lock.shield.fill",
                tint: .brand,
                isOn: $motion.enabled
            )
            .accessibilityIdentifier("popopx.antiTheft.masterToggle")
            AntiTheftDivider()
            PopopxToggleRow(
                Copy.instantBgRow,
                note: Copy.instantBgNote,
                systemImage: "moon.zzz",
                tint: .neutral,
                isOn: $motion.instantLockOnBackground
            )
            AntiTheftDivider()
            // When biometrics are unavailable this row must stay visible but untappable, and say why on the spot: simply hiding it
            // would make the owner think the feature does not exist, and then fail to find it exactly when they need it most.
            PopopxToggleRow(
                Copy.biometricsRow,
                note: biometricsNote,
                systemImage: "faceid",
                tint: .neutral,
                isOn: $duress.biometricsEnabled
            )
            .disabled(!biometricsAvailable)
            .opacity(biometricsAvailable ? 1 : 0.45)
            AntiTheftDivider()
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(Copy.lockNowRow)
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                    Text(Copy.lockNowNote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
                PopopxButton(Copy.lockNowButton, systemImage: "lock", role: .secondary, fullWidth: false) {
                    lockManually()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, PopopxMetrics.spaceXS)
        }
    }

    /// The consecutive-failure downgrade sentence uses the manager's own constant; no second literal 2 is written here.
    private var biometricsNote: String {
        if !biometricsAvailable {
            return Copy.biometricsNoteUnavailable
        }
        return String(
            format: Copy.biometricsNoteFormat,
            "\(PopopxDuressAuthManager.maxBiometricFailuresBeforeKeypad)"
        )
    }

    /// Lock once manually. The consequence of `PopopxLockReason.manual` is "re-authenticate once", at the same level as the sensor criteria,
    /// So this button needs no confirmation dialog: it leads to no erasure whatsoever.
    private func lockManually() {
        PopopxAppLockState.shared.lock(reason: .manual)
        PopopxHaptics.impact(.light)
        toast.show(Copy.lockNowDone, kind: .encrypted)
    }

    // MARK: sensitivity

    /// The segmented picker's three tiers are the enum's own `allCases`, and the labels are its built-in `label` (all three are ≤4 Chinese characters,
    /// the `.lineLimit(1)` line inside `PopopxSegmentedControl` cannot fit longer wording on small screens).
    /// Writing the element type out in full is to pin the `Selection` generic parameter on the spot, instead of inferring it back from the whole expression.
    private var sensitivityOptions: [PopopxSegmentedControl<PopopxMotionSensitivity>.Option] {
        PopopxMotionSensitivity.allCases.map { .init(selection: $0, title: $0.label) }
    }

    private var sensitivityCard: some View {
        PopopxSectionCard(Copy.groupSensitivity, footnote: Copy.sensitivityFootnote) {
            PopopxSegmentedControl(
                sensitivityOptions,
                title: { $0.label },
                selection: $motion.sensitivity
            )
            .accessibilityIdentifier("popopx.antiTheft.sensitivity")
            .padding(.bottom, PopopxMetrics.spaceXS)

            // These two lines are the half of this page that "proves what it is doing": the thresholds are read straight from `PopopxMotionCriteria` and from the tier's
            // `spikeG`/`spinOmega`; change a criteria constant and this page rewrites along with it immediately, so the interface and the runtime
            // never each tell a different story about the thresholds.
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                thresholdLine(
                    Copy.thresholdHeadline,
                    String(
                        format: Copy.thresholdSpikeFormat,
                        fixed(motion.sensitivity.spikeG),
                        fixed(motion.sensitivity.spinOmega)
                    )
                )
                thresholdLine(
                    Copy.preconditionHeadline,
                    String(
                        format: Copy.preconditionFormat,
                        fixed(PopopxMotionCriteria.spikeRiseG),
                        fixed(PopopxMotionCriteria.calmLookback),
                        fixed(PopopxMotionCriteria.calmLowerG, digits: 2),
                        fixed(PopopxMotionCriteria.calmUpperG, digits: 2)
                    )
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AntiTheftDivider()
            PopopxToggleRow(
                Copy.behaviorRow,
                note: Copy.behaviorNote,
                systemImage: "hand.draw",
                tint: .neutral,
                isOn: $behavior.enabled
            )
            // Tilt-angle threshold: module 2's only numeric criterion. However small you slide it, it stays inside its `sanitize` range (15~75),
            // out-of-range values are clamped back by itself, and this page does not recompute a second set of upper/lower bounds.
            AntiTheftDivider()
            PopopxSliderRow(
                Copy.angleRow,
                value: $behavior.angleLimitDegrees,
                in: PopopxBehaviorCriteria.minimumAngleLimitDegrees...PopopxBehaviorCriteria.maximumAngleLimitDegrees,
                step: 1,
                valueText: { "\(Int($0))°" }
            )
            .disabled(!behavior.enabled)
            .opacity(behavior.enabled ? 1 : 0.45)
            .accessibilityIdentifier("popopx.antiTheft.angleLimit")
            thresholdLine(Copy.angleHeadline, angleNoteText)
        }
    }

    /// The full criteria text; all four numbers come from module 2's own constants: if this page restated the numbers itself, it would leave whoever changes the constants later
    /// a copy that can lie. The directional convention also follows `PopopxBehaviorCriteria.evaluate` as-is (strictly greater than the threshold,
    /// duration seconds and touch counts each counting "once reached"), not written as ≥ / > just to read more smoothly.
    private var angleNoteText: String {
        String(
            format: Copy.angleFormat,
            fixed(PopopxBehaviorCriteria.minimumSustainedSeconds),
            fixed(PopopxBehaviorCriteria.irregularTouchWindow),
            "\(PopopxBehaviorCriteria.minimumIrregularTouches)"
        )
    }

    private func thresholdLine(_ headline: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Text(headline)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
            Text(value)
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PopopxMetrics.space2XS)
        }
    }

    // MARK: idle auto-lock duration
    //
    // Chose `PopopxPickerRow` + `PopopxRadioRow` inside the sheet, rather than spreading five RadioRow lines directly on the page,
    // for two layers of reasons: first the repo's status quo — every "N-choose-one with an explanation per item" tier (the nearby pairing policy in
    // `PopopxMeView.pairingPolicySheet` and the same-named one in `PopopxSettingsViews`) all go the "entry row + radio table" route;
    // following it makes this page look like it was always part of this app; second, this cell has five tiers in total, and spreading them on the page would
    // make the "lock screen duration" group longer than the dual passwords above it, and the layout's center of gravity would tip. The entry row's tail also carries a current-tier label;
    // spread out, you would actually lose sight of "which one is selected now".

    private var inactivityCard: some View {
        PopopxSectionCard(Copy.groupInactivity, footnote: Copy.inactivityFootnote) {
            PopopxPickerRow(
                Copy.inactivityRow,
                value: motion.inactivityTimeout.label,
                systemImage: "timer",
                tint: .brand
            ) {
                PopopxHaptics.selection()
                showsTimeoutSheet = true
            }
            .accessibilityIdentifier("popopx.antiTheft.inactivity")
            .accessibilityValue(motion.inactivityTimeout.label)
        }
    }

    private var timeoutSheet: some View {
        NavigationStack {
            PopopxSheetContainer(Copy.timeoutSheetTitle, subtitle: Copy.timeoutSheetSubtitle) {
                PopopxSectionCard {
                    ForEach(Array(PopopxInactivityTimeout.allCases.enumerated()), id: \.element) { index, timeout in
                        if index > 0 {
                            AntiTheftDivider()
                        }
                        PopopxRadioRow(
                            timeout.label,
                            note: timeoutNote(timeout),
                            selected: motion.inactivityTimeout == timeout
                        ) {
                            PopopxHaptics.selection()
                            motion.inactivityTimeout = timeout
                            showsTimeoutSheet = false
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.close) { showsTimeoutSheet = false }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    /// Each of the five tiers has its own consequence note, and the `never` tier must spell out the risk rather than only writing "never".
    private func timeoutNote(_ timeout: PopopxInactivityTimeout) -> String {
        switch timeout {
        case .oneMinute: return Copy.timeoutNoteOne
        case .threeMinutes: return Copy.timeoutNoteThree
        case .fiveMinutes: return Copy.timeoutNoteFive
        case .fifteenMinutes: return Copy.timeoutNoteFifteen
        case .never: return Copy.timeoutNoteNever
        }
    }

    // MARK: dual passwords

    private var duressCard: some View {
        PopopxSectionCard(Copy.groupDuress, footnote: Copy.duressFootnote) {
            PopopxToggleRow(
                Copy.duressSwitchRow,
                note: duressSwitchNote,
                systemImage: "exclamationmark.triangle.fill",
                tint: .danger,
                isOn: duressEnabledBinding
            )
            AntiTheftDivider()
            PopopxPickerRow(
                Copy.duressSetupRow,
                value: duressStatusValue,
                systemImage: "key.fill",
                tint: .brand
            ) {
                PopopxHaptics.impact(.light)
                duress.refreshConfiguration()
                nativeEntryPasswordActive = PopopxDuressAuthManager.nativeEntryPasswordActive
                nativeSelfDestructGhostActive = PopopxDuressAuthManager.nativeSelfDestructGhostActive
                showsPinSheet = true
            }
            .accessibilityIdentifier("popopx.antiTheft.duressEntry")
            .accessibilityValue(duressStatusValue)
            AntiTheftDivider()
            // The state of the emergency-erasure password's own row, speaking only the two wordings the brief allows: set / not set.
            // It is a direct reading of `duressConfigured`, and the latter each time goes through `refreshConfiguration()`
            // asking the Keychain fresh — so once an emergency erasure has been triggered, returning to this page this turns into "not set" on its own,
            // and the page needs no extra bookkeeping of a "just self-destructed" state (keeping one would only quarrel with the Keychain).
            thresholdLine(Copy.duressStateHeadline, duressStateValue)
            AntiTheftDivider()
            // Unrecoverable actions stay as one red row + one system dialog; `PopopxButton` itself reads isEnabled and drops it to 0.45.
            PopopxButton(
                Copy.duressClearRow,
                systemImage: "trash",
                role: .destructive
            ) {
                showsClearDialog = true
            }
            .disabled(!duress.normalConfigured && !duress.duressConfigured)
        }
    }

    /// Turning this cell off deletes the duress-code record (the `didSet` of `PopopxDuressAuthManager.duressEnabled`), so `set` only opens the dialog
    /// and writes no value: the real write happens in the red branch of the `confirmationDialog`. The turning-on direction has no side effects and writes directly.
    private var duressEnabledBinding: Binding<Bool> {
        Binding(
            get: { duress.duressEnabled },
            set: { newValue in
                if newValue {
                    duress.duressEnabled = true
                } else {
                    showsDuressOffDialog = true
                }
            }
        )
    }

    private var duressSwitchNote: String {
        duress.duressEnabled
            ? Copy.duressSwitchNoteOn
            : Copy.duressSwitchNoteOff
    }

    /// What the row's tail states is what is really in the Keychain right now, not "I did set it just now, right?".
    private var duressStatusValue: String {
        if !duress.normalConfigured {
            return Copy.duressStatusNone
        }
        return duress.duressConfigured ? Copy.duressStatusBoth : Copy.duressStatusNormalOnly
    }

    /// The state of the emergency-erasure-password matter itself. All of its write points are inside module 3, and every one of them follows
    /// the Keychain's actual readings (`refreshConfiguration()` asks fresh, `setDuressPin` sets true after a successful write,
    /// `clearDuressPin`/the `didSet` of `duressEnabled`/the downgrade step in `runDuressFlow` set it false).
    /// So "once an emergency erasure was triggered, returning here shows not set" is not this page's judgement; it reads the Keychain's facts out verbatim.
    private var duressStateValue: String {
        duress.duressConfigured ? Copy.duressStateSet : Copy.duressStateUnset
    }

    // MARK: 12-word mnemonic

    /// The state of the mnemonic cell, on the same convention as `duressStateValue`: **ask the Keychain fresh**.
    /// `mnemonicConfigured` requires both the "derived hash + viewable cleartext" records to exist (that AND in the manager),
    /// so a half-new-half-stale mnemonic reads as "not set" here, instead of showing a "viewable" line and then sending the owner into a failure.
    private var mnemonicStateValue: String {
        duress.mnemonicConfigured ? Copy.mnemonicStateSet : Copy.mnemonicStateUnset
    }

    /// Whether the Face ID gate can be used right now. All three conditions are required, corresponding one-to-one with
    /// the three `guard`s at the head of `PopopxDuressAuthManager.verifyIdentityWithBiometrics`:
    /// miss one, and the sheet's "verify with Face ID and show" button and the "verify with Face ID and regenerate" button
    /// would only yield a "not passed" once pressed — both asks share this gate, so they also share this check.
    /// - `duress.biometricsEnabled`: that master switch on this page.
    /// - `!duress.keypadRequired`: two consecutive failures just happened on the overlay, so this session is downgraded to "keypad code only".
    ///   This downgrade also reaches the settings page — it means "biometrics are untrusted during this period", not "the lock screen side temporarily withholds it".
    /// - `biometricsAvailable`: this device currently judges them available. What is used here is this page's `@State` copy of the "ask once on entry"
    ///   reading; the manager's version builds a new `LAContext` on every read, and putting that in body would mean asking on every redraw.
    /// The cooldown state is deliberately not asked here, for the same reason as over there: neither of these two asks consumes the failure count, so there is nothing to zero out.
    private var mnemonicFaceIDOffered: Bool {
        duress.biometricsEnabled && !duress.keypadRequired && biometricsAvailable
    }

    /// The tail value of the mnemonic row. Three values rather than the two "configured/not configured": whether that gate is open, the owner should
    /// see it on this very row, rather than tap into the sheet only to discover a button is missing.
    private var mnemonicRowValue: String {
        guard duress.mnemonicConfigured else { return Copy.mnemonicRowGenerate }
        return mnemonicFaceIDOffered ? Copy.mnemonicRowRevealEither : Copy.mnemonicRowReveal
    }

    /// Which gate the "regenerate a set" ask takes; the value rules are the same set as the two "view" buttons above:
    /// - `.entryPin`: the password field already holds a full 6 digits — goes through `verifyEntryPin`, the same half of the implementation as "verify and show".
    /// - `.biometric`: not filled enough, but the Face ID gate is open — goes through `verifyIdentityWithBiometrics`.
    /// - `.unavailable`: neither holds, no gate to walk. This branch **disables** the button, for the same reason as the Face ID
    ///   button only appearing when it can truly pass: a button that would only raise an error when pressed should not exist on the page.
    /// With 3 digits typed and Face ID open it counts as `.biometric`: that half-length password does not constitute a walkable path,
    /// while "Face ID passes just as well" is true, and the owner can switch back to the password path at any time by typing the full 6 digits.
    private enum MnemonicRegenDoor {
        case entryPin
        case biometric
        case unavailable
    }

    private var mnemonicRegenDoor: MnemonicRegenDoor {
        if PopopxDuressAuthManager.isValidPin(mnemonicUnlockPin) { return .entryPin }
        return mnemonicFaceIDOffered ? .biometric : .unavailable
    }

    /// The gate is written into the button's name, so before pressing the owner knows what this one hands over. The wording aligns with the "verify and show" /
    /// "verify with Face ID and show" pair: a bare "verify", with no qualifier, means the password field above.
    private var mnemonicRegenLabel: String {
        guard duress.mnemonicConfigured else { return Copy.mnemonicSheetGenerate }
        switch mnemonicRegenDoor {
        case .entryPin: return Copy.mnemonicSheetRegenerateVerified
        case .biometric: return Copy.mnemonicSheetRegenerateFaceID
        case .unavailable: return Copy.mnemonicSheetRegenerate
        }
    }

    private var mnemonicCard: some View {
        PopopxSectionCard(Copy.groupMnemonic, footnote: Copy.mnemonicFootnote) {
            thresholdLine(Copy.mnemonicStateHeadline, mnemonicStateValue)
            AntiTheftDivider()
            PopopxPickerRow(
                Copy.mnemonicRow,
                value: mnemonicRowValue,
                systemImage: "text.page.fill",
                tint: .brand
            ) {
                PopopxHaptics.impact(.light)
                duress.refreshConfiguration()
                clearMnemonicFields()
                freshMnemonic = nil
                showsMnemonicSheet = true
            }
            .accessibilityIdentifier("popopx.antiTheft.mnemonicEntry")
            .accessibilityValue(mnemonicRowValue)
            .disabled(!duress.normalConfigured)
            // The consequence is stated in the open instead of waiting for the owner to run into it on the lock screen: resetting clears the emergency-erasure password to "not set".
            // This sentence and the red sentence in `lockoutCard` are this page's only two dangerInk notes, and both point in irreversible directions.
            AntiTheftDivider()
            warningLine(Copy.mnemonicConsequence)
        }
    }

    /// The mnemonic's view/generate sheet.
    ///
    /// Four implementation conventions, all specific to this cell:
    /// 1. **No `.textSelection(.enabled)`**: once selected, text can enter the system clipboard, and the clipboard can be read by other apps
    ///    and may also sync to other devices via iCloud. A word set that can recover the identity in cleartext should not be copied by the system to
    ///    places this module cannot govern, so this cell can only be "copied down with the eyes".
    /// 2. **Closing the sheet clears everything** (`onChange(of: showsMnemonicSheet)` → `clearMnemonicFields()`);
    ///    the next view must verify all over again — entry password or Face ID, both gates are valid only in the moment.
    ///    This page keeps no "seen before" state.
    /// 3. Neither of those two buttons is "instant on tap": the password path runs one ~355 ms PBKDF2 derivation,
    ///    the Face ID path waits for the system sheet's result, so both carry `isLoading`;
    ///    the transition animation is not used to paper over this wait.
    /// 4. **"Regenerate a set" first passes the same pair of gates** (`proveIdentityForRegenerate()`): what this ask voids is
    ///    the sheet in the owner's hands; a bystander with an unlocked phone casually tapping it is bad enough, so that red double confirmation
    ///    only appears after the identity has been verified. The order is "verify identity first, ask confirmation second"; the two asks each govern one thing:
    ///    the first proves authority, the second proves intent. This ask neither reads nor displays the old word set.
    private var mnemonicSheet: some View {
        NavigationStack {
            PopopxSheetContainer(Copy.mnemonicSheetTitle, subtitle: mnemonicSheetHint) {
                PopopxSectionCard(Copy.mnemonicSheetGroup, footnote: Copy.mnemonicSheetFootnote) {
                    if !mnemonicWords.isEmpty {
                        mnemonicWordGrid(mnemonicWords)
                        AntiTheftDivider()
                        PopopxButton(Copy.mnemonicSheetHide, systemImage: "eye.slash") {
                            clearMnemonicFields()
                        }
                    } else {
                        if duress.mnemonicConfigured {
                            pinField(Copy.mnemonicSheetPinLabel, prompt: Copy.pinPrompt, text: $mnemonicUnlockPin)
                            AntiTheftDivider()
                            PopopxButton(
                                Copy.mnemonicSheetReveal,
                                systemImage: "eye",
                                isLoading: isReadingMnemonic
                            ) {
                                await revealMnemonicNow()
                            }
                            .disabled(!PopopxDuressAuthManager.isValidPin(mnemonicUnlockPin))
                            .accessibilityIdentifier("popopx.antiTheft.mnemonicReveal")
                            // The other gate appears only when it can truly pass. Its three conditions, with
                            // the three precondition gates of `PopopxDuressAuthManager.verifyIdentityWithBiometrics`
                            // correspond word for word — miss one and this would be a button that can only raise an error when pressed.
                            // The two buttons share `isReadingMnemonic`, so while either path runs the other greys out on its own:
                            // one click should hand out only one copy of cleartext.
                            if mnemonicFaceIDOffered {
                                AntiTheftDivider()
                                PopopxButton(
                                    Copy.mnemonicSheetRevealFaceID,
                                    systemImage: "faceid",
                                    role: .secondary,
                                    isLoading: isReadingMnemonic
                                ) {
                                    await revealMnemonicWithFaceID()
                                }
                                .accessibilityIdentifier("popopx.antiTheft.mnemonicRevealFaceID")
                            }
                            AntiTheftDivider()
                        }
                        PopopxButton(
                            mnemonicRegenLabel,
                            systemImage: duress.mnemonicConfigured ? "arrow.triangle.2.circlepath" : "plus",
                            role: duress.mnemonicConfigured ? .destructive : .primary,
                            isLoading: isReadingMnemonic
                        ) {
                            // When no word set exists yet, this click destroys nothing and generates directly; when one exists, what it destroys is
                            // the sheet in the owner's hands, so it first passes the exactly same identity gate as "view",
                            // and only after verification does the red double confirmation get its turn.
                            if duress.mnemonicConfigured {
                                await proveIdentityForRegenerate()
                            } else {
                                await regenerateMnemonic()
                            }
                        }
                        .disabled(duress.mnemonicConfigured && mnemonicRegenDoor == .unavailable)
                        .accessibilityIdentifier("popopx.antiTheft.mnemonicGenerate")
                    }
                    if let mnemonicFeedback {
                        AntiTheftDivider()
                        Text(mnemonicFeedback)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.dangerInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                PopopxSectionCard(Copy.mnemonicSheetPaperGroup, footnote: nil) {
                    warningLine(Copy.mnemonicSheetPaperNote)
                }
                if duress.mnemonicConfigured {
                    PopopxSectionCard(Copy.mnemonicSheetWhyGroup, footnote: nil) {
                        Text(Copy.mnemonicSheetWhyNoCount)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.close) { showsMnemonicSheet = false }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    /// The copy-down page after a successful write. It offers no input field and no "regenerate": the owner just tapped
    /// "write these two codes", and the only thing this screen must accomplish is copying the 12 words onto paper. To get a different set,
    /// close it and redo it from the mnemonic cell.
    ///
    /// Offers only the `.large` detent: those 12 cells plus two explanation lines would be half clipped at `.medium`,
    /// and a copy-down page with words clipped off is worse than no such screen at all — the owner would think they have copied everything.
    private func mnemonicCaptureSheet(_ words: [String]) -> some View {
        NavigationStack {
            PopopxSheetContainer(Copy.mnemonicCaptureTitle, subtitle: Copy.mnemonicCaptureSubtitle) {
                PopopxSectionCard(Copy.mnemonicSheetGroup, footnote: Copy.mnemonicSheetFootnote) {
                    mnemonicWordGrid(words)
                }
                PopopxSectionCard(Copy.mnemonicSheetPaperGroup, footnote: nil) {
                    warningLine(Copy.mnemonicSheetPaperNote)
                }
            } footer: {
                PopopxButton(Copy.mnemonicCaptureDone, systemImage: "checkmark") {
                    showsPinSheet = false
                }
                .padding(PopopxMetrics.spaceM)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.close) { showsPinSheet = false }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// 12 words, numbered, two columns. The numbering is necessary, not decorative: copying into the wrong slot (word 7 into cell 6)
    /// invalidates the whole word set just like a mistyped letter, and BIP-39's checksum is only 4 bit — it cannot block this kind of misplacement.
    /// The two columns use `.flexible()`, with no written minimum width — `PopopxMetrics` has no token of this kind,
    /// and making up a number would be the opposite of what this page promised: "hardcode not one dimension".
    ///
    /// takes a parameter instead of reading `mnemonicWords` directly: the re-view screen and the copy-down screen use two different `@State` copies
    /// (the former is discarded right after use, the latter must hold until the owner personally taps "I have copied it down"), while this typesetting section must be exactly the same.
    private func mnemonicWordGrid(_ words: [String]) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: PopopxMetrics.spaceXS), GridItem(.flexible(), spacing: PopopxMetrics.spaceXS)],
            spacing: PopopxMetrics.spaceXS
        ) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: PopopxMetrics.spaceXS) {
                    Text("\(index + 1)")
                        .font(PopopxType.microTag)
                        .foregroundStyle(PopopxPalette.labelHint)
                        .frame(width: PopopxMetrics.spaceXL, alignment: .trailing)
                        .accessibilityHidden(true)
                    Text(word)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.label)
                    Spacer(minLength: PopopxMetrics.space2XS)
                }
                .padding(.vertical, PopopxMetrics.space2XS)
                .padding(.horizontal, PopopxMetrics.spaceXS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PopopxPalette.cardHigh, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.mnemonicGridLabel)
        .accessibilityIdentifier("popopx.antiTheft.mnemonicWords")
    }

    /// The sheet's subtitle must say "what this cell can really use right now": when the Face ID gate is not open it must not write "or Face ID",
    /// otherwise the owner would hunt for a nonexistent button among the row of buttons.
    private var mnemonicSheetHint: String {
        guard duress.mnemonicConfigured else { return Copy.mnemonicSheetHintNone }
        return mnemonicFaceIDOffered ? Copy.mnemonicSheetHintHaveBiometric : Copy.mnemonicSheetHintHave
    }

    // MARK: progressive anti-brute-force

    private var lockoutStrikesValue: String {
        let strikes = duress.failedAttemptCount
        if strikes == 0 {
            return Copy.lockoutStrikesNone
        }
        return String(
            format: Copy.lockoutStrikesFormat,
            "\(strikes)",
            "\(duress.strikesUntilWipe)"
        )
    }

    /// That schedule is **read out of the schedule itself**; no re-copying of the numbers here: when `PopopxLockoutSchedule` changes,
    /// this sentence changes with it. Copying it would leave, for whoever edits the table later, one spot of copy that can say things that no longer hold.
    private var lockoutScheduleValue: String {
        let steps = [5, 6, 7, 8].map { attempt in
            String(
                format: Copy.lockoutStepFormat,
                "\(attempt)",
                PopopxLockoutSchedule.phrase(PopopxLockoutSchedule.lockoutSeconds(afterAttemptCount: attempt))
            )
        }
        return String(format: Copy.lockoutScheduleFormat, steps.joined(separator: " · "))
    }

    /// The cooldown row must move every second, but "seconds remaining" is the difference between `Date` and the stored moment, with no state changing at all,
    /// so it cannot be driven by `animationKey` (see the comment there). `TimelineView` is this cell's own heartbeat.
    private var cooldownRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = duress.lockoutEndsAt.map { $0.timeIntervalSince(context.date) } ?? 0
            thresholdLine(
                Copy.lockoutCoolingHeadline,
                remaining > 0
                    ? String(format: Copy.lockoutCoolingFormat, PopopxLockoutSchedule.phrase(remaining))
                    : Copy.lockoutCoolingIdle
            )
        }
    }

    private var lockoutCard: some View {
        PopopxSectionCard(Copy.groupLockout, footnote: Copy.lockoutFootnote) {
            thresholdLine(Copy.lockoutStrikesHeadline, lockoutStrikesValue)
            AntiTheftDivider()
            cooldownRow
            AntiTheftDivider()
            thresholdLine(Copy.lockoutScheduleHeadline, lockoutScheduleValue)
            AntiTheftDivider()
            PopopxToggleRow(
                Copy.lockoutTenStrikeRow,
                note: lockoutTenStrikeNote,
                systemImage: "exclamationmark.octagon.fill",
                tint: .danger,
                isOn: $duress.wipeOnTenthFailure
            )
            .accessibilityIdentifier("popopx.antiTheft.tenStrikeWipe")
            AntiTheftDivider()
            warningLine(Copy.lockoutTenStrikeWarning)
        }
    }

    /// On and off say two opposite things, so the two sentences are written separately, with no "prefix + shared second half" splicing:
    /// turning that tier off means the 10th failure is just "lock for one more hour", and this sentence must let the owner know they are **actively** giving up the wipe.
    private var lockoutTenStrikeNote: String {
        duress.wipeOnTenthFailure ? Copy.lockoutTenStrikeNoteOn : Copy.lockoutTenStrikeNoteOff
    }

    /// The red version of `riskLine`: on this page only "a destructive consequence that will actually be executed" deserves this color.
    private func warningLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxPalette.dangerInk)
                .accessibilityHidden(true)
            Text(text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.dangerInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// View the mnemonic: hand over the entry password once, exchange for the 12 words.
    ///
    /// The password is cleared from the interface right after this line (`mnemonicUnlockPin = ""`), **the same whether it succeeds or fails**:
    /// this cell's only purpose is "prove on the spot that the owner knows the entry password", and once proved, that copy should be gone.
    /// On failure only `errorDescription` is displayed verbatim, with no hint like "which digit was wrong".
    private func revealMnemonicNow() async {
        let pin = mnemonicUnlockPin
        mnemonicUnlockPin = ""
        mnemonicFeedback = nil
        mnemonicWords = []
        guard PopopxDuressAuthManager.isValidPin(pin) else {
            mnemonicFeedback = PopopxDuressSetupError.entryPinRequired.errorDescription
            PopopxHaptics.notice(.warning)
            return
        }
        isReadingMnemonic = true
        defer { isReadingMnemonic = false }
        do {
            mnemonicWords = try await duress.revealMnemonic(unlockingWith: pin)
            PopopxHaptics.notice(.success)
            toast.show(Copy.mnemonicToastShown, kind: .encrypted)
        } catch let error as PopopxDuressSetupError {
            mnemonicFeedback = error.errorDescription
            clearMnemonicFields()
            PopopxHaptics.notice(.error)
            toast.show(Copy.mnemonicToastRejected, kind: .danger)
        } catch {
            mnemonicFeedback = Copy.mnemonicUnexpectedFailure
            clearMnemonicFields()
            PopopxHaptics.notice(.error)
            toast.show(Copy.mnemonicToastRejected, kind: .danger)
        }
    }

    /// The second gate for viewing the mnemonic: Face ID. What it hands over is exactly the same as `revealMnemonicNow`,
    /// so the closing discipline is also exactly the same — first clear leftovers from the previous screen (the feedback copy and any word set possibly still showing),
    /// and on failure say `errorDescription` once verbatim, then `clearMnemonicFields()`.
    ///
    /// This one has no cleartext copy to clear: the password does not enter this path, `mnemonicUnlockPin` stays as is — characters the owner just typed
    /// should not be confiscated by another button's failure. Derivation also does not run on this path, so this wait is the system sheet, not three hundred milliseconds.
    private func revealMnemonicWithFaceID() async {
        mnemonicFeedback = nil
        mnemonicWords = []
        isReadingMnemonic = true
        defer { isReadingMnemonic = false }
        do {
            mnemonicWords = try await duress.revealMnemonicWithBiometrics(reason: Copy.mnemonicSheetFaceIDReason)
            PopopxHaptics.notice(.success)
            toast.show(Copy.mnemonicToastShown, kind: .encrypted)
        } catch let error as PopopxDuressSetupError {
            mnemonicFeedback = error.errorDescription
            clearMnemonicFields()
            PopopxHaptics.notice(.error)
            toast.show(Copy.mnemonicToastRejected, kind: .danger)
        } catch {
            mnemonicFeedback = Copy.mnemonicUnexpectedFailure
            clearMnemonicFields()
            PopopxHaptics.notice(.error)
            toast.show(Copy.mnemonicToastRejected, kind: .danger)
        }
    }

    /// The "regenerate a set" click: first prove the owner in person along the path `mnemonicRegenDoor` designates,
    /// and only after verification is the red double confirmation released. The order is deliberate — verify identity first, then ask "are you sure you want to void that sheet":
    /// what this ask guards against is a bystander with an unlocked phone casually tapping it, and that click should not even earn a single proof.
    ///
    /// Both gates call the same pair of manager methods as "view", so the passing conditions of the two asks must not differ. This **does not** read
    /// or display the old word set: having proved itself equals the right to void it, and there is no need to put the previous sheet back on the screen.
    ///
    /// The proof is not cached, the same closing discipline as `revealMnemonicNow`: the password is cleared from the interface on the spot, success and failure alike.
    /// So pressing again after cancelling that red confirmation asks all over again — the "I already verified" state is not kept here.
    private func proveIdentityForRegenerate() async {
        mnemonicFeedback = nil
        // The same thing as those two "view" buttons: before asking, re-read the Keychain's true state,
        // do not trust the in-memory cache — if a self-destruct happened midway, the `mnemonicConfigured` here must still have the final say.
        duress.refreshConfiguration()
        isReadingMnemonic = true
        defer { isReadingMnemonic = false }
        do {
            switch mnemonicRegenDoor {
            case .entryPin:
                let pin = mnemonicUnlockPin
                mnemonicUnlockPin = ""
                try await duress.verifyEntryPin(pin)
            case .biometric:
                try await duress.verifyIdentityWithBiometrics(reason: Copy.mnemonicRegenFaceIDReason)
            case .unavailable:
                // This branch's button is disabled (see `mnemonicRegenDoor`), so it is normally unreachable; if truly reached it returns right away —
                // prefer doing nothing over "passing through without proof".
                return
            }
        } catch let error as PopopxDuressSetupError {
            mnemonicFeedback = error.errorDescription
            mnemonicUnlockPin = ""
            PopopxHaptics.notice(.error)
            toast.show(Copy.mnemonicRegenToastRejected, kind: .danger)
            return
        } catch {
            mnemonicFeedback = Copy.mnemonicRegenUnexpectedFailure
            mnemonicUnlockPin = ""
            PopopxHaptics.notice(.error)
            toast.show(Copy.mnemonicRegenToastRejected, kind: .danger)
            return
        }
        PopopxHaptics.notice(.success)
        showsMnemonicRegenDialog = true
    }

    /// Generate / regenerate the mnemonic. On success the new word set is displayed — this is the owner's only chance to copy it down.
    ///
    /// The failure branch neither retries nor leaves a half-finished product: on the manager side (`storeMnemonic`) any half failing rolls back the whole pair,
    /// so here we only need to state honestly "nothing was generated", without judging "was only half of it written".
    ///
    /// Before calling it, a proof should already have passed: the `showsMnemonicRegenDialog` branch is opened by
    /// `proveIdentityForRegenerate` only after the identity verifies; when `mnemonicConfigured` is still false
    /// this click destroys nothing, so that path needs no gate. The write itself sets no gate inside the manager —
    /// the path that generates the first word set together with the entry password goes through the same method, and that gate would be meaningless over there.
    private func regenerateMnemonic() async {
        showsMnemonicRegenDialog = false
        mnemonicFeedback = nil
        mnemonicWords = []
        isReadingMnemonic = true
        defer { isReadingMnemonic = false }
        if let words = await duress.generateMnemonic() {
            mnemonicWords = words
            PopopxHaptics.notice(.success)
            toast.show(Copy.mnemonicToastGenerated, kind: .encrypted)
        } else {
            mnemonicFeedback = Copy.mnemonicGenerateFailed
            PopopxHaptics.notice(.error)
            toast.show(Copy.pinToastRejected, kind: .danger)
        }
        duress.refreshConfiguration()
    }

    /// Clears the three mnemonic-and-password cells in one go. Same reason as `clearPinFields`: a cleartext copy should not
    /// outlive the occasion it is used for — here it matters even more than for the two codes, because this copy is **readable plaintext**.
    private func clearMnemonicFields() {
        mnemonicUnlockPin = ""
        mnemonicWords = []
        mnemonicFeedback = nil
        isReadingMnemonic = false
    }

    // MARK: dual-password setup sheet

    /// Two mutually exclusive interfaces at the same sheet position: the form that fills in the two codes, and the copy-down page that appears right after a successful write.
    ///
    /// Split into two screens rather than inserting an `if` into that form: after a successful write the six input fields have nothing left to do,
    /// and keeping them only hands out one more chance to click "write these two codes" — that click would overwrite what was just written
    /// with a brand-new salt, while the interface would say nothing but "what on earth did I just write".
    @ViewBuilder
    private var pinSetupSheet: some View {
        if let words = freshMnemonic {
            mnemonicCaptureSheet(words)
        } else {
            pinSetupFormSheet
        }
    }

    private var pinSetupFormSheet: some View {
        NavigationStack {
            PopopxSheetContainer(Copy.pinSheetTitle, subtitle: Copy.pinSheetSubtitle) {
                PopopxSectionCard(Copy.pinGroupNormal, footnote: Copy.pinNormalFootnote) {
                    pinField(Copy.pinNormalLabel, prompt: Copy.pinPrompt, text: $normalPin)
                    AntiTheftDivider()
                    pinField(Copy.pinNormalConfirmLabel, prompt: Copy.pinPrompt, text: $normalConfirm)
                    AntiTheftDivider()
                    pinStateLine(normalPin, confirming: normalConfirm)
                }
                // This section appears only when those two native old credentials truly still exist, and it follows right after the regular-password group: the migration happens
                // inside `setNormalPin`, before any write (PopopxDuressAuthManager.swift:1358),
                // and placing it after the duress code would make the "fill the old password first" ordering unreadable on the page.
                // The two cells are mutually exclusive, guaranteed by module 3's two readings: entry code still there → ask for the entry code; entry code already gone,
                // only an unpressable self-destruct code left → ask for that self-destruct code.
                // Like `pinField`, no `systemImage`/`keyboard:` is passed here — the `isSecure` branch does not read them.
                if nativeEntryPasswordActive {
                    PopopxSectionCard(Copy.pinNativeGroup, footnote: Copy.pinNativeFootnote) {
                        nativePasscodeField(Copy.pinNativeLabel, prompt: Copy.pinNativePrompt, text: $nativePasscode)
                    }
                } else if nativeSelfDestructGhostActive {
                    PopopxSectionCard(Copy.pinNativeSDGroup, footnote: Copy.pinNativeSDFootnote) {
                        nativePasscodeField(
                            Copy.pinNativeSDLabel,
                            prompt: Copy.pinNativePrompt,
                            text: $nativeSelfDestructCode
                        )
                    }
                }
                PopopxSectionCard(Copy.pinGroupDuress, footnote: Copy.pinDuressFootnote) {
                    pinField(Copy.pinDuressLabel, prompt: Copy.pinPrompt, text: $duressPin)
                    AntiTheftDivider()
                    pinField(Copy.pinDuressConfirmLabel, prompt: Copy.pinPrompt, text: $duressConfirm)
                    AntiTheftDivider()
                    pinStateLine(duressPin, confirming: duressConfirm)
                }
                if let pinFeedback {
                    PopopxSectionCard {
                        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(PopopxType.microTag)
                                .imageScale(.medium)
                                .foregroundStyle(PopopxPalette.dangerInk)
                                .accessibilityHidden(true)
                            Text(pinFeedback)
                                .font(PopopxType.caption)
                                .foregroundStyle(PopopxPalette.dangerInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                PopopxSectionCard(Copy.pinIrreversibleGroup, footnote: nil) {
                    Text(Copy.pinIrreversibleNote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                PopopxButton(
                    Copy.pinWriteButton,
                    systemImage: "lock.fill",
                    role: .destructive,
                    isLoading: isWritingPins
                ) {
                    showsCommitDialog = true
                }
                .padding(PopopxMetrics.spaceM)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.close) { showsPinSheet = false }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    /// The input field for the six-cell numeric code. Uses `PopopxTextField(isSecure:)`: internally it is a `SecureField`,
    /// so it brings no history candidates, no auto-correction, and does not take part in the system's password autofill suggestions
    /// (the branch at PopopxControls.swift:237-241). Deliberately no `systemImage` is passed here, and no
    /// `keyboard:` either: that branch does not read it, and passing it would be a quiet false promise (see the commit message).
    private func pinField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        PopopxTextField(label, prompt: prompt, text: text, isSecure: true)
            .onChange(of: text.wrappedValue) { _, newValue in
                clampToDigits(text, newValue, maxLength: PopopxDuressAuthManager.pinLength)
            }
    }

    /// Keeps only ASCII digits, truncating the length to `maxLength`. This is pure filtering with no echo-back: no cell's value ever appears
    /// in any copy; the most the interface shows are content-irrelevant facts like "how many cells are filled / whether the two match".
    ///
    /// `maxLength` must be an explicit parameter, never a default value: default-argument expressions evaluate in a nonisolated context in Swift,
    /// while `PopopxDuressAuthManager.pinLength` is isolated with the whole `@MainActor` class, so writing
    /// `maxLength: Int = PopopxDuressAuthManager.pinLength` would report on the spot
    /// "main actor-isolated static property can not be referenced from a nonisolated context"
    /// (a direct error under the Swift 6 language mode).
    private func clampToDigits(_ target: Binding<String>, _ newValue: String, maxLength: Int) {
        let filtered = String(
            newValue
                .filter { PopopxDuressAuthManager.digits.contains($0) }
                .prefix(maxLength)
        )
        if filtered != newValue { target.wrappedValue = filtered }
    }

    /// The native keyboard's hardcoded upper bound (Shared/Views/LocalAuth/PasscodeEntry.swift:125 `password.count < 16`,
    /// and the same thing fully disables the keys at :131).
    private static let nativePasscodeMaxLength = 16

    /// The shared input cell for the two native old codes: the same `PopopxTextField(isSecure:)`, but truncated to the native keyboard's own
    /// 16-digit bound rather than the dual-password 6. The entry code and the self-destruct code come from the same keyboard (the same `PasscodeEntry`),
    /// so length and character set follow exactly the same rules; only the labels and notes differ.
    private func nativePasscodeField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        PopopxTextField(label, prompt: prompt, text: text, isSecure: true)
            .onChange(of: text.wrappedValue) { _, newValue in
                clampToDigits(text, newValue, maxLength: Self.nativePasscodeMaxLength)
            }
    }

    /// Live consistency between the two cells: says only "match / mismatch", never the values. A mistap is this page's costliest mistake,
    /// so make it visible before validation even runs.
    private func pinStateLine(_ first: String, confirming second: String) -> some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Image(systemName: stateSymbol(first: first, confirming: second))
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(stateInk(first: first, confirming: second))
                .accessibilityHidden(true)
            Text(stateSentence(first: first, confirming: second))
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PopopxMetrics.space2XS)
        }
        .padding(.vertical, PopopxMetrics.space2XS)
    }

    private func stateSymbol(first: String, confirming second: String) -> String {
        if first.isEmpty { return "circle" }
        return (first == second && PopopxDuressAuthManager.isValidPin(first)) ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func stateInk(first: String, confirming second: String) -> Color {
        if first.isEmpty { return PopopxPalette.labelHint }
        return (first == second && PopopxDuressAuthManager.isValidPin(first))
            ? PopopxPalette.successInk
            : PopopxPalette.dangerInk
    }

    private func stateSentence(first: String, confirming second: String) -> String {
        if first.isEmpty {
            return String(format: Copy.pinStateEmptyFormat, "\(PopopxDuressAuthManager.pinLength)")
        }
        if !PopopxDuressAuthManager.isValidPin(first) {
            return String(format: Copy.pinStateShortFormat, "\(PopopxDuressAuthManager.pinLength)", "\(first.count)")
        }
        return first == second ? Copy.pinStateMatched : Copy.pinStateMismatched
    }

    /// Write the two codes. The validation order follows module 3's constraints: first locally judge the format and "the two codes are identical" (this layer can produce
    /// the `pinsMustDiffer` wording on the spot), then hand off to `setNormalPin`/`setDuressPin`, letting the true gate at the derived-value level
    /// make the final verdict (the constant-time comparison inside `setDuressPin` that "re-derives once more with the regular record's own salt").
    ///
    /// The native entry code's migration is not this page's concern: it lives inside `setNormalPin`, after these two local checks and before any Keychain
    /// write (PopopxDuressAuthManager.swift:1358-1363), so on a mistyped old code not even the regular code hits disk.
    private func writePins() async {
        pinFeedback = nil
        guard PopopxDuressAuthManager.isValidPin(normalPin),
              PopopxDuressAuthManager.isValidPin(duressPin) else {
            pinFeedback = PopopxDuressSetupError.malformedPin.errorDescription
            PopopxHaptics.notice(.warning)
            toast.show(Copy.pinToastRejected, kind: .danger)
            return
        }
        // The local check is "what can be said on the spot"; the manager's check is "what is finally computed". Both sentences use the
        // same case of the same enum, so there are not two copies of the wording.
        guard normalPin != duressPin else {
            pinFeedback = PopopxDuressSetupError.pinsMustDiffer.errorDescription
            PopopxHaptics.notice(.warning)
            toast.show(Copy.pinToastRejected, kind: .danger)
            return
        }
        isWritingPins = true
        defer { isWritingPins = false }
        do {
            let generated = try await duress.setNormalPin(
                normalPin,
                confirming: normalConfirm,
                nativePasscode: nativePasscode,
                nativeSelfDestructCode: nativeSelfDestructCode
            )
            try await duress.setDuressPin(duressPin, confirming: duressConfirm)
            clearPinFields()
            // This call may have generated the 12 words along the way (`setNormalPin` generates only when "no mnemonic existed before",
            // returns nil if one exists, and never overwrites the sheet in hand). If words come back, the sheet **does not close**: this array is
            // their only appearance on the interface in readable form; close it and they can never be reassembled — the manager keeps
            // both the derived value and the readable plaintext as two records, but "re-viewing" requires passing verification again (entry password or Face ID) to reach.
            if let generated, !generated.isEmpty {
                freshMnemonic = generated
            } else {
                showsPinSheet = false
            }
            PopopxHaptics.notice(.success)
            toast.show(Copy.pinToastWritten, kind: .encrypted)
        } catch let setup as PopopxDuressSetupError {
            // The fifteen `errorDescription` sentences are displayed verbatim, not rewritten or processed.
            pinFeedback = setup.errorDescription
            clearPinFields()
            PopopxHaptics.notice(.error)
            toast.show(Copy.pinToastRejected, kind: .danger)
        } catch {
            // At this point only errors from outside this module remain (which theoretically should not occur). This sentence likewise echoes back no input.
            pinFeedback = Copy.pinUnexpectedFailure
            clearPinFields()
            PopopxHaptics.notice(.error)
            toast.show(Copy.pinToastRejected, kind: .danger)
        }
    }

    private func clearAllPins() {
        duress.clearAllPins()
        clearPinFields()
        toast.show(Copy.duressCleared, kind: .danger)
    }

    /// Clears the six input fields, that feedback sentence, and the "incidentally generated 12 words" in one go. A passphrase's interface copy should not
    /// outlive the occasion it is used for.
    /// The two native cells (entry code, ghost self-destruct code) are included, covering the "old code typed wrong" case too (both
    /// `...Incorrect` go through the same catch): better to make the owner retype the old code than let it survive one more redraw on the page.
    /// The two cells are mutually exclusive on the same page (`nativeEntryPasswordActive` and `nativeSelfDestructGhostActive`
    /// can never both be true), but the clearing does not check this condition — one fewer line of judgement is one more chance to break it later.
    ///
    /// `freshMnemonic` is in it too, so `writePins`' success branch must be "clear first, then assign":
    /// the other order amounts to wiping the words the moment they were copied down.
    private func clearPinFields() {
        normalPin = ""
        normalConfirm = ""
        duressPin = ""
        duressConfirm = ""
        nativePasscode = ""
        nativeSelfDestructCode = ""
        pinFeedback = nil
        freshMnemonic = nil
    }

    // MARK: what account to hand over after self-destruct (retention strategy, choose one of three)
    //
    // In this version module 3 replaced the two-choice `PopopxDuressRebuildMode` with the associated-value-bearing
    // `PopopxDuressRetentionStrategy`: with associated values it cannot be `CaseIterable`, so its own comments fix the convention hard
    // — "the segmented picker is assembled by the UI in the order of `segmentTitles`, and `segmentIndex` is the only mapping convention". This page does exactly as that says:
    // the picker's `Selection` is the subscript Int, the three tier titles are used from module 3 unchanged, and coming back only passes
    // through the `fromSegmentIndex(_:)` gate (out of range it falls back to the default tier itself; this page does not guess).

    private var retentionOptions: [PopopxSegmentedControl<Int>.Option] {
        PopopxDuressRetentionStrategy.segmentTitles.enumerated()
            .map { .init(selection: $0.offset, title: $0.element) }
    }

    /// UI subscript ⇄ the strategy itself. Writing this `Binding` is the only place on this page that changes the retention strategy.
    private var retentionBinding: Binding<Int> {
        Binding(
            get: { duress.retentionStrategy.segmentIndex },
            set: { duress.retentionStrategy = PopopxDuressRetentionStrategy.fromSegmentIndex($0) }
        )
    }

    private var rebuildCard: some View {
        PopopxSectionCard(Copy.groupRebuild, footnote: Copy.rebuildFootnote) {
            PopopxSegmentedControl(
                retentionOptions,
                title: { PopopxDuressRetentionStrategy.segmentTitles[$0] },
                selection: retentionBinding
            )
            .accessibilityIdentifier("popopx.antiTheft.rebuild")
            .padding(.bottom, PopopxMetrics.spaceXS)
            // The current tier's `note` comes directly from the enum itself; this page does not rewrite it.
            thresholdLine(Copy.rebuildCurrentHeadline, duress.retentionStrategy.note)
            // `.retainExistingProfile` carries `profileId` and `displayName` — that is identity information, not a preference,
            // so this tier only counts once the owner taps a name from the **underlying real identity list**. The list's source is
            // `listUsersAsync()` (module 3's self-destruct path reads the very same interface; both sides seeing the same identities is what is correct),
            // not that `ChatModel.users` copy which may have been read at launch.
            if duress.retentionStrategy.isRetainExisting {
                AntiTheftDivider()
                PopopxPickerRow(
                    Copy.retainRow,
                    value: retainValueText,
                    systemImage: "person.crop.circle",
                    tint: .brand
                ) {
                    PopopxHaptics.impact(.light)
                    Task { @MainActor in
                        await loadRetainCandidates()
                        showsRetainSheet = true
                    }
                }
                .accessibilityIdentifier("popopx.antiTheft.retainEntry")
                .accessibilityValue(retainValueText)
                // Fool-proofing: when there is only one identity, "keep the specified nickname" and "keep nothing" are actually the same thing,
                // while the owner thinks they left themselves a fallback. So this line must appear before they tap the entry row, not after.
                // Judge only after the list has truly been fetched: `retainCandidates.count` is 0 when it was never loaded,
                // and treating that as "only one identity" would lie.
                if retainLoaded, retainCandidates.count < 2 {
                    thresholdLine(Copy.retainFoolproofHeadline, Copy.retainFoolproofNote)
                }
            }
            AntiTheftDivider()
            PopopxToggleRow(
                Copy.decoyRow,
                note: Copy.decoyNote,
                systemImage: "circle.grid.2x2",
                tint: .neutral,
                isOn: $decoyEnabled
            )
        }
    }

    // MARK: retained-identity roll-call (picker + data source)
    //
    // Shape follows `timeoutSheet`: entry row + radio table inside the sheet + one "close" — this page's only "N-choose-one" interaction convention.
    // The only difference from the tier table: the data here comes from an underlying async interface, so an "empty list" must say a plain-language line itself,
    // and never leave a blank patch that makes people think the feature is broken.

    /// The entry row's tail value. When no identity has been named it clearly says "not yet named", and never falls back to the first identity's name —
    /// that would make the owner think a choice was already made while what is actually stored is the empty shell `profileId: 0`.
    private var retainValueText: String {
        if case .retainExistingProfile(_, let displayName) = duress.retentionStrategy,
           !displayName.isEmpty {
            return displayName
        }
        return Copy.retainUnchosen
    }

    /// The header sentence: with only one identity it swaps to the fool-proofing line; the two are mutually exclusive and never appear together.
    /// The name deliberately differs from `Copy.retainSheetSubtitle` — same-named computed properties are the easiest thing to turn into a self-reference in the next edit.
    private var retainSheetHint: String {
        retainLoaded && retainCandidates.count < 2 ? Copy.retainFoolproofNote : Copy.retainSheetSubtitle
    }

    private var retainSheet: some View {
        NavigationStack {
            PopopxSheetContainer(Copy.retainSheetTitle, subtitle: retainSheetHint) {
                PopopxSectionCard {
                    if retainCandidates.isEmpty {
                        Text(Copy.retainSheetEmpty)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, PopopxMetrics.spaceXS)
                    } else {
                        ForEach(Array(retainCandidates.enumerated()), id: \.element.id) { index, candidate in
                            if index > 0 {
                                AntiTheftDivider()
                            }
                            PopopxRadioRow(
                                candidate.name,
                                selected: duress.retentionStrategy.isRetainExisting
                                    && duress.retentionStrategy.retainedProfileId == candidate.id
                            ) {
                                PopopxHaptics.selection()
                                duress.retentionStrategy = .retainExistingProfile(
                                    profileId: candidate.id,
                                    displayName: candidate.name
                                )
                                showsRetainSheet = false
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.close) { showsRetainSheet = false }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    /// Reads the underlying identity list once. **Read-only**; touches no configuration.
    ///
    /// Why `listUsersAsync()` rather than `ChatModel.shared.users`: the latter is that copy in the model which may still be the one
    /// read at launch, and the consequence of tapping this cell is "physically delete the remaining identities" — one row missing on screen means one more real identity deleted underneath.
    /// Module 3 executes that same interface at self-destruct time; both sides reading the same truth is what maximizes the chance that the selected id still exists at the moment of erasure.
    ///
    /// Failure and "truly not a single identity" are merged into the same interface conclusion (empty-table copy + the fool-proofing line): the correct behavior here is
    /// **to make it unselectable**, not to throw up an error banner. The real fallback lives on the self-destruct side — when `profileId` no longer exists by then,
    /// module 3, per the brief, safely downgrades to a full `.simulatedDecoy` rebuild and never sticks on a white screen.
    private func loadRetainCandidates() async {
        do {
            let users = try await listUsersAsync()
            retainCandidates = users.map {
                PopopxRetainCandidate(id: $0.user.userId, name: $0.user.displayName)
            }
        } catch {
            retainCandidates = []
        }
        retainLoaded = true
    }

    // MARK: rehearsal entry

    private var drillCard: some View {
        PopopxSectionCard(Copy.groupDrill, footnote: Copy.drillFootnote) {
            AntiTheftRowLink(Copy.drillRow, systemImage: "play.circle.fill", tint: .brand) {
                PopopxAntiTheftDrillView()
                    .navigationTitle(Copy.drillPageTitle)
            }
            .accessibilityIdentifier("popopx.antiTheft.drillEntry")
        }
    }

    // MARK: footer risk notes

    /// All three sentences are bad news, and all three are true. This cell's purpose is not a disclaimer but letting the owner, before pressing "write the two codes",
    /// already know what they are giving up and what they are keeping.
    private var riskCard: some View {
        PopopxSectionCard(Copy.groupRisk) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
                riskLine(Copy.riskIrreversible)
                riskLine(Copy.riskForensics)
                riskLine(Copy.riskFalsePositive)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func riskLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: "questionmark.circle")
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxPalette.labelHint)
                .accessibilityHidden(true)
            Text(text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: formatting

    /// Thresholds and readings always use the same formatting; `PopopxType.metric` is monospaced digits, so ticking numbers never shove the layout around.
    private func fixed(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }
}

// MARK: - Rehearsal subpage

/// One-tap simulation rehearsal.
///
/// **The invariant of this page (load-bearing, not decoration)**: this page only calls `PopopxMotionCriteria`'s static pure functions
/// (`evaluate(samples:sensitivity:)`, `syntheticSnatch()`, `syntheticFreeFall()`) and
/// `PopopxDuressAuthManager.verify(pin:)`. Nowhere does it reference `PopopxAppLockState.lock(reason:)`,
/// `PopopxDuressAuthManager.submit(pin:)`, or `PopopxStorageWipe`, and nowhere does it start or stop sensors.
/// At the type level this is checkable: `evaluate` returns `PopopxMotionVerdict` (a value type, which cannot carry side effects),
/// `verify`'s comment states "pure verification, zero side effects", and the only road to the wipe is `submit`
/// (inside `submit(pin:)`, only a `.duress` hit runs `runDuressWipe(mode:)`). Even when the snatch/free-fall criteria hit in the real flow, the consequence is only
/// `lock(reason:)`, which never leads to erasure (see the section on module 1's bet) — the rehearsal does not even do that step.
/// So: the rehearsal does not lock the screen, does not wipe data, does not touch the Keychain, and does not read the real sensors.
@MainActor
private struct PopopxAntiTheftDrillView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The result panel draws its own card surface, so whether it carries a shadow or a hairline highlight must be decided by mode (that ruling of `popopxCardElevation`
    /// ).
    @Environment(\.colorScheme) private var colorScheme

    /// Read-only on it, never written: nowhere on the rehearsal page does anything change module 1's switches or criteria.
    @Bindable private var motion = PopopxAntiTheftMotionGuard.shared
    @Bindable private var duress = PopopxDuressAuthManager.shared

    @State private var toast = PopopxToastModel()

    /// The verdicts of the two synthetic sample strings. What is stored is the `PopopxMotionVerdict` itself rather than a pre-written sentence,
    /// so the sentence on screen is always the one just computed.
    @State private var snatchRun: AntiTheftDrillRun?
    @State private var freeFallRun: AntiTheftDrillRun?

    @State private var drillPin = ""
    @State private var drillOutcome: PopopxDuressAuthOutcome?
    @State private var drillFeedback: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                invariantCard
                sensorCard
                snatchCard
                freeFallCard
                duressDrillCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
            .popopxAnimation(PopopxSpring.fluid, value: animationKey, reduceMotion: reduceMotion)
        }
        .background(PopopxPalette.base)
        .navigationBarTitleDisplayMode(.inline)
        .popopxToast(toast)
    }

    private var animationKey: String {
        // `?? 0` pins the two Optionals down to Int: interpolating an Optional directly yields the debug description (a compiler warning on the spot),
        // and that string could change every round of rehearsal, making the animation key shake by itself. Slots never run read as a fixed 0.
        "\(snatchRun?.verdict.hashValue ?? 0)-\(freeFallRun?.verdict.hashValue ?? 0)-\(motion.sensitivity.wireValue)-\(drillOutcome != nil)"
    }

    // MARK: invariant declaration

    private var invariantCard: some View {
        PopopxSectionCard(Copy.drillInvariantGroup, footnote: Copy.drillInvariantFootnote) {
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "checkmark.shield.fill")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.successInk)
                    .accessibilityHidden(true)
                Text(Copy.drillInvariantLine)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: this device's sensors

    private var sensorCard: some View {
        PopopxSectionCard(Copy.drillSensorGroup, footnote: Copy.drillSensorFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                thresholdLine(
                    Copy.drillSensorAvailableHeadline,
                    motion.motionAvailable ? Copy.drillSensorAvailableYes : Copy.drillSensorAvailableNo
                )
                thresholdLine(Copy.drillSensorRunningHeadline, motion.isRunning ? Copy.drillRunningYes : Copy.drillRunningNo)
                thresholdLine(Copy.drillPeakGHeadline, fixed(motion.peakG, digits: 2))
                thresholdLine(Copy.drillPeakOmegaHeadline, fixed(motion.peakOmega, digits: 2))
                thresholdLine(Copy.drillVerdictHeadline, liveVerdictSentence)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: Copy.drillSensorGroup))
        }
    }

    private var liveVerdictSentence: String {
        guard let verdict = motion.lastVerdict else {
            return Copy.drillVerdictNone
        }
        return verdictSentence(verdict)
    }

    // MARK: snatch rehearsal

    private var snatchCard: some View {
        PopopxSectionCard(Copy.drillSnatchGroup, footnote: Copy.drillSnatchFootnote) {
            PopopxButton(Copy.drillSnatchRun, systemImage: PopopxLockReason.snatch.symbolName, role: .secondary) {
                runSnatchDrill()
            }
            if let run = snatchRun {
                AntiTheftDivider()
                resultPlate(for: run)
            }
        }
    }

    private func runSnatchDrill() {
        // Synthetic samples + static pure functions. There is no `lock(reason:)` here, and none would be allowed.
        let samples = PopopxMotionCriteria.syntheticSnatch()
        let verdict = PopopxMotionCriteria.evaluate(samples: samples, sensitivity: motion.sensitivity)
        snatchRun = AntiTheftDrillRun(
            verdict: verdict,
            sampleCount: samples.count,
            peakG: samples.map(\.g).max() ?? 0,
            peakOmega: samples.map(\.omega).max() ?? 0,
            thresholdG: motion.sensitivity.spikeG,
            thresholdOmega: motion.sensitivity.spinOmega
        )
        // The haptic is just the receipt for this line of text appearing, not the hint that "the phone is vibrating = it is locked".
        PopopxHaptics.notice(verdict.isHit ? .warning : .success)
    }

    // MARK: free-fall rehearsal

    private var freeFallCard: some View {
        PopopxSectionCard(Copy.drillFreeFallGroup, footnote: Copy.drillFreeFallFootnote) {
            PopopxButton(Copy.drillFreeFallRun, systemImage: PopopxLockReason.freeFall.symbolName, role: .secondary) {
                runFreeFallDrill()
            }
            if let run = freeFallRun {
                AntiTheftDivider()
                resultPlate(for: run)
            }
        }
    }

    private func runFreeFallDrill() {
        let samples = PopopxMotionCriteria.syntheticFreeFall()
        let verdict = PopopxMotionCriteria.evaluate(samples: samples, sensitivity: motion.sensitivity)
        // The free-fall threshold is one of `PopopxMotionCriteria`'s fixed constants, unrelated to the sensitivity tier, so what is reported here
        // takes those statics directly rather than a tier value.
        freeFallRun = AntiTheftDrillRun(
            verdict: verdict,
            sampleCount: samples.count,
            peakG: samples.map(\.g).max() ?? 0,
            peakOmega: samples.map(\.omega).max() ?? 0,
            thresholdG: PopopxMotionCriteria.impactG,
            thresholdOmega: nil
        )
        PopopxHaptics.notice(verdict.isHit ? .warning : .success)
    }

    // MARK: result panel

    /// One rehearsal's result: the verdict, the peak against the threshold, and "whether the current tier would trigger".
    private func resultPlate(for run: AntiTheftDrillRun) -> some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            Text(run.verdict.isHit ? Copy.drillWillTrigger : Copy.drillWillNotTrigger)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(run.verdict.isHit ? PopopxPalette.label : PopopxPalette.labelSecondary)
            Text(verdictSentence(run.verdict))
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.label)
                .fixedSize(horizontal: false, vertical: true)

            gauge(
                Copy.drillGaugeG,
                value: "\(fixed(run.peakG, digits: 2)) / \(fixed(run.thresholdG, digits: 2))",
                fraction: run.peakG / run.thresholdG
            )
            // `thresholdOmega == nil` says "this criterion does not look at angular velocity at all". Then only the peak is reported,
            // and no made-up ratio bar is drawn — the free-fall verdict contains no ω threshold at all (see `freeFallVerdict`).
            if let thresholdOmega = run.thresholdOmega {
                gauge(
                    Copy.drillGaugeOmega,
                    value: "\(fixed(run.peakOmega, digits: 2)) / \(fixed(thresholdOmega, digits: 2))",
                    fraction: run.peakOmega / thresholdOmega
                )
            } else {
                thresholdLine(Copy.drillOmegaNoThresholdHeadline, fixed(run.peakOmega, digits: 2))
            }

            Text(String(format: Copy.drillSampleCountFormat, "\(run.sampleCount)"))
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PopopxMetrics.spaceS)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .popopxCardElevation(colorScheme: colorScheme)
        .accessibilityElement(children: .combine)
    }

    /// The threshold comparison bar. Exceeding the threshold only means "will re-authenticate once", so the brand color is used rather than danger red:
    /// in this app red speaks only of the unrecoverable things.
    private func gauge(_ label: String, value: String, fraction: Double) -> some View {
        let clamped = min(max(fraction, 0), 1)
        return VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                Text(label)
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                Spacer(minLength: PopopxMetrics.space2XS)
                Text(value)
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.label)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(PopopxPalette.separator)
                    Rectangle().fill(PopopxPalette.brand)
                        .frame(width: proxy.size.width * clamped)
                }
            }
            .frame(height: PopopxMetrics.spaceXS)
            .clipShape(.rect(cornerRadius: PopopxMetrics.space2XS))
            .accessibilityHidden(true)
        }
    }

    private func thresholdLine(_ headline: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            Text(headline)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
            Text(value)
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.label)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PopopxMetrics.space2XS)
        }
    }

    // MARK: duress-code rehearsal

    private var duressDrillCard: some View {
        PopopxSectionCard(Copy.drillDuressGroup, footnote: Copy.drillDuressFootnote) {
            PopopxTextField(Copy.drillDuressFieldLabel, prompt: Copy.drillDuressFieldPrompt, text: $drillPin, isSecure: true)
                .onChange(of: drillPin) { _, newValue in
                    let filtered = String(
                        newValue
                            .filter { PopopxDuressAuthManager.digits.contains($0) }
                            .prefix(PopopxDuressAuthManager.pinLength)
                    )
                    if filtered != newValue { drillPin = filtered }
                }
            PopopxButton(Copy.drillDuressRun, systemImage: "number", role: .primary) {
                await runDuressDrill()
            }
            .padding(.top, PopopxMetrics.spaceXS)

            if let outcome = drillOutcome {
                AntiTheftDivider()
                Text(outcomeSentence(outcome))
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let drillFeedback {
                Text(drillFeedback)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Only `verify(pin:)` is called. It wipes nothing, plants no smoke bomb, and releases no lock; the road to the wipe is
    /// `submit(pin:)`, which this page never references. Right after verification, the copy in the input field is cleared.
    private func runDuressDrill() async {
        let pin = drillPin
        drillPin = ""
        drillOutcome = nil
        drillFeedback = nil
        guard PopopxDuressAuthManager.isValidPin(pin) else {
            drillFeedback = PopopxDuressSetupError.malformedPin.errorDescription
            PopopxHaptics.notice(.warning)
            return
        }
        guard duress.normalConfigured else {
            drillOutcome = .notConfigured
            return
        }
        let outcome = await duress.verify(pin: pin)
        drillOutcome = outcome
        // When the duress code hits there is no celebrating: that cell says "this code wipes your data".
        PopopxHaptics.notice(outcome == .duress ? .warning : .success)
        toast.show(Copy.drillDuressNoEraseToast, kind: .success)
    }

    private func outcomeSentence(_ outcome: PopopxDuressAuthOutcome) -> String {
        switch outcome {
        case .unlocked: return Copy.drillOutcomeNormal
        case .duress: return Copy.drillOutcomeDuress
        case .wrong: return Copy.drillOutcomeWrong
        case .notConfigured: return Copy.drillOutcomeNotConfigured
        case .lockedOut: return Copy.drillOutcomeLockedOut
        }
    }

    /// The verdict sentence: the numbers come from the criteria themselves, the sentence pattern from this page.
    private func verdictSentence(_ verdict: PopopxMotionVerdict) -> String {
        switch verdict {
        case .none:
            return Copy.drillVerdictNone
        case .snatch(let g, let omega):
            return String(format: Copy.drillVerdictSnatchFormat, fixed(g, digits: 2), fixed(omega, digits: 2))
        case .freeFall(let peakG, let weightlessMs):
            return String(
                format: Copy.drillVerdictFreeFallFormat,
                fixed(peakG, digits: 2),
                "\(Int(weightlessMs.rounded()))"
            )
        }
    }

    private func fixed(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }
}

// MARK: - one rehearsal's verdict

/// Stores the verdict's inputs and outputs, not the verdict copy: the conclusion is re-derived from `verdict` every time, so once the tier changes,
/// the previous rehearsal result does not linger on screen as a sentence saying things that no longer hold.
private struct AntiTheftDrillRun {
    let verdict: PopopxMotionVerdict
    let sampleCount: Int
    let peakG: Double
    let peakOmega: Double
    /// Thresholds for comparison: for the snatch it is the current tier's `spikeG`/`spinOmega`; for free fall there is only the fixed constant `impactG`,
    /// and that criterion does not look at angular velocity, so `thresholdOmega` gets nil.
    let thresholdG: Double
    let thresholdOmega: Double?
}

// MARK: - row

/// Pushes an existing page. The shape follows `PopopxMeRowLink` (PopopxMeView.swift): the appearance reuses `PopopxPickerRow`,
/// but the tap belongs to the outer `NavigationLink` — the atom-library row is itself a `Button`, and nested buttons would swallow the link's tap,
/// so the whole row is made unhittable and kept out of the accessibility tree, with the link itself carrying the same-named label and hint.
@MainActor
private struct AntiTheftRowLink<Destination: View>: View {
    private let title: String
    private let value: String?
    private let systemImage: String?
    private let tint: PopopxIconTint
    private let destination: () -> Destination

    init(
        _ title: String,
        value: String? = nil,
        systemImage: String? = nil,
        tint: PopopxIconTint = .neutral,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            PopopxPickerRow(title, value: value, systemImage: systemImage, tint: tint) { }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, minHeight: PopopxMetrics.minHitTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text(verbatim: Copy.drillOpenHint))
    }
}

/// The divider inside cards. The same-named one at `PopopxControls.swift:853` sits only inside the `#if DEBUG` gallery scope,
/// while `PopopxMeDivider` and `PopopxSettingsDivider` each carry a private one; this page follows the same convention.
/// One row inside the "name which anonymous identity to retain" cell: a projection of the underlying `users`, carrying only the two things the interface needs.
/// The id stays the underlying raw `Int64`; no self-made UUID and no conversion — this table and the `profileId` stored in `PopopxDuressRetentionStrategy`
/// must use the same number; a mapping layer in between is exactly where errors would appear.
private struct PopopxRetainCandidate: Identifiable, Hashable {
    let id: Int64
    let name: String
}

private struct AntiTheftDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - copy

/// Every Chinese sentence on the page appears exactly once here. The fifteen failure sentences for dual-password writing and mnemonic viewing are not here: those fifteen are
/// quoted verbatim from `PopopxDuressSetupError.errorDescription`; copying them over would produce two sets of wording.
private enum Copy {
    static let pageTitle = NSLocalizedString("Anti-theft lock & self-destruct", comment: "")
    static let close = NSLocalizedString("Close", comment: "")
    /// and `close` are two different things: `close` means "leave this sheet"; `cancel` means "do not execute this unrecoverable step".
    static let cancel = NSLocalizedString("Cancel", comment: "")

    // master switch
    static let groupMaster = NSLocalizedString("Anti-theft lock", comment: "")
    static let masterFootnote = NSLocalizedString("All three switches on this page only talk about locking; not one of them leads to erasing data. Turning anything here on can never make the phone wipe itself.", comment: "")
    static let enabledRow = NSLocalizedString("Enable anti-theft lock", comment: "")
    static let enabledNoteOn = NSLocalizedString("The sensors are sampling at 20Hz. Sampling stops the moment the screen locks, and also when the app moves to the background.", comment: "")
    static let enabledNoteOff = NSLocalizedString("Off: no sampling and no timing. The snatch-and-drop and free-fall tests are not running at all right now.", comment: "")
    static let instantBgRow = NSLocalizedString("Lock immediately in the background", comment: "")
    static let instantBgNote = NSLocalizedString("The first frame after coming back to the foreground is the lock screen, with no flash of content. Turning this off still leaves the inactivity timeout below in force.", comment: "")
    static let biometricsRow = NSLocalizedString("Biometric quick unlock", comment: "")
    static let biometricsNoteUnavailable = NSLocalizedString("This device has no usable Face ID or Touch ID, so the lock screen asks straight for the 6-digit keypad code.", comment: "")
    static let biometricsNoteFormat = NSLocalizedString("It only proves that it is you, not which code you used, so it can never lead to self-destruct. After %@ consecutive failures this session accepts only the keypad code.", comment: "")
    static let lockNowRow = NSLocalizedString("Lock once now", comment: "")
    static let lockNowButton = NSLocalizedString("Lock", comment: "")
    static let lockNowNote = NSLocalizedString("Brings up the lock screen at once and requires re-authentication, with exactly the same consequence as a sensor hit. It erases nothing.", comment: "")
    static let lockNowDone = NSLocalizedString("Locked. Returning to the app requires re-authentication.", comment: "")

    // sensitivity
    static let groupSensitivity = NSLocalizedString("Detection sensitivity", comment: "")
    static let sensitivityFootnote = NSLocalizedString("The level only changes the two snatch-and-drop thresholds. The free-fall test, the impact after weightlessness, uses fixed constants, so switching levels does not change it.", comment: "")
    static let thresholdHeadline = NSLocalizedString("Thresholds", comment: "")
    static let thresholdSpikeFormat = NSLocalizedString("G > %1$@ and ω > %2$@ rad/s", comment: "")
    static let preconditionHeadline = NSLocalizedString("Extra precondition", comment: "")
    static let preconditionFormat = NSLocalizedString("Two adjacent frames must rise by at least %1$@ g, and over the %2$@ s before the hit the average must stay inside %3$@–%4$@ g, the normal handling range.", comment: "")
    static let behaviorRow = NSLocalizedString("Non-owner behaviour", comment: "")
    static let behaviorNote = NSLocalizedString("This switch is bound to the behaviour test itself: flipping it starts or stops the sensors on the spot instead of waiting for the next launch. It only escalates to one more authentication and can never lead to erasure.", comment: "")
    static let angleRow = NSLocalizedString("Tilt threshold", comment: "")
    static let angleHeadline = NSLocalizedString("Criterion", comment: "")
    static let angleFormat = NSLocalizedString("The screen is judged suspicious and locked only when the angle stays past the chosen threshold for at least %1$@ s and there are at least %3$@ irregular touches inside %2$@ s. Smaller is more sensitive, and the price of a wrong call is one extra authentication.", comment: "")

    // idle duration
    static let groupInactivity = NSLocalizedString("Auto-lock after inactivity", comment: "")
    static let inactivityRow = NSLocalizedString("Idle wait before locking", comment: "")
    static let inactivityFootnote = NSLocalizedString("The timer only looks at whether anything touches the screen. Once it is locked the timer stops; it does not keep counting behind the lock screen.", comment: "")
    static let timeoutSheetTitle = NSLocalizedString("Auto-lock after inactivity", comment: "")
    static let timeoutSheetSubtitle = NSLocalizedString("How long after you leave the phone it closes itself. Shorter is safer, and easier to interrupt by just putting it down.", comment: "")
    static let timeoutNoteOne = NSLocalizedString("Safest: set it down to answer a message and you have to authenticate again.", comment: "")
    static let timeoutNoteThree = NSLocalizedString("Default level: a bathroom break or pouring a glass of water will not lock it.", comment: "")
    static let timeoutNoteFive = NSLocalizedString("For the cases where the phone sits in front of you for a long time untouched.", comment: "")
    static let timeoutNoteFifteen = NSLocalizedString("Close to never locking: it only closes when you have clearly left.", comment: "")
    static let timeoutNoteNever = NSLocalizedString("Never: this test stops applying altogether, leaving only the sensor and the background one.", comment: "")

    // dual passwords
    static let groupDuress = NSLocalizedString("Dual-code self-destruct", comment: "")
    static let duressFootnote = NSLocalizedString("The normal code opens the door; the duress code opens it and immediately erases the identities on this device. The two codes must be different, otherwise which code you hand over is the same question either way.", comment: "")
    static let duressSwitchRow = NSLocalizedString("Enable dual-code self-destruct", comment: "")
    static let duressSwitchNoteOn = NSLocalizedString("On: while a duress code exists, entering it takes the erasure path. Turning this off deletes the duress code record on the spot.", comment: "")
    static let duressSwitchNoteOff = NSLocalizedString("Off: the duress code record is deleted, and no keypad input can lead to erasure any more.", comment: "")
    static let duressSetupRow = NSLocalizedString("Set the normal code and the duress code", comment: "")
    static let duressStatusNone = NSLocalizedString("Not set", comment: "")
    static let duressStateHeadline = NSLocalizedString("Emergency erase passcode", comment: "")
    static let duressStateSet = NSLocalizedString("Set", comment: "")
    static let duressStateUnset = NSLocalizedString("Not set", comment: "")
    static let duressStatusNormalOnly = NSLocalizedString("Normal code only", comment: "")
    static let duressStatusBoth = NSLocalizedString("Both codes are set", comment: "")
    static let duressClearRow = NSLocalizedString("Remove both codes", comment: "")
    static let duressCleared = NSLocalizedString("The records of both codes were deleted", comment: "")
    static let duressOffDialogTitle = NSLocalizedString("Turn off dual-code self-destruct?", comment: "")
    static let duressOffDialogConfirm = NSLocalizedString("Turn off and delete the duress code", comment: "")
    static let duressOffDialogMessage = NSLocalizedString("The duress code record is deleted from secure storage at once, and after that no input can trigger an erasure. The normal code stays. Switching it back on means setting both codes again.", comment: "")
    static let duressOffDone = NSLocalizedString("Dual codes disabled, duress code record deleted", comment: "")
    static let clearDialogTitle = NSLocalizedString("Remove both codes?", comment: "")
    static let clearDialogConfirm = NSLocalizedString("Delete both codes", comment: "")
    static let clearDialogMessage = NSLocalizedString("The records of the normal code and of the duress code are both deleted, and the lock screen falls back to only the app's own authentication gate. This step cannot be undone, but it deletes no chat data.", comment: "")

    static let pinSheetTitle = NSLocalizedString("Set the two codes", comment: "")
    static let pinSheetSubtitle = NSLocalizedString("Every code has to be typed twice: the cost of writing a wrong one here is unrecoverable.", comment: "")
    static let pinGroupNormal = NSLocalizedString("Normal passcode", comment: "")
    static let pinGroupDuress = NSLocalizedString("Duress passcode", comment: "")
    static let pinNormalFootnote = NSLocalizedString("This code only opens the door; it does the same job as the app passcode gate upstream.", comment: "")
    static let pinDuressFootnote = NSLocalizedString("This code opens the door and at the same time erases the identities on this device. It is rejected outright if it equals the normal code.", comment: "")
    static let pinNormalLabel = NSLocalizedString("Normal passcode", comment: "")
    static let pinNormalConfirmLabel = NSLocalizedString("Type the normal passcode again", comment: "")
    static let pinDuressLabel = NSLocalizedString("Duress passcode", comment: "")
    static let pinDuressConfirmLabel = NSLocalizedString("Type the duress passcode again", comment: "")
    static let pinPrompt = NSLocalizedString("6 digits", comment: "")
    // The native entry-code section: it renders only when the Keychain truly still holds an old code, so these three lines are normally invisible.
    static let pinNativeGroup = NSLocalizedString("Turn off the app's own entry passcode", comment: "")
    static let pinNativeLabel = NSLocalizedString("Existing entry passcode", comment: "")
    static let pinNativePrompt = NSLocalizedString("4 to 16 digits", comment: "")
    static let pinNativeFootnote = NSLocalizedString("This device still has the app's own entry passcode switched on: when unlocking it shows its keypad once first and POPOPX shows its keypad again, and the two keypads do the same job. Enter it correctly and we turn it off, so from now on only the normal code above is accepted. What goes off with it is the self-destruct code that only that old keypad could accept: once the old keypad is gone it has no way in, and keeping it would only make the row in Privacy and Security read enabled. This step does not rebuild the database keys and not one character of chat data moves; getting it back means setting it up again on the Privacy and Security page.", comment: "")
    // The ghost self-destruct-code section: it renders only when the entry code is already gone and just an untypeable self-destruct code remains, mutually exclusive with the three sections above.
    // The prompt line shares `pinNativePrompt` — the two codes come from the same keyboard (the same `PasscodeEntry`), and the format rules are the same.
    static let pinNativeSDGroup = NSLocalizedString("Turn off the leftover self-destruct passcode", comment: "")
    static let pinNativeSDLabel = NSLocalizedString("Existing self-destruct passcode", comment: "")
    static let pinNativeSDFootnote = NSLocalizedString("An old self-destruct passcode is still on this device, but only the app's own keypad could take it and that keypad no longer appears: it can neither be triggered nor seen now, and it only makes the row in Privacy and Security read enabled. Enter it correctly and we turn it off together with that row; enter it wrong and nothing changes this time, and the two new codes above are not written either. If the authentication method is still on the app passcode level it also falls back to system authentication. This step does not rebuild the database keys and not one character of chat data moves.", comment: "")
    static let pinIrreversibleGroup = NSLocalizedString("Before this is written down", comment: "")
    static let pinIrreversibleNote = NSLocalizedString("These two codes exist only as derived values; the plain text is never stored on this device. When you forget the entry passcode the only way out is the 12 English words you copied down by hand, and the mnemonic phrase itself has no recovery channel at all, so this write generates one on the way. Whether you copy it down is your call. That one tap in the confirmation dialog is the last gate on this consequence.", comment: "")
    static let pinWriteButton = NSLocalizedString("Write both codes", comment: "")
    static let pinStateEmptyFormat = NSLocalizedString("Nothing typed yet, it needs exactly %@ digits", comment: "")
    static let pinStateShortFormat = NSLocalizedString("%2$@ of %1$@ digits typed", comment: "")
    static let pinStateMatched = NSLocalizedString("The two entries match", comment: "")
    static let pinStateMismatched = NSLocalizedString("The two entries do not match", comment: "")
    static let pinToastWritten = NSLocalizedString("Both codes were written to secure storage", comment: "")
    static let pinToastRejected = NSLocalizedString("Nothing was written, see the reason above", comment: "")
    static let pinUnexpectedFailure = NSLocalizedString("The write failed, please try again later", comment: "")
    static let commitDialogTitle = NSLocalizedString("Confirm writing these two codes?", comment: "")
    static let commitDialogConfirm = NSLocalizedString("Confirm and write", comment: "")
    static let commitDialogMessage = NSLocalizedString("Overwriting an existing normal or duress code cannot be undone and cannot be recovered. Check both entries once more, in particular whether a fingertip was dragged one digit off by oil on the screen.", comment: "")

    // 12-word mnemonic
    static let groupMnemonic = NSLocalizedString("12-word recovery mnemonic phrase", comment: "")
    static let mnemonicFootnote = NSLocalizedString("The only way out when you forget the entry passcode: type these 12 English words correctly on the lock screen and you can set a new entry passcode. The phrase is generated on this device, and secure storage keeps both its derived value for the lock screen to compare and the readable text, which exists only so this page can show it again.", comment: "")
    static let mnemonicStateHeadline = NSLocalizedString("Mnemonic phrase", comment: "")
    static let mnemonicStateSet = NSLocalizedString("Generated", comment: "")
    static let mnemonicStateUnset = NSLocalizedString("Not generated", comment: "")
    static let mnemonicRow = NSLocalizedString("View or regenerate", comment: "")
    static let mnemonicRowReveal = NSLocalizedString("Needs the entry passcode", comment: "")
    /// This line is only used when `mnemonicFaceIDOffered` is true: when that gate is not open the row's tail must not mention Face ID.
    static let mnemonicRowRevealEither = NSLocalizedString("Needs the entry passcode or Face ID", comment: "")
    static let mnemonicRowGenerate = NSLocalizedString("Generate now", comment: "")
    static let mnemonicConsequence = NSLocalizedString("Resetting the entry passcode with the mnemonic phrase on the lock screen also clears the emergency erase passcode back to not set: that code then no longer exists, and handing it over would erase no data either. After the reset, come back to the previous page and set the emergency erase passcode once more.", comment: "")
    static let mnemonicSheetTitle = NSLocalizedString("12-word recovery mnemonic phrase", comment: "")
    static let mnemonicSheetHintHave = NSLocalizedString("Type the current entry passcode once before the phrase is shown; regenerating a new phrase asks for this same gate too. This prompt is not counted in the lock screen failure counter, for the reason explained below.", comment: "")
    static let mnemonicSheetHintHaveBiometric = NSLocalizedString("Type the current entry passcode, or prove yourself once with Face ID, before the phrase is shown; regenerating a new phrase accepts either of these two gates too. This prompt is not counted in the lock screen failure counter, for the reason explained below.", comment: "")
    static let mnemonicSheetHintNone = NSLocalizedString("This device has no mnemonic phrase yet. Generate one and copy the 12 English words onto paper right there and then.", comment: "")
    static let mnemonicSheetGroup = NSLocalizedString("Phrase", comment: "")
    static let mnemonicSheetFootnote = NSLocalizedString("The word list is the standard BIP-39 English list of 2048 words, and the 12 words are derived from 16 random bytes plus a 4-bit checksum, so the order and the spelling both have to be copied exactly. The derivation uses PBKDF2-HMAC-SHA256 with 100,000 iterations, so one tap waits about a third of a second and that is not a hang; the Face ID button waits for the system sheet, which is not a hang either.", comment: "")
    static let mnemonicSheetPinLabel = NSLocalizedString("Current entry passcode", comment: "")
    static let mnemonicSheetReveal = NSLocalizedString("Verify and show", comment: "")
    /// Paired with the line above: each of the two buttons states which gate it uses, so the owner knows which ask they are pressing.
    static let mnemonicSheetRevealFaceID = NSLocalizedString("Verify with Face ID and show", comment: "")
    /// The explanation line on the system Face ID sheet. Following Apple's convention the app name is not written (the system supplies it),
    /// and it says only what this ask does: not "unlock", but "show the 12 words".
    static let mnemonicSheetFaceIDReason = NSLocalizedString("Show your 12-word recovery mnemonic phrase", comment: "")
    static let mnemonicSheetHide = NSLocalizedString("Hide the phrase", comment: "")
    static let mnemonicSheetGenerate = NSLocalizedString("Generate the 12-word mnemonic phrase", comment: "")
    /// The line for when no gate can be walked (the button is disabled then).
    static let mnemonicSheetRegenerate = NSLocalizedString("Regenerate a new phrase", comment: "")
    /// The same vocabulary as the two "view" buttons above: a bare "verify", without a qualifier, means that password field.
    static let mnemonicSheetRegenerateVerified = NSLocalizedString("Verify and regenerate", comment: "")
    static let mnemonicSheetRegenerateFaceID = NSLocalizedString("Verify with Face ID and regenerate", comment: "")
    /// The explanation line on the system Face ID sheet, paired with the "view" ask: what this ask does is not "show the words",
    /// but "void the old one and get a new set". Likewise without the app name.
    static let mnemonicRegenFaceIDReason = NSLocalizedString("Regenerate your 12-word recovery mnemonic phrase", comment: "")
    static let mnemonicSheetPaperGroup = NSLocalizedString("Copy it down", comment: "")
    static let mnemonicSheetPaperNote = NSLocalizedString("Once this panel is closed there is no way left on this device to show these 12 words again, unless next time you still pass the verification gate: type the current entry passcode correctly, or, while biometric quick unlock is on, let the machine recognise you. Please copy them onto paper right now: no screenshot, no typing them into any cloud note, and no relying on the system clipboard. For that reason this panel does not allow selecting the text, because a selection may end up in the clipboard, and the clipboard can be read by other apps and can sync to other devices through iCloud.", comment: "")
    static let mnemonicSheetWhyGroup = NSLocalizedString("Why this prompt is not counted", comment: "")
    static let mnemonicSheetWhyNoCount = NSLocalizedString("Why a failure here does not enter the cool-down table: this prompt guards against an owner who got the words wrong, not against someone who holds the phone and guesses. If it counted, the settings page would become a second place to guess at, while an owner who once mis-copies, and getting 12 words out of order is common, would lock themselves into a 1 hour cool-down, exactly in the place where that hurts most. The prompt that really leads to a reset is on the lock screen, and only that one counts.", comment: "")
    static let mnemonicRegenTitle = NSLocalizedString("Void the old 12 words?", comment: "")
    static let mnemonicRegenConfirm = NSLocalizedString("Void the old phrase and generate", comment: "")
    static let mnemonicRegenMessage = NSLocalizedString("Your identity has already been verified, so this tap will not ask a second time. The old phrase is deleted from secure storage at once, and the copy on paper is void with it. The new 12 words are shown in full on this screen only once; the entry passcode and the emergency erase passcode are unaffected.", comment: "")
    static let mnemonicGridLabel = NSLocalizedString("12 English mnemonic words in two numbered columns", comment: "")
    static let mnemonicToastShown = NSLocalizedString("Phrase shown; it disappears as soon as you close this panel", comment: "")
    static let mnemonicToastRejected = NSLocalizedString("Nothing was shown, see the reason above", comment: "")
    /// The "regenerate" ask's failure announcement must not share the line above: when this ask fails there is no "thing that did not get shown",
    /// only a generation that did not come off.
    static let mnemonicRegenToastRejected = NSLocalizedString("Nothing was regenerated, see the reason above", comment: "")
    /// Split into two sentences from `mnemonicUnexpectedFailure`: that one speaks of "reading the word set back",
    /// while this one speaks of "passing the identity gate", and this path has not even begun to read.
    static let mnemonicRegenUnexpectedFailure = NSLocalizedString("Verification failed, please try again later", comment: "")
    static let mnemonicToastGenerated = NSLocalizedString("Mnemonic phrase generated, please copy it down now", comment: "")
    static let mnemonicGenerateFailed = NSLocalizedString("Nothing generated: the write to secure storage failed, and this device is still in the state of having no mnemonic phrase", comment: "")
    static let mnemonicUnexpectedFailure = NSLocalizedString("The read failed, please try again later", comment: "")
    static let mnemonicCaptureTitle = NSLocalizedString("Copy down these 12 words", comment: "")
    static let mnemonicCaptureSubtitle = NSLocalizedString("Both codes have been written. This screen is the first, and possibly the last, time their mnemonic phrase is shown in full.", comment: "")
    static let mnemonicCaptureDone = NSLocalizedString("I have copied it down. Close", comment: "")

    // progressive anti-brute-force
    static let groupLockout = NSLocalizedString("Cool-down after wrong entries", comment: "")
    static let lockoutFootnote = NSLocalizedString("This one table governs the numeric keypad, Face ID and the mnemonic phrase together, because all three verify the same thing: the owner in person. The first 4 failures only buzz and do not lock; a slip of the finger, or one digit off because of oil on the screen, should not be treated as an attack. The counter lives in secure storage, so it is still there after the process is killed and reopened.", comment: "")
    static let lockoutStrikesHeadline = NSLocalizedString("Current failure count", comment: "")
    static let lockoutStrikesNone = NSLocalizedString("None", comment: "")
    static let lockoutStrikesFormat = NSLocalizedString("%1$@ wrong in a row · %2$@ more before the 10th", comment: "")
    static let lockoutCoolingHeadline = NSLocalizedString("Cool-down left", comment: "")
    static let lockoutCoolingFormat = NSLocalizedString("You can type again in %@", comment: "")
    static let lockoutCoolingIdle = NSLocalizedString("Not in cool-down", comment: "")
    static let lockoutScheduleHeadline = NSLocalizedString("Escalation table", comment: "")
    static let lockoutStepFormat = NSLocalizedString("Attempt %1$@ · %2$@", comment: "")
    static let lockoutScheduleFormat = NSLocalizedString("%@ · from the 9th attempt on, 1 hour each", comment: "")
    static let lockoutTenStrikeRow = NSLocalizedString("10 wrong entries in a row wipes the data", comment: "")
    static let lockoutTenStrikeNoteOn = NSLocalizedString("On: the 10th wrong entry silently runs the exact same wipe and rebuild flow as the emergency erase passcode, and no warning appears on screen first.", comment: "")
    static let lockoutTenStrikeNoteOff = NSLocalizedString("Off (default): the 10th and every later failure only locks for 1 hour and the data stays untouched.", comment: "")
    static let lockoutTenStrikeWarning = NSLocalizedString("With this level on you accept two things: someone who has an unlocked phone and 10 chances may wipe your identities for you, and you may count to 10 in the dark yourself. The price of an accidental touch, a family member pressing around, a child playing with it, or typing your own mnemonic phrase wrong ten times in a row, is carried by this one deliberate tap.", comment: "")

    // rebuild mode
    static let groupRebuild = NSLocalizedString("After self-destruct", comment: "")
    static let rebuildFootnote = NSLocalizedString("This row decides what kind of account you hand over once the wipe is done. The first option only counts when you name which anonymous identity to keep, and that is identity information, not a preference.", comment: "")
    static let rebuildCurrentHeadline = NSLocalizedString("Current choice", comment: "")
    static let retainRow = NSLocalizedString("Name the anonymous identity to keep", comment: "")
    static let retainUnchosen = NSLocalizedString("Not named yet", comment: "")
    static let retainFoolproofHeadline = NSLocalizedString("Still short of a decoy profile", comment: "")
    static let retainFoolproofNote = NSLocalizedString("Right now this device has only 1 anonymous identity, or even 0, so keeping a named nickname has no second one left to keep. First create an everyday decoy profile at the top left of the home page, then come back and name it.", comment: "")
    static let retainSheetTitle = NSLocalizedString("Which identity to keep", comment: "")
    static let retainSheetSubtitle = NSLocalizedString("Self-destruct keeps only the one you named; every other identity is physically deleted together with its conversations and its Bluetooth mesh bindings.", comment: "")
    static let retainSheetEmpty = NSLocalizedString("The underlying identity list could not be read: the chat core is unavailable right now, or this device really has no identity at all. Close this page and enter again, or first go back to the home page and check that the account is ready.", comment: "")
    static let decoyRow = NSLocalizedString("Simulated decoy content", comment: "")
    static let decoyNote = NSLocalizedString("This row only decides which kind of account you hand over; it does not affect the wipe itself. Flipping it makes the simulated decoy generator re-read immediately instead of waiting for its own refresh.", comment: "")

    // rehearsal entry
    static let groupDrill = NSLocalizedString("One-tap simulated drill", comment: "")
    static let drillRow = NSLocalizedString("Drill: snatch-and-drop, free fall, duress code", comment: "")
    static let drillOpenHint = NSLocalizedString("Open", comment: "")
    static let drillFootnote = NSLocalizedString("The drill only feeds fixed synthetic samples into the very same detection code the real runtime uses. It does not lock the screen, does not wipe, and does not read the sensors on the phone in your hand.", comment: "")

    // rehearsal subpage
    static let drillPageTitle = NSLocalizedString("Simulated drill", comment: "")
    static let drillInvariantGroup = NSLocalizedString("What this page will not do", comment: "")
    static let drillInvariantLine = NSLocalizedString("No lock, no data wipe, no Keychain write, no stopping or starting sensors.", comment: "")
    static let drillInvariantFootnote = NSLocalizedString("The guarantee is a type-level one in the implementation: this page only calls the static pure functions of the detection code and verify(pin:), and the latter is defined to have zero side effects; the method that leads to a wipe has no reference anywhere on this page.", comment: "")

    static let drillSensorGroup = NSLocalizedString("Sensor state on this device", comment: "")
    static let drillSensorFootnote = NSLocalizedString("These readings are what the sensor monitor collected itself: the peaks since this run started, and a conclusion only after a verdict has hit once. They are not the two numbers the drill computes.", comment: "")
    static let drillSensorAvailableHeadline = NSLocalizedString("Sensors available", comment: "")
    static let drillSensorAvailableYes = NSLocalizedString("Available", comment: "")
    static let drillSensorAvailableNo = NSLocalizedString("Not available", comment: "")
    static let drillSensorRunningHeadline = NSLocalizedString("Sampling now", comment: "")
    static let drillRunningYes = NSLocalizedString("Running", comment: "")
    static let drillRunningNo = NSLocalizedString("Not running", comment: "")
    static let drillPeakGHeadline = NSLocalizedString("Peak G, gravity included", comment: "")
    static let drillPeakOmegaHeadline = NSLocalizedString("Peak ω (rad/s)", comment: "")
    static let drillVerdictHeadline = NSLocalizedString("Latest verdict", comment: "")
    static let drillVerdictNone = NSLocalizedString("No verdict yet in this run", comment: "")

    static let drillSnatchGroup = NSLocalizedString("Snatch-and-drop drill", comment: "")
    static let drillSnatchRun = NSLocalizedString("Run one snatch-and-drop sample", comment: "")
    static let drillSnatchFootnote = NSLocalizedString("Sample: 10 frames of normal holding at 1.0 g, immediately followed by one frame that jumps to 3.6 g and 8.2 rad/s. Quiet first, then one violent pull, is exactly what the real test asks for.", comment: "")
    static let drillFreeFallGroup = NSLocalizedString("Free-fall drill", comment: "")
    static let drillFreeFallRun = NSLocalizedString("Run one free-fall sample", comment: "")
    static let drillFreeFallFootnote = NSLocalizedString("Sample: 150 ms of weightlessness at 0.06 g, then a 3.1 g impact. The free-fall test does not look at the sensitivity level, so changing levels does not change the conclusion here.", comment: "")
    static let drillWillTrigger = NSLocalizedString("Would trigger a lock", comment: "")
    static let drillWillNotTrigger = NSLocalizedString("Would not trigger a lock", comment: "")
    static let drillGaugeG = NSLocalizedString("Peak G against the threshold", comment: "")
    static let drillGaugeOmega = NSLocalizedString("Peak ω against the threshold", comment: "")
    static let drillOmegaNoThresholdHeadline = NSLocalizedString("Peak ω (rad/s) · this test does not look at it", comment: "")
    static let drillSampleCountFormat = NSLocalizedString("Sample %@ frames · 20Hz", comment: "")
    static let drillVerdictSnatchFormat = NSLocalizedString("Snatch-and-drop hit: G %1$@, ω %2$@ rad/s", comment: "")
    static let drillVerdictFreeFallFormat = NSLocalizedString("Free-fall hit: impact peak G %1$@, weightlessness lasted %2$@ ms", comment: "")

    static let drillDuressGroup = NSLocalizedString("Duress code drill", comment: "")
    static let drillDuressFieldLabel = NSLocalizedString("Type a code to verify", comment: "")
    static let drillDuressFieldPrompt = NSLocalizedString("6 digits", comment: "")
    static let drillDuressRun = NSLocalizedString("Verify only, do not commit", comment: "")
    static let drillDuressFootnote = NSLocalizedString("The drill will not really wipe: this row only asks which code the typed one matches, using the verification-only method; the path that leads to a wipe is not called here.", comment: "")
    static let drillDuressNoEraseToast = NSLocalizedString("Drill finished, no wipe was triggered", comment: "")
    static let drillOutcomeNormal = NSLocalizedString("It matched the normal code. In a real situation that only opens the door and touches no data.", comment: "")
    static let drillOutcomeDuress = NSLocalizedString("It matched the duress code. In a real situation it would erase the identities on this device. The drill performed no wipe at all.", comment: "")
    static let drillOutcomeWrong = NSLocalizedString("It matched neither code. In a real situation it would just ask for the input once more.", comment: "")
    static let drillOutcomeNotConfigured = NSLocalizedString("This device has no normal code set yet, so there is no record to compare against.", comment: "")
    static let drillOutcomeLockedOut = NSLocalizedString("The drill uses a read-only comparison and does not consult the cool-down table, so this sentence can never appear on this page: it exists only because that result has one more possibility and the compiler requires the cases to be exhaustive. The row on the lock screen is where the cool-down actually lands.", comment: "")

    // footer risk notes
    static let groupRisk = NSLocalizedString("What this cannot protect you from", comment: "")
    static let riskIrreversible = NSLocalizedString("Once data is wiped by the duress code it cannot be recovered: no backup prompt, no undo, no recovery channel. The drill page will not let you try it once, and cannot.", comment: "")
    static let riskForensics = NSLocalizedString("Self-destruct relies on this app closing the database and deleting the files itself. Whatever the operating system once rendered of these pages into caches is not guaranteed to be beyond forensic recovery; this module pushes recoverable content down to very little, but it does not promise zero.", comment: "")
    static let riskFalsePositive = NSLocalizedString("The sensor tests will definitely report false positives: going over a speed bump, throwing the phone into a bag or knocking it on a table corner can all hit. Precisely because they do, their consequence is always limited to one more authentication and can never lead to a wipe.", comment: "")
}
