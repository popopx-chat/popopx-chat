//
//  PopopxAntiTheftMotionGuard.swift
//  POPOPX (iOS)
//
//  [Physical anti-snatch - module 1] snatch/drop criteria, auto lock screen after a timeout with no interaction, instant lock on going to background,
//  and the single lock state machine `PopopxAppLockState` shared by the whole AntiTheftDuress module.
//
//  This file carries the 'lock state' and not only the sensors because the criteria come from three places (sensor, behaviour, timeout),
//  the UI is a fourth place (the overlay) and the settings page a fifth. If every source held its own copy of 'is locked', there would inevitably be
//  half-locked states — 'unlocked in one place, still locked in another'; that is the kind of lock that can be bypassed, and the one mistake this module may not make.
//  So the lock state exists exactly once, in the file that is depended on first, and every other section only reads it and writes it only through `lock(reason:)`.
//
//  ### Sensors only lock, never wipe
//  The **only** consequence of the three criteria snatch / drop / behaviour is raising the lock screen. They trigger no wipe, and they do not lead to
//  `PopopxDuressAuthManager`'s self-destruct. The reason is pure engineering, not caution: a 20Hz acceleration criterion misfires in a car,
//  while running, when the phone knocks against a table corner, or when it is thrown into a bag, and the cost of a false positive must be tolerable —
//  typing the passphrase once more is tolerable, lost data is not. In the whole module only one road leads to a wipe, 'the duress passphrase was entered correctly',
//  which requires the attacker to press keys deliberately, so it cannot misfire; the settings page's 'one-tap drill' runs `PopopxMotionCriteria`'s
//  pure functions plus synthetic samples, which by type cannot return any side effect.
//
//  ### Division of labour with the upstream POPOPX Lock (not a duplicate implementation)
//  `ContentView` already has a complete LA gate: `DEFAULT_PERFORM_LA` + `contentViewAccessAuthenticated`
//  + the background `DEFAULT_LA_LOCK_DELAY` (30 seconds by default) + `SetAppPasscodeView` (see ContentView.swift:80-86,
//  :123-156). That gate governs 'who may enter the app'. This module governs 'the phone is physically no longer in my hand',
//  a different source of criteria and a different moment, and it **only adds one layer, it changes none of theirs**: we neither call nor modify
//  `authorize()` — it grants access directly on `.unavailable` (LocalAuthenticationUtils.swift:24),
//  and that semantics was written for 'device-unlock convenience'; the security overlay is not allowed to inherit it.
//
//  ### Sample rate, coordinate system and power use
//  20Hz (one frame every 50ms). $G$ uses the **raw accelerometer reading** (including gravity), because the signature of free fall is exactly
//  'the gravity-inclusive vector magnitude approaches 0'; with `deviceMotion.userAcceleration` (gravity already subtracted) the weightless stretch would read
//  as about 1g and the criterion would be turned completely upside down. That is the only reason for choosing `accelerometer` over `deviceMotion`.
//  The analysis runs on the `.main` queue: 20Hz x a few floating-point operations is not enough to stall a frame, and `PopopxAppLockState` is
//  `@MainActor`, so moving to a dedicated OperationQueue would still have to hop back to the main thread and only adds a race window.
//  Sampling stops immediately once locked (module 4's power-saving requirement), and it stops on going to background too — this module has zero background sampling and zero background battery.
//
//  ### Why the criterion constants live in `PopopxMotionCriteria` instead of this class's `static let`
//  A `static let` of a `@MainActor` class is main-actor isolated, so non-isolated pure functions (the drill entry,
//  future unit tests) cannot reference it, and the whole class would have to be dragged onto the main thread to be testable. Putting the thresholds and the decision together in one enum
//  makes them naturally nonisolated, so a decision function can take an array of samples and assert the conclusion directly.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. Red lines forbid a script from modifying project.pbxproj.
//

import SwiftUI
import UIKit
import CoreMotion

// MARK: - This module's UserDefaults keys

/// Key naming follows the repository's current practice (bare camelCase, no prefix, see Shared/Views/UserSettings/SettingsView.swift:29-72
/// the `DEFAULT_*` block there — that is the upstream file of the same name, not this module's `PopopxAntiTheftSettingsView.swift`),
/// but the whole anti-theft key set is declared in **this file**: if one module's keys scatter into host files, renaming misses half of them.
let DEFAULT_ANTI_THEFT_ENABLED = "antiTheftEnabled"
let DEFAULT_ANTI_THEFT_SENSITIVITY = "antiTheftSensitivity"
let DEFAULT_ANTI_THEFT_INACTIVITY_SECONDS = "antiTheftInactivitySeconds"
let DEFAULT_ANTI_THEFT_INSTANT_BG_LOCK = "antiTheftInstantBackgroundLock"
/// Used by module 2 (behaviour criteria).
let DEFAULT_ANTI_THEFT_BEHAVIOR_ENABLED = "antiTheftBehaviorEnabled"
let DEFAULT_ANTI_THEFT_ANGLE_LIMIT = "antiTheftAngleLimitDegrees"
/// Used by module 3 (dual passcodes).
let DEFAULT_ANTI_THEFT_DURESS_ENABLED = "antiTheftDuressEnabled"
let DEFAULT_ANTI_THEFT_BIOMETRICS_ENABLED = "antiTheftBiometricsEnabled"
/// Whether the 10th consecutive error wipes the data outright. Off by default (when the key is absent it reads as `false`),
/// and the owner must turn it on explicitly in the settings page — this one switch changes the cost of 'ten wrong guesses' from 'locked for an hour' to 'the identity is gone'.
/// It stores **only** this bool and no credentials, but it is a digest that 'this device had extreme self-destruct enabled',
/// so, like the other switches, it goes into the sweep table below.
let DEFAULT_ANTI_THEFT_TEN_STRIKE_WIPE = "antiTheftTenStrikeWipe"
/// The rebuild mode after self-destruct (`.emptyProfile` / `.simulatedDecoy`).
let DEFAULT_ANTI_THEFT_RETENTION_STRATEGY = "antiTheftRetentionStrategy"
/// Used by module 4 (the smokescreen).
let DEFAULT_ANTI_THEFT_DECOY_ENABLED = "antiTheftDecoyEnabled"

/// **All** UserDefaults keys of this module, none left out. The self-destruct path uses this table to sweep traces,
/// so a new key must be added here too — writing them scattered means missing a wipe, and 'traces left un-wiped' is exactly what this module exists to destroy.
let POPOPX_ANTI_THEFT_DEFAULT_KEYS: [String] = [
    DEFAULT_ANTI_THEFT_ENABLED,
    DEFAULT_ANTI_THEFT_SENSITIVITY,
    DEFAULT_ANTI_THEFT_INACTIVITY_SECONDS,
    DEFAULT_ANTI_THEFT_INSTANT_BG_LOCK,
    DEFAULT_ANTI_THEFT_BEHAVIOR_ENABLED,
    DEFAULT_ANTI_THEFT_ANGLE_LIMIT,
    DEFAULT_ANTI_THEFT_DURESS_ENABLED,
    DEFAULT_ANTI_THEFT_BIOMETRICS_ENABLED,
    DEFAULT_ANTI_THEFT_TEN_STRIKE_WIPE,
    DEFAULT_ANTI_THEFT_RETENTION_STRATEGY,
    DEFAULT_ANTI_THEFT_DECOY_ENABLED,
]

// MARK: - Lock reason

/// Who raised the lock. The line on the lock screen, VoiceOver, and 'whether to prompt once more after unlocking' all read it,
/// so it is a closed set: adding a source means adding a case, and the compiler finds every missing branch for me.
enum PopopxLockReason: String, Hashable, Sendable, CaseIterable {
    /// Snatch pull-away: a sudden rise in combined acceleration plus a violent flip.
    case snatch
    /// Impact after free fall.
    case freeFall
    /// Behaviour signature of someone who is not the owner (module 2).
    case behavior
    /// Timeout without touching the screen.
    case inactivity
    /// Having gone to the background (`instantLockOnBackground`).
    case background
    /// Manual by the user, or module 2's forced re-authentication.
    case manual

    var userText: String {
        switch self {
        case .snatch: return NSLocalizedString("Snatching motion detected, locked", comment: "")
        case .freeFall: return NSLocalizedString("Fall detected, locked", comment: "")
        case .behavior: return NSLocalizedString("The way it is being handled does not match you, locked", comment: "")
        case .inactivity: return NSLocalizedString("No touch for a long time, locked", comment: "")
        case .background: return NSLocalizedString("The app went to the background, locked", comment: "")
        case .manual: return NSLocalizedString("Locked manually", comment: "")
        }
    }

    var symbolName: String {
        switch self {
        case .snatch: return "arrow.up.right.bold"
        case .freeFall: return "arrow.down.to.line.compact"
        case .behavior: return "hand.draw"
        case .inactivity: return "clock"
        case .background: return "moon.zzz"
        case .manual: return "lock"
        }
    }
}

// MARK: - Lock state machine (the only one in the whole module)

/// The lock state, plus the 'duress flow in progress' slot.
///
/// Two questions must be asked separately here, and getting either one wrong is an accident:
/// 1. **Is the overlay on screen** — as long as `isLocked` it is, including the 1.2 seconds of silent self-destruct.
///    That is `coversContent`. These two were once merged into a single `shielded = isLocked && !duress`,
///    so the instant 'wiping starts' the overlay vanished and the content was exposed straight to whoever stood next to it — exactly the thing that had to be prevented.
/// 2. **What the overlay displays** — normally anti-theft copy plus the keyboard; while self-destruct is running only breathing is allowed,
///    no change of copy, no error, no 'destroying' may appear. That is `showsLockUI`.
///
/// So: covering content uses `coversContent`, switching what the UI shows uses `showsLockUI`, and nobody may assemble the condition themselves.
@MainActor
@Observable
final class PopopxAppLockState {
    static let shared = PopopxAppLockState()

    private(set) var isLocked = false
    private(set) var reason: PopopxLockReason?
    private(set) var lockedAt: Date?

    /// Duress self-destruct in progress: the UI keeps breathing as usual, and no abnormal feedback may appear.
    private(set) var duressSilentFlow = false

    /// Whether the content is covered (and whether screenshots / screen recording must be blocked). True for the whole locked period.
    /// Its definition **must not contain `duressSilentFlow`**; see the type's comment for the reason.
    var coversContent: Bool { isLocked }

    /// Whether the overlay shows 'why it locked + the keyboard'. False during the silent self-destruct, when only the breathing animation is left.
    var showsLockUI: Bool { isLocked && !duressSilentFlow }

    /// The moment of the last interaction. A `Date` rather than accumulated seconds, because timers are throttled by the system while the screen is off,
    /// and accumulation underestimates the real idle duration.
    private(set) var lastInteractionAt = Date()

    private init() {}

    /// Raise the lock. Idempotent when already locked: the sensor delivers several hit samples within 50ms,
    /// and changing `reason` every time would make the lock-screen copy jump between two wordings.
    func lock(reason: PopopxLockReason) {
        guard !isLocked else { return }
        isLocked = true
        self.reason = reason
        lockedAt = Date()
        // The state machine tells the sensor to stop sampling itself, instead of hoping some host view remembers to call it:
        // module 1 requires 'stop sampling immediately after locking', and forgetting this step means running 20Hz behind the lock screen.
        PopopxAntiTheftMotionGuard.shared.lockedDidChange()
    }

    /// Unlock. Only the authentication module (through the overlay) may call it.
    func unlock() {
        isLocked = false
        reason = nil
        lockedAt = nil
        duressSilentFlow = false
        noteInteraction()
        PopopxAntiTheftMotionGuard.shared.lockedDidChange()
    }

    /// One real touch. The touch watcher and the keyboard both call it.
    func noteInteraction() {
        lastInteractionAt = Date()
    }

    /// Enter the silent self-destruct flow. Returns false when already in the flow, and the caller must give up this attempt:
    /// two concurrent wipes would disorder the 'stop → close → delete → init → start' order,
    /// and that chain is not reentrant.
    @discardableResult
    func beginDuressFlow() -> Bool {
        guard !duressSilentFlow else { return false }
        duressSilentFlow = true
        return true
    }

    func endDuressFlow() {
        duressSilentFlow = false
    }

    var idleSeconds: TimeInterval {
        Date().timeIntervalSince(lastInteractionAt)
    }
}

// MARK: - Levels

/// Criterion sensitivity. `wireValue` is the string stored in UserDefaults, exactly the same as `rawValue` but with a different duty:
/// `rawValue` belongs to the local archive, `wireValue` to this configuration's outward wording, so each is written out literally instead of using `rawValue`.
enum PopopxMotionSensitivity: String, CaseIterable, Hashable, Sendable {
    case low
    case medium
    case high

    var wireValue: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    static func fromStored(_ raw: String?) -> PopopxMotionSensitivity {
        allCases.first { $0.wireValue == raw } ?? .medium
    }

    /// Segmented control labels. `PopopxSegmentedControl` allows only one line (PopopxControls.swift:589's
    /// `.lineLimit(1)`), so a longer Chinese label is truncated with an ellipsis on small screens.
    var label: String {
        switch self {
        case .low: return NSLocalizedString("Less sensitive", comment: "")
        case .medium: return NSLocalizedString("Standard", comment: "")
        case .high: return NSLocalizedString("More sensitive", comment: "")
        }
    }

    /// Pull-away peak threshold $G$: sluggish 3.8, standard 3.0, sensitive 2.5.
    var spikeG: Double {
        switch self {
        case .low: return 3.8
        case .medium: return 3.0
        case .high: return 2.5
        }
    }

    /// Flip angular-velocity threshold $\omega$, rad/s. All three levels share one value: a snatch twists the wrist, an arm swing while walking does not,
    /// and the discrimination this quantity gives is already enough; scaling it along with sensitivity would only inflate the false-positive rate too.
    var spinOmega: Double {
        6.5
    }
}

/// Levels of the no-interaction auto lock screen. `never` has 0 seconds, which is also 0 when stored in UserDefaults,
/// so 'never' and 'key not readable' must be told apart by `object(forKey:) != nil` — see the getter below.
enum PopopxInactivityTimeout: Int, CaseIterable, Hashable, Sendable {
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case never = 0

    var label: String {
        switch self {
        case .oneMinute: return NSLocalizedString("1 minute", comment: "")
        case .threeMinutes: return NSLocalizedString("3 minutes", comment: "")
        case .fiveMinutes: return NSLocalizedString("5 minutes", comment: "")
        case .fifteenMinutes: return NSLocalizedString("15 minutes", comment: "")
        case .never: return NSLocalizedString("Never", comment: "")
        }
    }

    var seconds: Int {
        rawValue
    }

    /// 3 minutes by default. `never` is not the default: this switch means 'put the phone down for a while and it closes itself',
    /// and defaulting it off is the same as the feature not existing.
    static let defaultValue: PopopxInactivityTimeout = .threeMinutes

    static func fromStored(seconds: Int?) -> PopopxInactivityTimeout {
        guard let seconds else { return defaultValue }
        return allCases.first { $0.rawValue == seconds } ?? defaultValue
    }
}

// MARK: - Samples and conclusions

/// One frame of observations. The timestamp is a `Date`: real samples and drill samples can therefore enter the same decision function.
struct PopopxMotionSample: Hashable, Sendable {
    let at: Date
    /// Magnitude of the three-axis combined acceleration, in g, **including gravity**.
    let g: Double
    /// Magnitude of the three-axis angular velocity, in rad/s.
    let omega: Double
}

/// The conclusion for a stretch of samples.
enum PopopxMotionVerdict: Hashable, Sendable {
    case none
    case snatch(g: Double, omega: Double)
    case freeFall(peakG: Double, weightlessMs: Double)

    var lockReason: PopopxLockReason? {
        switch self {
        case .none: return nil
        case .snatch: return .snatch
        case .freeFall: return .freeFall
        }
    }

    var isHit: Bool {
        if case .none = self { return false }
        return true
    }
}

// MARK: - The criteria themselves (nonisolated, side-effect free: the real stream and the drill share the same code)

enum PopopxMotionCriteria {
    /// Sample rate. 20Hz = one frame per 50ms, enough to catch a 120ms weightless stretch (at least 2 frames) without burning battery at 100Hz.
    static let sampleRateHz: Double = 20

    /// Weightlessness threshold. At rest the vector magnitude is ≈1.0g, in free fall ≈0g; 0.25g leaves room for sensor zero-bias and slight pose jitter
    /// while not reading 'set down gently' as weightlessness.
    static let weightlessG: Double = 0.25

    /// How long weightlessness must continue to count. Shorter than three frames (first and last included) never counts.
    static let weightlessMinimum: TimeInterval = 0.120

    /// After the weightless stretch ends, within how long the impact must appear to count as the same fall.
    static let impactWindow: TimeInterval = 0.600

    /// Impact peak threshold.
    static let impactG: Double = 2.2

    /// A pull-away needs a 'spike': between two adjacent frames the vector magnitude must rise by at least this much. Comparing absolute values alone
    /// would already reach 2.5g when lifting the phone off a table.
    static let spikeRiseG: Double = 1.2

    /// The 'calm' precondition before a decision: over this span counting back from the hit frame the average vector magnitude must land in 0.85–1.20g,
    /// that is, the phone was previously in roughly a normal hold. A car over a speed bump or an arm swinging while running already averages far from 1g,
    /// and the criteria filter them out at this step.
    static let calmLookback: TimeInterval = 0.5
    static let calmLowerG: Double = 0.85
    static let calmUpperG: Double = 1.20

    /// Analysis window. 2 seconds covers 120ms of weightlessness + a 600ms impact window + the 0.5s calm look-back a pull-away needs.
    static let analysisWindow: TimeInterval = 2.0
    static let maxWindowSamples: Int = 40

    /// Judge a stretch of samples. A fall takes priority over a pull-away: while the phone is landing it is handled as a landing first,
    /// because that landing impact also satisfies the pull-away 'spike', so the two criteria are not mutually exclusive within one event.
    static func evaluate(
        samples: [PopopxMotionSample],
        sensitivity: PopopxMotionSensitivity
    ) -> PopopxMotionVerdict {
        guard samples.count >= 3 else { return .none }
        if let fall = freeFallVerdict(samples: samples) { return fall }
        return snatchVerdict(samples: samples, sensitivity: sensitivity)
    }

    private static func snatchVerdict(
        samples: [PopopxMotionSample],
        sensitivity: PopopxMotionSensitivity
    ) -> PopopxMotionVerdict {
        var index = samples.count - 1
        while index > 0 {
            let hit = samples[index]
            let previous = samples[index - 1]
            if hit.g > sensitivity.spikeG,
               hit.g - previous.g >= spikeRiseG,
               hit.omega > sensitivity.spinOmega,
               calmBefore(samples: samples, upTo: index) {
                return .snatch(g: hit.g, omega: hit.omega)
            }
            index -= 1
        }
        return .none
    }

    private static func freeFallVerdict(samples: [PopopxMotionSample]) -> PopopxMotionVerdict? {
        var index = 0
        while index < samples.count {
            guard samples[index].g < weightlessG else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < samples.count, samples[end + 1].g < weightlessG {
                end += 1
            }
            let weightless = samples[end].at.timeIntervalSince(samples[index].at)
            guard weightless >= weightlessMinimum else {
                index = end + 1
                continue
            }
            let limit = samples[end].at.addingTimeInterval(impactWindow)
            var cursor = end + 1
            while cursor < samples.count, samples[cursor].at <= limit {
                if samples[cursor].g > impactG {
                    return .freeFall(peakG: samples[cursor].g, weightlessMs: weightless * 1_000)
                }
                cursor += 1
            }
            index = end + 1
        }
        return nil
    }

    /// Whether the frames before the hit frame sit inside the normal-hold range.
    private static func calmBefore(samples: [PopopxMotionSample], upTo index: Int) -> Bool {
        guard index > 0 else { return false }
        let from = samples[index].at.addingTimeInterval(-calmLookback)
        var total = 0.0
        var count = 0
        var cursor = index - 1
        while cursor >= 0, samples[cursor].at >= from {
            total += samples[cursor].g
            count += 1
            cursor -= 1
        }
        guard count >= 2 else { return false }
        let mean = total / Double(count)
        return mean >= calmLowerG && mean <= calmUpperG
    }

    /// For the drill: a synthetic pull-away sample stretch.
    static func syntheticSnatch(at start: Date = Date()) -> [PopopxMotionSample] {
        var samples: [PopopxMotionSample] = []
        for step in 0..<10 {
            samples.append(PopopxMotionSample(
                at: start.addingTimeInterval(Double(step) * 0.05),
                g: 1.0,
                omega: 0.4
            ))
        }
        samples.append(PopopxMotionSample(
            at: start.addingTimeInterval(0.50),
            g: 3.6,
            omega: 8.2
        ))
        return samples
    }

    /// For the drill: a synthetic fall sample, 200ms of weightlessness first, then a 3.1g impact.
    static func syntheticFreeFall(at start: Date = Date()) -> [PopopxMotionSample] {
        var samples: [PopopxMotionSample] = []
        for step in 0..<4 {
            samples.append(PopopxMotionSample(
                at: start.addingTimeInterval(Double(step) * 0.05),
                g: 0.98,
                omega: 0.2
            ))
        }
        for step in 0..<4 {
            samples.append(PopopxMotionSample(
                at: start.addingTimeInterval(0.20 + Double(step) * 0.05),
                g: 0.06,
                omega: 1.1
            ))
        }
        samples.append(PopopxMotionSample(
            at: start.addingTimeInterval(0.42),
            g: 3.1,
            omega: 5.4
        ))
        return samples
    }
}

// MARK: - Sensor watchdog

@MainActor
@Observable
final class PopopxAntiTheftMotionGuard {
    static let shared = PopopxAntiTheftMotionGuard()

    /// Cooldown after a hit. The lock is already raised and the sensor already stopped sampling; the real purpose of this window is to keep the same event from
    /// raising the lock over and over in an 'unlock → hit again immediately' loop.
    static let triggerCooldown: TimeInterval = 5

    // MARK: Public state

    private(set) var isRunning = false
    private(set) var lastVerdict: PopopxMotionVerdict?
    /// Diagnostic reading: the peak inside the window. The settings page uses it to explain 'why that last one did not trigger'.
    private(set) var peakG: Double = 0
    private(set) var peakOmega: Double = 0
    /// Whether this device's sensor is available. On the simulator `isAccelerometerAvailable == false`,
    /// so the settings page shows 'unavailable on this device' instead of pretending to run.
    private(set) var motionAvailable = false

    var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            UserDefaults.standard.set(enabled, forKey: DEFAULT_ANTI_THEFT_ENABLED)
            sync()
        }
    }

    var sensitivity: PopopxMotionSensitivity {
        didSet {
            guard oldValue != sensitivity else { return }
            UserDefaults.standard.set(sensitivity.wireValue, forKey: DEFAULT_ANTI_THEFT_SENSITIVITY)
        }
    }

    var inactivityTimeout: PopopxInactivityTimeout {
        didSet {
            guard oldValue != inactivityTimeout else { return }
            UserDefaults.standard.set(inactivityTimeout.seconds, forKey: DEFAULT_ANTI_THEFT_INACTIVITY_SECONDS)
        }
    }

    var instantLockOnBackground: Bool {
        didSet {
            guard oldValue != instantLockOnBackground else { return }
            UserDefaults.standard.set(instantLockOnBackground, forKey: DEFAULT_ANTI_THEFT_INSTANT_BG_LOCK)
        }
    }

    // MARK: Internal

    private let manager = CMMotionManager()
    private var window: [PopopxMotionSample] = []
    /// The two streams call back separately, pairing the most recent angular velocity with this frame's acceleration: at most 50ms of skew,
    /// negligible against a 6.5 rad/s threshold, and in exchange there is no resampling to maintain by hand.
    private var latestOmega: Double = 0
    private var lastTriggerAt: Date?
    private var inactivityTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Background events only raise the lock after coming back to the foreground: once in the background the user can no longer see the overlay,
    /// and changing state in the background only makes the first foreground frame flash the content.
    private var lockPendingOnActive = false

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: DEFAULT_ANTI_THEFT_ENABLED)
        sensitivity = PopopxMotionSensitivity.fromStored(defaults.string(forKey: DEFAULT_ANTI_THEFT_SENSITIVITY))
        inactivityTimeout = PopopxInactivityTimeout.fromStored(
            seconds: defaults.object(forKey: DEFAULT_ANTI_THEFT_INACTIVITY_SECONDS) == nil
                ? nil
                : defaults.integer(forKey: DEFAULT_ANTI_THEFT_INACTIVITY_SECONDS)
        )
        instantLockOnBackground = defaults.object(forKey: DEFAULT_ANTI_THEFT_INSTANT_BG_LOCK) == nil
            ? true
            : defaults.bool(forKey: DEFAULT_ANTI_THEFT_INSTANT_BG_LOCK)
        motionAvailable = manager.isAccelerometerAvailable && manager.isGyroAvailable
    }

    // MARK: Lifecycle

    /// Starts or stops according to the setting. Idempotent.
    func sync() {
        if enabled { start() } else { stop() }
    }

    func start() {
        guard enabled, !isRunning else { return }
        guard motionAvailable else { return }
        installObserversIfNeeded()
        startSampling()
        startInactivityTimer()
        isRunning = true
    }

    /// Stop sampling + stop the timer + remove notifications. The lock state itself is not changed here: the timer stops because measuring is no longer needed, the lock should keep locking.
    func stop() {
        guard isRunning else { return }
        stopSampling()
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        removeObservers()
        window.removeAll()
        latestOmega = 0
        isRunning = false
    }

    /// A lock-state change must tell the sensor: module 1 requires 'stop sampling immediately after locking'.
    func lockedDidChange() {
        guard enabled, isRunning else { return }
        if PopopxAppLockState.shared.isLocked {
            stopSampling()
        } else {
            startSampling()
        }
    }

    private func startSampling() {
        let interval = 1.0 / PopopxMotionCriteria.sampleRateHz
        manager.accelerometerUpdateInterval = interval
        manager.gyroUpdateInterval = interval
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let acceleration = data?.acceleration else { return }
            // The callback is already on the `.main` queue; `assumeIsolated` only tells the type system that fact,
            // without enqueuing anything extra, so the 20Hz decisions are not pushed back frame by frame.
            MainActor.assumeIsolated {
                self.receive(acceleration)
            }
        }
        manager.startGyroUpdates(to: .main) { [weak self] data, _ in
            guard let self, let rate = data?.rotationRate else { return }
            let omega = sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z)
            MainActor.assumeIsolated {
                self.latestOmega = omega
            }
        }
    }

    private func stopSampling() {
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
    }

    // MARK: Criterion entry

    private func receive(_ acceleration: CMAcceleration) {
        let g = sqrt(
            acceleration.x * acceleration.x
                + acceleration.y * acceleration.y
                + acceleration.z * acceleration.z
        )
        // `CMMotionManager`'s timestamp counts seconds since boot and shares no origin with `Date`; here the callback
        // moment is used as the sample moment. The decision only looks at the time difference between adjacent samples, so the two clocks never have to be converted.
        let sample = PopopxMotionSample(at: Date(), g: g, omega: latestOmega)
        append(sample)
        if g > peakG { peakG = g }
        if latestOmega > peakOmega { peakOmega = latestOmega }
        let state = PopopxAppLockState.shared
        guard !state.isLocked else { return }
        if let at = lastTriggerAt, Date().timeIntervalSince(at) < Self.triggerCooldown { return }

        let verdict = PopopxMotionCriteria.evaluate(samples: window, sensitivity: sensitivity)
        lastVerdict = verdict
        guard verdict.isHit else { return }
        lastTriggerAt = Date()
        trigger(verdict, state: state)
    }

    private func append(_ sample: PopopxMotionSample) {
        window.append(sample)
        let cutoff = sample.at.addingTimeInterval(-PopopxMotionCriteria.analysisWindow)
        while let first = window.first,
              first.at < cutoff || window.count > PopopxMotionCriteria.maxWindowSamples {
            window.removeFirst()
        }
    }

    private func trigger(_ verdict: PopopxMotionVerdict, state: PopopxAppLockState) {
        guard let reason = verdict.lockReason else { return }
        state.lock(reason: reason)
        PopopxHaptics.notice(.warning)
        logger.debug("anti-theft: locked by \(reason.rawValue)")
        stopSampling()
    }

    // MARK: Timeout and background

    private func startInactivityTimer() {
        inactivityTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.checkInactivity()
            }
        }
        // `.common` mode: while the keyboard is up the main runloop is in eventTracking mode and does not fire ordinary timers,
        // and that is exactly the moment the lock is needed most.
        RunLoop.main.add(timer, forMode: .common)
        inactivityTimer = timer
    }

    private func checkInactivity() {
        guard enabled, inactivityTimeout != .never else { return }
        let state = PopopxAppLockState.shared
        guard !state.isLocked, !state.duressSilentFlow else { return }
        guard state.idleSeconds >= Double(inactivityTimeout.seconds) else { return }
        state.lock(reason: .inactivity)
        stopSampling()
        logger.debug("anti-theft: locked after \(Int(state.idleSeconds))s idle")
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let background = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleDidEnterBackground()
            }
        }
        let active = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleDidBecomeActive()
            }
        }
        observers = [background, active]
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
    }

    private func handleDidEnterBackground() {
        // Zero background battery: whether or not instant locking is on, going to the background stops sampling.
        stopSampling()
        guard enabled, instantLockOnBackground else { return }
        lockPendingOnActive = true
    }

    private func handleDidBecomeActive() {
        if lockPendingOnActive {
            lockPendingOnActive = false
            let state = PopopxAppLockState.shared
            if !state.isLocked, !state.duressSilentFlow {
                state.lock(reason: .background)
            }
        }
        guard enabled, isRunning, !PopopxAppLockState.shared.isLocked, motionAvailable else { return }
        startSampling()
    }
}

// MARK: - Global touch heartbeat

/// A gesture recogniser that only observes and never participates in recognition: it gives the timeout criterion the fact that 'the user is still touching the screen'.
///
/// Why not a SwiftUI-side solution: `.onTapGesture` eats taps, and `DragGesture(minimumDistance: 0)`
/// fights list scrolling just the same; swapping out `UIApplication.sendEvent` is a technique Apple explicitly forbids.
/// A recogniser that never enters the `.began` state still gets `touchesBegan` and never cancels anyone else's touches.
///
/// Mounted on `SceneDelegate.windowStatic` (AppDelegate.swift:135-145 already has this static handle),
/// so no new scene is needed and project.pbxproj does not have to be touched.
final class PopopxTouchBeat: UIGestureRecognizer {
    private static weak var installedIn: UIWindow?
    /// Edge-band criterion: the longest normalised component of a touch point's distance from the screen centre. 0.90 = a ring band of 5% on each of the four sides
    /// (390pt wide ≈ 20pt per side, 844pt high ≈ 42pt per side).
    /// Why not narrower: during a snatch the owner's hand is usually still gripping an edge, and too narrow is the same as switching off half of module 2's criteria;
    /// why not wider: the status bar and the Home indicator are places a normal person taps every day; once that half misfires,
    /// the two conditions 'skewed posture + edge touch' will complete themselves in everyday use.
    static let edgeBandThreshold: Double = 0.90
    #if DEBUG
    /// Acceptance 'node state' reading: every so many fingers fed in it logs one line of edge share; it only counts and takes no part in any criterion.
    /// In Release the whole block does not exist — it neither leaves log spam nor lets the word "telemetry" into the shipped binary
    /// (2c2b1d2dd already unified the outward wording to 'node state').
    private static let statusReadoutEvery = 25
    private static var statusReadoutTouches = 0
    private static var statusReadoutEdgeTouches = 0
    #endif

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // It only records the moment and never changes state: the state stays `.possible` and the system then decides it `.failed`,
        // and in between no view fails to receive touches because of this recogniser.
        PopopxAppLockState.shared.noteInteraction()
        // Handed off finger by finger to module 2 (the combined tilt + unusual-touch criterion). What it needs is `UITouch.majorRadius`
        // and 'was this one on the edge', and only this place can get both: module 2 does not know the view's size,
        // and should not go and read the window itself either. Its very first line is `guard enabled, isRunning`,
        // so when switched off this loop is only a few floating-point divisions.
        guard let view = self.view else { return }
        let size = view.bounds.size
        let edgeReady = size.width > 0 && size.height > 0
        for touch in touches {
            let radius = Double(touch.majorRadius)
            var edge = false
            if edgeReady {
                let point = touch.location(in: view)
                let nx = abs(Double(point.x) / Double(size.width) - 0.5) * 2
                let ny = abs(Double(point.y) / Double(size.height) - 0.5) * 2
                edge = max(nx, ny) >= Self.edgeBandThreshold
            }
            PopopxBehaviorGuard.shared.noteTouch(majorRadius: radius, edge: edge)
            #if DEBUG
            Self.statusReadoutTouches += 1
            if edge { Self.statusReadoutEdgeTouches += 1 }
            if Self.statusReadoutTouches >= Self.statusReadoutEvery {
                logger.debug(
                    "anti-theft node status readout: \(Self.statusReadoutEdgeTouches)/\(Self.statusReadoutTouches) touches in edge band"
                )
                Self.statusReadoutTouches = 0
                Self.statusReadoutEdgeTouches = 0
            }
            #endif
        }
    }

    /// Idempotent installation. If the window changes (split view, rebuild), install once more.
    @MainActor
    static func install(in window: UIWindow?) {
        guard let window else { return }
        if let existing = window.gestureRecognizers?.first(where: { $0 is PopopxTouchBeat }) {
            window.removeGestureRecognizer(existing)
        }
        let beat = PopopxTouchBeat(target: nil, action: nil)
        beat.cancelsTouchesInView = false
        beat.delaysTouchesBegan = false
        beat.delaysTouchesEnded = false
        window.addGestureRecognizer(beat)
        installedIn = window
    }
}
