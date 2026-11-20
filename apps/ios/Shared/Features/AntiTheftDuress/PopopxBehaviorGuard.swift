//
//  PopopxBehaviorGuard.swift
//  POPOPX (iOS)
//
//  [Not-the-owner operation · module 2] the owner's grip posture + the owner's touch feel = two memories;
//  when these two memories are broken at the same time, the phone is locked.
//
//  Two criteria, they **must both hold** before the lock is raised:
//  1. The grip tilt deviates **persistently** past the threshold relative to the EMA baseline (default 45°, adjustable on the settings page, stored
//     `DEFAULT_ANTI_THEFT_ANGLE_LIMIT`）；
//  2. In the same period high-frequency irregular touching appears (`UITouch.majorRadius` abnormally large versus the owner himself, or repeated hits on the screen edge).
//  The consequence is only one: `PopopxAppLockState.shared.lock(reason: .behavior)`
//  (`PopopxAntiTheftMotionGuard.swift:99-100` writes this case's purpose as "module 2", and this file is its only author).
//
//  ### The boundary of the misjudgement cost: it can only be "authenticate once more", never "lose data"
//  Module 1's header note (`PopopxAntiTheftMotionGuard.swift:13-19`) already fixes the division of labour: sensor criteria only lock, they never wipe.
//  This file keeps strictly to that boundary and **points at wiping nowhere in the call graph** — across the whole file there is a single read call to module 3,
//  （`PopopxDuressAuthManager.shared.requestBiometricUnlock`，`PopopxDuressAuthManager.swift:2070`），
//  and that road itself only leads to "unlock" (on success it has already called `unlock()`, see `PopopxDuressAuthManager.swift:2088-2092`).
//  Behaviour criteria are far easier to misreport than grab-and-drop/fall: a false grab-and-drop needs a 3g shock, whereas "wrong posture + slipping random taps"
//  come together every day on the metro. So this module prefers to write itself as "lock only" — one lock screen costs two seconds,
//  a wrong wipe costs a whole person's chat history; the two are not in the same order of magnitude at all and are not worth trading.
//
//  ### Why the EMA baseline is α=0.004 (≈8.7 second half-life), and not some other window
//  20Hz reuses module 1's same sampling-rate tier (`PopopxMotionCriteria.sampleRateHz`, :328). The half-life of a first-order low-pass
//  is `ln2 / α` frames: α=0.004 → 173 frames ≈ 8.7 seconds. This number is squeezed out from both ends:
//  - it must be **clearly slower than a single posture change** (a person going from sitting to lying takes 1–3 seconds, about 20–60 frames). With α=0.05
//    the half-life is under 0.7 seconds, lying down itself drags the baseline along, and the deviation never grows — the criterion eats itself.
//  - it must be **clearly faster than the owner's habit drift over a whole day** (an achy arm slowly changing posture, minutes). With α=0.0002
//    the half-life is three minutes, and the owner would be locked out twice within half an hour.
//  - what really keeps the two ends from clashing is the **freeze condition**: once the deviation exceeds `0.6 × threshold` the baseline stops learning
//    (`baselineFreezeFactor`). During the tens of seconds a thief holds the phone up rummaging through things, the baseline does not move at all,
//    so he can never be learned as the "new owner"; while the few degrees the owner slowly sinks by stay below the freeze line and are learned all the same.
//
//  ### Why 45° must be constrained by "lasting 6 seconds": with angle alone it will certainly mis-lock
//  Looking only at the instantaneous angle, watching a video in landscape, raising the phone upright to the ear, lying in bed pointing at the ceiling, all can produce
//  a deviation of >45° within 1–2 seconds, and these are the most ordinary usages — an angle threshold alone makes a feature that "cannot be used while lying down".
//  Add "above the threshold for ≥6 seconds continuously" and: one passing posture change is not long enough; snatching the phone and browsing it necessarily holds the new posture
//  for tens of seconds or more, which is certainly enough. Stack on the further rule "the touching must be abnormal at the same time" (AND, not OR),
//  and the only false-positive window left is "blindly typing steadily for over 6 seconds in a strange posture" — that was already a case worth asking about once.
//  Conversely, an angle that lasts long enough but normal touching only rises to `.watching` (`evaluate` spells that tier out explicitly), and stops nobody.
//
//  ### The 45-second "stable new posture" self-heal, and the price paid for it (stated plainly, not hidden)
//  Deviation is large but the posture itself is very steady, and there is no abnormal touch within these 2 seconds: after 45 continuous seconds the baseline moves to the current posture.
//  Without this rule, after finishing a video in landscape any single edge mistouch would immediately complete both criteria and lock the person out —
//  users switch that kind of feature off, and a switched-off feature has zero security. The cost must be admitted: someone willing to hold the phone steady on the table for 45 seconds
//  before acting can make the baseline follow his posture. But what he follows is only the **posture**; the gate of the touch criterion has not loosened in the least,
//  and it is that gate which really decides whether to stop a person; `authorizeSensitiveAction` also looks only at `suspicion`,
//  not at "whether someone moved the baseline".
//
//  ### Why `userAcceleration` is used instead of raw acceleration (exactly the opposite of module 1)
//  Module 1 measures weightlessness, so it must use raw readings **including gravity** (`PopopxAntiTheftMotionGuard.swift:30-32` explains the reason).
//  This module measures "shaking", and wants the part **with gravity subtracted**: with the phone lying flat and unmoving the raw resultant magnitude is ≈1g
//  (for the field semantics see `PopopxAntiTheftMotionGuard.swift:299`), so raw values would read "at rest" as "shaking all the time" and invert the criterion.
//  And precisely because the field meanings are opposite, `PopopxMotionSample` is **not reused** here: stuffing `userAcceleration` into a
//  `g` field whose documentation says "including gravity" means the next person to read the code understands it as standing still at 1g, which is a planted trap.
//  The posture angles themselves are computed from the `gravity` component (no centrifugal force, steadier than `attitude`, and unaffected by heading drift).
//
//  ### Why a separate `CMMotionManager` is started
//  Module 1's instance (:531) already occupies the accelerometer + gyro channels, and its start/stop follows "locked",
//  while this file's start/stop follows "foreground + locked", a different moment. Cramming the two into one instance would only interrupt each other,
//  and each would have to worry about the other's side-effect scope. Two instances at 20Hz each still sum to far below the system's power ceiling.
//
//  ### Why a 1Hz heartbeat reads the lock state instead of the state machine calling us
//  `PopopxAppLockState` is `@Observable`, and observing it across objects means hand-writing recursive `withObservationTracking`
//  (which is stuffing a whole SwiftUI mechanism into a sensor class, and the re-entry timing is uncontrolled). Module 1 takes another route:
//  `lock`/`unlock` explicitly call `PopopxAntiTheftMotionGuard.shared.lockedDidChange()`
//  (`PopopxAntiTheftMotionGuard.swift:175-177`, :187). This module also needs the "unlock edge" — that is the only moment to rebuild
//  the baseline — but hooking into those two methods would mean changing module 1, which is out of bounds. So this becomes 1Hz self-polling:
//  reading a Bool costs less than one haptic feedback, and the price is at most 1 second after unlocking before relearning begins, which is acceptable.
//
//  ### `.unavailable` is always treated as "do not release"
//  The upstream `authorize()` treats `.unavailable` directly as authentication success (`LocalAuthenticationUtils.swift:24`),
//  but those are semantics written for "device unlock convenience"; this module's presence check must not inherit them: when biometrics are unavailable, are turned off,
//  or have downgraded after two consecutive failures (`PopopxDuressAuthManager.swift:2073-2075`), always `completion(false)`
//  and raise one `.manual` lock (`PopopxAntiTheftMotionGuard.swift:105-106` explicitly assigns "module 2's forced re-authentication"
//  to this case), so the person goes through the overlay's keyboard — the downgrade direction can only be a stronger proof.
//  For the same reason `authenticate(reason:)` is not borrowed either: its `.passcode` branch hangs the request on
//  `ChatModel.shared.laRequest` (:47), which is the door for "who may enter the app", not the door for "is the one holding the phone right now the owner".
//
//  ### No previews
//  This file deliberately carries no `#Preview` / `PreviewProvider`: a newly added preview would be judged a failure by CI's snapshot comparison, that is a decision, not an omission.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.
//

import SwiftUI
import UIKit
import CoreMotion

// MARK: - Suspicion level

/// This module's single conclusion about "is the person holding the phone right now the owner". Three tiers rather than a 0–1 score:
/// the segmented control, the badge and the host's gate all want a wording that can be read at a glance, and a continuous score will in the end
/// be cut away by someone casually with something like `> 0.5`, with nobody responsible for where the cut sits.
///
/// `label` being as short as 2 Chinese characters is for `PopopxSegmentedControl` — that place only has `.lineLimit(1)`
/// (`PopopxControls.swift:589`), and long copy on a small screen gets cut into half a sentence by the ellipsis.
enum PopopxSuspicion: String, CaseIterable, Hashable, Sendable {
    case calm
    case watching
    case suspicious

    var label: String {
        switch self {
        case .calm: NSLocalizedString("Normal", comment: "")
        case .watching: NSLocalizedString("Watchful", comment: "")
        case .suspicious: NSLocalizedString("Suspicious", comment: "")
        }
    }

    var symbolName: String {
        switch self {
        case .calm: "checkmark.seal"
        case .watching: "eye"
        case .suspicious: "exclamationmark.shield"
        }
    }

    /// Used only inside this file to "take the more severe one". Not exposed: publishing a score ordering only invites
    /// writes like `rank >= 1` that bypass the enum.
    private var rank: Int {
        switch self {
        case .calm: 0
        case .watching: 1
        case .suspicious: 2
        }
    }

    fileprivate func escalated(with other: PopopxSuspicion) -> PopopxSuspicion {
        other.rank > rank ? other : self
    }
}

// MARK: - Posture reading

/// The two components of the grip posture, unit: degrees.
///
/// This module never interprets "what the absolute angle is in degrees", it only measures **how far it differs from its own baseline**: the sign differences of CoreMotion's components
/// across device models and across `CMAttitudeReferenceFrame` values therefore never infect the criteria.
struct PopopxAttitude: Hashable, Sendable {
    /// Around the x axis: pitching forward and back.
    var pitchDegrees: Double
    /// Around the y axis: leaning left and right.
    var rollDegrees: Double

    static let zero = PopopxAttitude(pitchDegrees: 0, rollDegrees: 0)

    init(pitchDegrees: Double, rollDegrees: Double) {
        self.pitchDegrees = pitchDegrees
        self.rollDegrees = rollDegrees
    }

    init(radiansPitch: Double, radiansRoll: Double) {
        self.init(
            pitchDegrees: radiansPitch * 180 / Double.pi,
            rollDegrees: radiansRoll * 180 / Double.pi
        )
    }

    /// The deviation from the baseline, in degrees. Each component is wrapped back into (-180°, 180°] and then the Euclidean length is taken:
    /// gripping is a two-dimensional quantity, 32° front-back + 32° left-right together make 45°, which fits human intuition better than "any single component over 45",
    /// and it is not led astray by high-frequency jitter of a single component.
    func deviationDegrees(from other: PopopxAttitude) -> Double {
        let pitch = Self.wrappedDegrees(pitchDegrees - other.pitchDegrees)
        let roll = Self.wrappedDegrees(rollDegrees - other.rollDegrees)
        return sqrt(pitch * pitch + roll * roll)
    }

    /// Fold the angle difference into (-180, 180]. Without this step, going from +179° to -179° computes as a "huge change" of 358°,
    /// while it actually rotated only 2°.
    static func wrappedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }
}

// MARK: - One frame of posture deviation (internal diagnostic sample)

/// Lives only in this file: gives "how many seconds it lasted" a window that can be counted backwards.
private struct PopopxAngleSample {
    let at: Date
    let deviationDegrees: Double
}

// MARK: - The criteria themselves (nonisolated, side-effect-free: the live stream, the drill and future unit tests share the same code)

/// Constants and decisions all live here, for the same reason as module 1 (`PopopxAntiTheftMotionGuard.swift:37-40`):
/// `static let` on a `@MainActor` type is main-actor isolated, so nonisolated pure functions and the drill entry point cannot reference them.
enum PopopxBehaviorCriteria {
    // MARK: Thresholds

    /// Default 45°. Written here rather than scattered through the settings page so that "the key could not be read" has one single answer.
    static let defaultAngleLimitDegrees: Double = 45
    /// The slider range. Below 15° the arm swing of normal walking can trigger it; above 75° nothing is reported even when the phone has been grabbed and is held reversed.
    static let minimumAngleLimitDegrees: Double = 15
    static let maximumAngleLimitDegrees: Double = 75

    /// How long the deviation must persist to count as "suspected". See the header note "Why 45° must be constrained by lasting 6 seconds".
    static let minimumSustainedSeconds: Double = 6

    /// Hysteresis: a fall-back that is still above this ratio does not count as a break; if one tremble of the hand reset the timer to zero,
    /// the 6-second persistence condition would never be assembled — which is exactly the one error this criterion must not commit (never triggering).
    static let releaseFactor: Double = 0.85

    /// The baseline freeze line: no more learning once the deviation exceeds `threshold × this ratio` (header note "EMA baseline", third item).
    static let baselineFreezeFactor: Double = 0.6

    /// The "approach" ratio for rising to `.watching`. Below the threshold evidence is still banked, and nothing is shown to the user.
    static let approachingFactor: Double = 0.6

    // MARK: Baseline learning

    /// The posture EMA coefficient. Half-life = ln2 / α frames ≈ 173 frames ≈ 8.7 seconds (derivation in the header note).
    static let baselineAlpha: Double = 0.004

    /// The touch-radius EMA coefficient. Touching is a Hz-scale human event, and 0.25 means "the feel from about four events ago still carries half the weight".
    static let radiusAlpha: Double = 0.25

    /// Self-heal: the deviation is large, the posture is steady, and there are zero abnormal touches within these 2 seconds; after this many continuous seconds the baseline moves to the current posture.
    static let relearnHoldSeconds: Double = 45
    /// The criterion for "posture steady": the deviation between adjacent frames no longer changes by more than this number.
    static let relearnDriftDegrees: Double = 2.0

    // MARK: Touch dynamics

    /// The counting window for irregular touching. 4 times in 2 seconds = 2Hz of erratic tapping; a human hand browsing chats normally does not do this.
    static let irregularTouchWindow: Double = 2
    static let minimumIrregularTouches: Int = 4
    /// Relative criterion: being this many times larger than the owner's own fingertip-pulp radius counts as abnormal (gloves and wet hands enlarge everything, hence the baseline).
    static let radiusAnomalyFactor: Double = 1.6
    /// Absolute fallback: palm heel, thigh and pocket-lining readings can reach above 15pt. A purely relative criterion, when "the baseline itself is polluted by large radii",
    /// stops working, so one hard line that does not look at the baseline is kept.
    static let minimumRadiusAnomalyPoints: Double = 9.5
    /// Above this value a thing is not treated as a finger and takes no part in learning (earphone cables, tissues, a lifting screen-protector edge).
    static let maximumPlausibleRadiusPoints: Double = 20

    // MARK: Shaking and hands-off (only escalate to "watching", never raise a lock on their own)

    /// A `userAcceleration` resultant magnitude above this value counts as one violent shake. Walking is about 0.2g, running about 0.6g,
    /// a jerking arm snatching a bag can reach 2g, so 1.6 sits on the "deliberate shaking" side.
    static let shakeG: Double = 1.6
    /// A resultant magnitude below this value counts as at rest (including the phone lying flat on a table).
    static let stillG: Double = 0.08
    /// After rest, exceeding this value again = it has been picked up again; the hands-off event is established at that moment.
    static let resumeG: Double = 0.35
    /// How long at rest with nobody touching the screen counts as a "brief hands-off".
    static let handOffStillSeconds: Double = 4
    /// How long after an event at least "watching" is kept. 25 seconds ≈ the reasonable length of grabbing the phone, unlocking the screen and starting to browse.
    static let armHoldSeconds: Double = 25

    // MARK: Buffer

    /// The window the sustained duration is counted backwards through. Much wider than `minimumSustainedSeconds`, but memory-capped (20Hz × 13 seconds).
    static let trendSeconds: Double = 13
    static let maxTrendSamples: Int = 260

    // MARK: Pure functions

    /// Fold any input into the legal range. NaN / negative numbers / a corrupted archive all become usable values through this one path,
    /// rather than letting a 0 threshold turn the feature into "locking all the time".
    static func sanitize(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return defaultAngleLimitDegrees }
        return min(max(degrees, minimumAngleLimitDegrees), maximumAngleLimitDegrees)
    }

    /// The three-axis combined magnitude. Written as `Double(...)` so as not to depend on the SDK declaring CoreMotion's fields as
    /// `Double` or `Float` — this generic initialiser exists in both cases.
    static func magnitude(_ acceleration: CMAcceleration) -> Double {
        let x = Double(acceleration.x)
        let y = Double(acceleration.y)
        let z = Double(acceleration.z)
        return sqrt(x * x + y * y + z * z)
    }

    /// Counts the seconds of "the tilt stayed continuously above the threshold" backwards from the newest frame.
    ///
    /// This is the **only** algorithm for the sustained duration: the live stream and the drill share it, so there is no "it triggers in the drill,
    /// but not on a real device". It only accepts uniform sampling (20Hz, see `PopopxMotionCriteria.sampleRateHz`),
    /// and the caller guarantees the buffer holds consecutive frames — the buffer is emptied when sampling stops.
    /// Also, counting backwards through the array instead of accumulating on our own means a "frame gap" only leaves the duration unchanged or lowers it, never lets it climb out of thin air.
    static func trailingSustainedSeconds(
        deviations: [Double],
        sampleInterval: Double,
        limit: Double
    ) -> Double {
        guard !deviations.isEmpty, sampleInterval > 0, limit > 0 else { return 0 }
        let release = limit * releaseFactor
        var cursor = deviations.count - 1
        var overLimitSamples = 0
        while cursor >= 0 {
            let value = deviations[cursor]
            if value > limit {
                overLimitSamples += 1
                cursor -= 1
                continue
            }
            // It lands in the hysteresis band: not counted as a break, and not added to the duration either.
            if value > release {
                cursor -= 1
                continue
            }
            // It really fell back (NaN takes this road too; a bad sample only makes the criterion more conservative).
            break
        }
        return Double(overLimitSamples) * sampleInterval
    }

    /// The decision itself. All three inputs are scalars, so a handful of numbers can assert the conclusion directly, with zero side effects.
    ///
    /// Monotonicity note (for explaining results on the drill page): raising `angleLimit` only makes the conclusion lighter,
    /// lengthening `sustainedSeconds` or `irregularTouches` only makes it heavier; there is no third road.
    static func evaluate(
        deviationDegrees: Double,
        sustainedSeconds: Double,
        irregularTouches: Int,
        angleLimit: Double
    ) -> PopopxSuspicion {
        guard deviationDegrees.isFinite, deviationDegrees > 0 else {
            // No angle evidence. Erratic touching alone yields at most "watching": a child playing a game or a pocket mistouch should not be treated as a snatcher.
            return irregularTouches >= minimumIrregularTouches ? .watching : .calm
        }
        let limit = sanitize(angleLimit)
        let noisy = irregularTouches >= minimumIrregularTouches
        let over = deviationDegrees > limit
        let sustained = over && sustainedSeconds >= minimumSustainedSeconds
        if sustained, noisy { return .suspicious }
        // Deviating long enough but touching normally: most likely the owner changed posture on their own, so only observe, do not stop anyone.
        if sustained { return .watching }
        if over || noisy || deviationDegrees >= limit * approachingFactor { return .watching }
        return .calm
    }
}

// MARK: - The behaviour monitor

@MainActor
@Observable
final class PopopxBehaviorGuard {
    static let shared = PopopxBehaviorGuard()

    /// The cooldown after a hit. The same value as `PopopxAntiTheftMotionGuard.swift:488` so that
    /// "no new lock within 5 seconds after unlocking" has one single reading across the modules. What really prevents "unlock — immediately locked again" is
    /// that baseline rebuild inside `updateSampling()`; this here is only the second safety.
    static let triggerCooldown: TimeInterval = 5

    // MARK: Outward state

    /// The master switch of the behaviour criteria. Off by default, same reading as module 1's `DEFAULT_ANTI_THEFT_ENABLED`
    /// (`PopopxAntiTheftMotionGuard.swift:546`: if the key cannot be read it is false) —
    /// unlike `instantLockOnBackground` (:553-555) which is on by default: that one carries no misjudgement cost, this one does.
    ///
    /// ⚠️ `didSet` writes the value back to UserDefaults, so the self-destruct sweep must "flip the switch first, then delete the keys"
    /// (see `PopopxAntiTheftSwitches.eraseAllTraces()` in `PopopxDuressAuthManager.swift`, which touches this property in exactly that order).
    var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            UserDefaults.standard.set(enabled, forKey: DEFAULT_ANTI_THEFT_BEHAVIOR_ENABLED)
            sync()
        }
    }

    /// The value of the settings-page slider. Out-of-range input is clamped back (when the clamp re-enters `didSet` the two values are equal, so it goes straight to disk).
    var angleLimitDegrees: Double {
        didSet {
            let clamped = PopopxBehaviorCriteria.sanitize(angleLimitDegrees)
            if clamped != angleLimitDegrees {
                angleLimitDegrees = clamped
                return
            }
            guard oldValue != clamped else { return }
            UserDefaults.standard.set(clamped, forKey: DEFAULT_ANTI_THEFT_ANGLE_LIMIT)
            // The threshold changed, and the earlier stretch of "persistence" was measured with the old ruler, so it does not count.
            resetDeviationRun()
        }
    }

    private(set) var suspicion: PopopxSuspicion = .calm
    private(set) var isBaselineCaptured = false
    /// Diagnostic readings: the current grip posture / the baseline / the difference between the two.
    private(set) var currentAngle = PopopxAttitude.zero
    private(set) var baselineAngle = PopopxAttitude.zero
    private(set) var deviationDegrees: Double = 0
    /// How long the tilt has been continuously above the threshold. 0 means "not above it".
    private(set) var sustainedDeviationSeconds: Double = 0
    /// The number of irregular touches inside the current 2-second window.
    private(set) var irregularTouchCount: Int = 0
    private(set) var isRunning = false
    /// On the simulator `isDeviceMotionAvailable == false`, and the settings page shows "not available on this device" accordingly, instead of pretending to run.
    private(set) var motionAvailable = false
    // Event records: module 2's two auxiliary criteria, escalation only, never a lock.
    private(set) var peakWobbleG: Double = 0
    private(set) var lastViolentShakeAt: Date?
    private(set) var lastHandOffAt: Date?
    private(set) var lastTriggerAt: Date?

    // MARK: Internal

    private let manager = CMMotionManager()
    private var trend: [PopopxAngleSample] = []
    private var irregularTouchMoments: [Date] = []
    /// The owner's own fingertip-pulp radius EMA. 0 = not learned yet.
    private var typicalRadius: Double = 0
    private var previousDeviation: Double = 0
    private var settledSeconds: Double = 0
    private var stillRunSeconds: Double = 0
    /// Already at rest long enough, waiting for the motion of "picked up again" to confirm the hands-off event.
    private var setDownPending = false
    private var lastTouchAt = Date()
    private var lastSampleAt: Date?
    private var samplingActive = false
    /// Whether the previous tick was locked. Used to catch the "locked to not locked" edge — the only moment to rebuild the baseline.
    private var wasLocked = false
    /// The foreground flag. `scenePhase` is a SwiftUI-side quantity, and this class is not a View,
    /// so two notifications, `UIApplication.didBecomeActive/didEnterBackground`, implement the same hard constraint
    /// (following the style of `PopopxAntiTheftMotionGuard.swift:691-742`).
    private var appIsActive = true
    private var heartbeat: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Only one authentication sheet at a time is allowed. Stacking two Face IDs is not "safer", it makes the host receive two contradictory callbacks.
    private var awaitingAuthorization = false

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: DEFAULT_ANTI_THEFT_BEHAVIOR_ENABLED) == nil
            ? false
            : defaults.bool(forKey: DEFAULT_ANTI_THEFT_BEHAVIOR_ENABLED)
        angleLimitDegrees = PopopxBehaviorCriteria.sanitize(
            defaults.object(forKey: DEFAULT_ANTI_THEFT_ANGLE_LIMIT) == nil
                ? PopopxBehaviorCriteria.defaultAngleLimitDegrees
                : defaults.double(forKey: DEFAULT_ANTI_THEFT_ANGLE_LIMIT)
        )
        motionAvailable = manager.isDeviceMotionAvailable
    }

    // MARK: Lifecycle

    /// Whether to start or stop is decided by the setting. Idempotent.
    func sync() {
        if enabled { start() } else { stop() }
    }

    func start() {
        guard enabled, !isRunning else { return }
        guard motionAvailable else { return }
        installObserversIfNeeded()
        startHeartbeat()
        isRunning = true
        appIsActive = true
        updateSampling()
    }

    /// Stop sampling + stop the timer + remove the notifications. The baseline is **not** cleared: if one trip to the background meant relearning the grip posture,
    /// that is the feature being out of action for tens of seconds after every app switch.
    ///
    /// The lock state itself is not changed here (module 1's :574-584 does the same): the timer stops because measuring is no longer needed, and the lock keeps locking.
    func stop() {
        // Once switched off, no "invisible" gate may be left behind: the host's sensitive-action check must return to the releasing state.
        suspicion = .calm
        awaitingAuthorization = false
        guard isRunning else { return }
        stopSampling()
        heartbeat?.invalidate()
        heartbeat = nil
        removeObservers()
        resetDeviationRun()
        irregularTouchMoments.removeAll()
        irregularTouchCount = 0
        peakWobbleG = 0
        lastViolentShakeAt = nil
        lastHandOffAt = nil
        setDownPending = false
        stillRunSeconds = 0
        lastSampleAt = nil
        wasLocked = false
        isRunning = false
    }

    /// Forget every memory about the owner (grip-posture baseline + fingertip feel) and relearn from the next frame.
    ///
    /// May only be called at moments when the person has just proved their presence: the settings-page button, the unlock edge,
    /// the successful run of `authorizeSensitiveAction`. It zeroes `suspicion`, so if someone
    /// got the phone without being stopped, entering settings and pressing this key would switch the criteria off — yet entering settings is itself the high-risk action guarded by these very
    /// criteria, so the chain is closed here.
    func resetBaseline() {
        isBaselineCaptured = false
        baselineAngle = .zero
        currentAngle = .zero
        typicalRadius = 0
        lastTouchAt = Date()
        resetDeviationRun()
        irregularTouchMoments.removeAll()
        irregularTouchCount = 0
        peakWobbleG = 0
        lastViolentShakeAt = nil
        lastHandOffAt = nil
        suspicion = .calm
    }

    // MARK: Touch-dynamics entry point

    /// The feed-in point for `UITouch.majorRadius`. Fed by `PopopxTouchBeat` (module 1 :754 — inside `touchesBegan`
    /// it both feeds `noteInteraction()` (:771) and computes the edge share finger by finger before handing it to this module (:788))
    /// or by the host, called from its own `touchesBegan`.
    ///
    /// This file only consumes the parameters and does not change that recogniser: its position is "observe only, never take part in recognition",
    /// and putting recognition logic into it would tie the life and death of the two modules together.
    ///
    /// - Parameters:
    ///   - majorRadius: the contact radius (points). Passing 0 means the host cannot obtain this value — then only the edge criterion is used,
    ///     never misjudging because of an "abnormal radius"; missing data can only loosen the criteria, never tighten them.
    ///   - edge: whether the contact falls inside the screen's edge band (decided by the host, this module does not know the view size).
    func noteTouch(majorRadius: Double, edge: Bool) {
        guard enabled, isRunning, !PopopxAppLockState.shared.isLocked else { return }
        let now = Date()
        lastTouchAt = now
        let radius = majorRadius.isFinite ? max(0, majorRadius) : 0
        // Learn "how big this finger is": only readings inside the reasonable range are learned, palm heel/thigh never enter the baseline.
        if radius > 0, radius <= PopopxBehaviorCriteria.maximumPlausibleRadiusPoints {
            if typicalRadius > 0 {
                typicalRadius += PopopxBehaviorCriteria.radiusAlpha * (radius - typicalRadius)
            } else {
                typicalRadius = radius
            }
        }
        let oversized = radius > 0
            && radius > max(
                typicalRadius * PopopxBehaviorCriteria.radiusAnomalyFactor,
                PopopxBehaviorCriteria.minimumRadiusAnomalyPoints
            )
        if edge || oversized {
            irregularTouchMoments.append(now)
        }
        pruneTouchMoments(now: now)
        refreshSuspicion(now: now)
    }

    // MARK: Presence-check gate for high-risk actions

    /// Called by the host before "entering settings / exporting keys / viewing top-secret messages".
    ///
    /// Only `.suspicious` is stopped; `.calm` and `.watching` are released immediately, every time —
    /// a gate that requires thinking about whether to call it will in the end be skipped, so it must add almost no trouble.
    /// `completion(true)` only means "you may proceed"; the authentication itself has already been done here (when biometrics succeed
    /// module 2 unlocks along the way, see `PopopxDuressAuthManager.swift:2088-2092`).
    /// When `false` is returned the host should **do nothing at all**: the person has already landed on the overlay and will go through the keyboard.
    func authorizeSensitiveAction(
        reason: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard enabled, suspicion == .suspicious else {
            completion(true)
            return
        }
        let state = PopopxAppLockState.shared
        // Already locked, or in the middle of a silent self-destruct: do not stack another layer of authentication. The overlay is that door,
        // and during `duressSilentFlow` any extra sheet is shouting "this password is not right" right in front of the coercer.
        guard !state.isLocked, !state.duressSilentFlow, !awaitingAuthorization else {
            completion(false)
            return
        }
        let auth = PopopxDuressAuthManager.shared
        // `.unavailable` is handled as do-not-release (see the header note). `prefersBiometricUnlock` has already folded
        // the three cases "biometrics switched off / downgrade after consecutive failures / no regular passcode set" into it
        // （`PopopxDuressAuthManager.swift:1159-1164`）。
        guard auth.prefersBiometricUnlock, auth.biometricsAvailable else {
            denyAndLock()
            completion(false)
            return
        }
        awaitingAuthorization = true
        auth.requestBiometricUnlock(reason: reason) { granted in
            // Both of module 2's completion paths are on the main thread: the guard one is called synchronously inside a `@MainActor` method,
            // the other is wrapped in `Task { @MainActor in }` (`PopopxDuressAuthManager.swift:2078-2094`).
            // `assumeIsolated` only tells the type system about this and does not enqueue anything extra
            // (same as module 1's `PopopxAntiTheftMotionGuard.swift:603-605`, `AudioRecPlay.swift:53`).
            MainActor.assumeIsolated {
                self.awaitingAuthorization = false
                if granted {
                    // The person has proved their presence face to face: suspicion is zeroed, and learning restarts from the grip posture of this moment.
                    self.resetBaseline()
                } else {
                    self.denyAndLock()
                }
                completion(granted)
            }
        }
    }

    /// The async shape of `authorizeSensitiveAction`, for hosts already inside an `async` flow
    /// (`exportArchive()` and the two top-secret card places). Its semantics are **word for word identical** to the callback version, including "only
    /// `.suspicious` is stopped" and "when false is returned the host does nothing" — this method only changes the shape, it adds no judgement.
    func authorized(reason: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            authorizeSensitiveAction(reason: reason) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// The only entry point for the settings page's "one-tap drill". **Takes only numbers, returns only a conclusion**: it does not touch lock state, does not trigger authentication,
    /// and leads to no wiping whatsoever. The criteria themselves are in `PopopxBehaviorCriteria.evaluate`, the same code the live stream uses.
    nonisolated static func evaluate(
        deviationDegrees: Double,
        sustainedSeconds: Double,
        irregularTouches: Int,
        angleLimit: Double
    ) -> PopopxSuspicion {
        PopopxBehaviorCriteria.evaluate(
            deviationDegrees: deviationDegrees,
            sustainedSeconds: sustainedSeconds,
            irregularTouches: irregularTouches,
            angleLimit: angleLimit
        )
    }

    // MARK: Sampling switch

    /// The single sampling gate: the master switch on, running, the sensor available, in the foreground, not locked — only when all five hold is anything really sampled.
    /// If any condition fails, sampling stops at once (zero background power drain; module 1's :35 energy requirement holds here just the same).
    private func updateSampling() {
        let state = PopopxAppLockState.shared
        let shouldSample = enabled
            && isRunning
            && motionAvailable
            && appIsActive
            && !state.isLocked
            && !state.duressSilentFlow
        if shouldSample {
            startSampling()
        } else {
            stopSampling()
        }
        if wasLocked, !state.isLocked {
            // The overlay has just been unlocked = the person has just proved their identity face to face once. Rebuild the baseline from the grip posture of this moment,
            // otherwise "unlock lying down → locked again 6 seconds later" would drive people to switch the feature off.
            resetBaseline()
        }
        wasLocked = state.isLocked
    }

    private func startSampling() {
        guard !samplingActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / PopopxMotionCriteria.sampleRateHz
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let motion = data else { return }
            // The callback is already on the `.main` queue; `assumeIsolated` merely tells the type system about that.
            MainActor.assumeIsolated {
                self.receive(motion)
            }
        }
        samplingActive = true
    }

    private func stopSampling() {
        guard samplingActive else { return }
        manager.stopDeviceMotionUpdates()
        samplingActive = false
        trend.removeAll()
        lastSampleAt = nil
        // Duration spent while sampling was stopped must not count toward "sustained deviation", so the whole deviation state is zeroed together.
        resetDeviationRun()
        settledSeconds = 0
        setDownPending = false
        stillRunSeconds = 0
    }

    // MARK: Per frame

    private func receive(_ motion: CMDeviceMotion) {
        let now = Date()
        let interval = min(max(lastSampleAt.map { now.timeIntervalSince($0) } ?? sampleInterval, 0), 0.5)
        lastSampleAt = now

        // 1) Touch evidence ages out first, then takes part in this round of deciding: stale erratic touching should not raise a lock.
        pruneTouchMoments(now: now)

        // 2) Violent shaking and the brief hands-off. Both only escalate to "watching" and never raise a lock on their own,
        //    so making the thresholds here rather sensitive is safe.
        let wobble = PopopxBehaviorCriteria.magnitude(motion.userAcceleration)
        if wobble.isFinite {
            if wobble > peakWobbleG { peakWobbleG = wobble }
            if wobble >= PopopxBehaviorCriteria.shakeG {
                lastViolentShakeAt = now
                setDownPending = false
                stillRunSeconds = 0
            } else if wobble <= PopopxBehaviorCriteria.stillG {
                stillRunSeconds += interval
                if stillRunSeconds >= PopopxBehaviorCriteria.handOffStillSeconds,
                   now.timeIntervalSince(lastTouchAt) >= PopopxBehaviorCriteria.handOffStillSeconds {
                    setDownPending = true
                }
            } else {
                if setDownPending, wobble >= PopopxBehaviorCriteria.resumeG {
                    // It moved again after resting: the earlier stretch of "the phone was not in a hand" has ended, and whoever holds it now needs a closer look.
                    lastHandOffAt = now
                    setDownPending = false
                }
                stillRunSeconds = 0
            }
        }

        // 3) Grip posture. Using `gravity` rather than `attitude`: the former comes directly from the accelerometer and is unaffected by heading drift.
        let gravity = motion.gravity
        let gx = Double(gravity.x)
        let gy = Double(gravity.y)
        let gz = Double(gravity.z)
        guard gx.isFinite, gy.isFinite, gz.isFinite else { return }
        // `atan2` is bounded and continuous across all quadrants (even with the phone pointing straight up, gz→0 produces no NaN),
        // whereas switching to asin or dividing by gz would blow up a fake large deviation at posture singularities.
        let angle = PopopxAttitude(
            radiansPitch: atan2(-gy, gz),
            radiansRoll: atan2(gx, gz)
        )
        currentAngle = angle
        guard isBaselineCaptured else {
            // The first frame only acts as a seed. At this moment we must still be in the foreground and unlocked, so whoever holds the phone is the owner.
            baselineAngle = angle
            isBaselineCaptured = true
            previousDeviation = 0
            return
        }

        let limit = angleLimitDegrees
        let deviation = angle.deviationDegrees(from: baselineAngle)
        deviationDegrees = deviation

        // 4) Baseline learning: following slowly only inside the small-deviation zone where it "still looks like the owner" (the large-deviation zone is frozen, see the header note).
        if deviation < limit * PopopxBehaviorCriteria.baselineFreezeFactor {
            baselineAngle = blended(
                from: baselineAngle,
                toward: angle,
                alpha: PopopxBehaviorCriteria.baselineAlpha
            )
        }

        // 5) Sustained duration: counted backwards from the ring buffer, the only algorithm (see `trailingSustainedSeconds`).
        trend.append(PopopxAngleSample(at: now, deviationDegrees: deviation))
        pruneTrend(now: now)
        sustainedDeviationSeconds = PopopxBehaviorCriteria.trailingSustainedSeconds(
            deviations: trend.map(\.deviationDegrees),
            sampleInterval: sampleInterval,
            limit: limit
        )

        // 6) The 45-second "stable new posture" self-heal (its cost and reasons are in the header note, written very plainly).
        let steady = abs(deviation - previousDeviation) <= PopopxBehaviorCriteria.relearnDriftDegrees
        if deviation >= limit * PopopxBehaviorCriteria.baselineFreezeFactor,
           steady,
           irregularTouchCount == 0 {
            settledSeconds += interval
            if settledSeconds >= PopopxBehaviorCriteria.relearnHoldSeconds {
                baselineAngle = angle
                settledSeconds = 0
                sustainedDeviationSeconds = 0
            }
        } else {
            settledSeconds = 0
        }
        previousDeviation = deviation

        // 7) The conclusion, and the only permitted side effect.
        refreshSuspicion(now: now)
        guard suspicion == .suspicious else { return }
        let state = PopopxAppLockState.shared
        guard !state.isLocked, !state.duressSilentFlow else { return }
        if let at = lastTriggerAt, now.timeIntervalSince(at) < Self.triggerCooldown { return }
        lastTriggerAt = now
        // Sensors only lock. What can be reached from here, and what this file is allowed to call, ends right here.
        state.lock(reason: .behavior)
        PopopxHaptics.notice(.warning)
        // The string must be one single literal: `os`'s `debug` overload goes through `OSLogMessage`,
        // so if a `+` concatenation appears in the middle it degrades to the `StaticString?` overload and does not compile. And `debug`'s parameter is
        // `@autoclosure`, so properties inside the interpolation must be written as `self.` (module 1's :660 has no interpolated properties, so it never hits this).
        // The log contains no personal information, only three numbers — enough to explain "why it just locked".
        logger.debug(
            "behavior: locked, deviation \(Int(deviation)) over limit \(Int(limit)), \(self.irregularTouchCount) irregular touches"
        )
        stopSampling()
    }

    private var sampleInterval: Double {
        1.0 / PopopxMotionCriteria.sampleRateHz
    }

    /// Per-component EMA, with the difference wrapped back into (-180, 180] before weighting: a weighted average taken directly over angles flies apart near ±180°.
    private func blended(
        from base: PopopxAttitude,
        toward angle: PopopxAttitude,
        alpha: Double
    ) -> PopopxAttitude {
        let pitch = PopopxAttitude.wrappedDegrees(angle.pitchDegrees - base.pitchDegrees)
        let roll = PopopxAttitude.wrappedDegrees(angle.rollDegrees - base.rollDegrees)
        return PopopxAttitude(
            pitchDegrees: base.pitchDegrees + alpha * pitch,
            rollDegrees: base.rollDegrees + alpha * roll
        )
    }

    private func pruneTrend(now: Date) {
        let cutoff = now.addingTimeInterval(-PopopxBehaviorCriteria.trendSeconds)
        while let first = trend.first, first.at < cutoff || trend.count > PopopxBehaviorCriteria.maxTrendSamples {
            trend.removeFirst()
        }
    }

    private func pruneTouchMoments(now: Date) {
        let cutoff = now.addingTimeInterval(-PopopxBehaviorCriteria.irregularTouchWindow)
        while let first = irregularTouchMoments.first, first < cutoff {
            irregularTouchMoments.removeFirst()
        }
        irregularTouchCount = irregularTouchMoments.count
    }

    private func resetDeviationRun() {
        deviationDegrees = 0
        sustainedDeviationSeconds = 0
        previousDeviation = 0
        trend.removeAll()
    }

    /// The pure function's conclusion + the escalation from events (shaking / hands-off). Events only lift it up, never push it down:
    /// one violent shake should not loosen an angle criterion that has already been met.
    private func refreshSuspicion(now: Date) {
        let evaluated = Self.evaluate(
            deviationDegrees: deviationDegrees,
            sustainedSeconds: sustainedDeviationSeconds,
            irregularTouches: irregularTouchCount,
            angleLimit: angleLimitDegrees
        )
        var result = evaluated
        if armedByEvent(now: now) {
            result = result.escalated(with: .watching)
        }
        if result != suspicion { suspicion = result }
    }

    private func armedByEvent(now: Date) -> Bool {
        for date in [lastViolentShakeAt, lastHandOffAt] {
            if let date, now.timeIntervalSince(date) <= PopopxBehaviorCriteria.armHoldSeconds {
                return true
            }
        }
        return false
    }

    /// Stops the high-risk action and hands the person to the overlay's keyboard. Still "lock only": no data is touched.
    private func denyAndLock() {
        let state = PopopxAppLockState.shared
        guard !state.duressSilentFlow else { return }
        guard !state.isLocked else { return }
        // `.manual` rather than `.behavior`: module 1's :104-105 assigns "module 2's forced re-authentication" to it.
        state.lock(reason: .manual)
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.beat()
            }
        }
        // `.common` mode: while the keyboard is up the main runloop sits in eventTracking mode and does not run ordinary timers,
        // and that is exactly when the lock state most needs watching (same as module 1's :674-676).
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    /// One beat per second at 1Hz. When the sensor stalls (screen locked, dropped frames, system throttling) it guarantees that evidence ages out and state resets.
    private func beat() {
        updateSampling()
        guard enabled, isRunning, samplingActive else { return }
        let now = Date()
        pruneTouchMoments(now: now)
        pruneTrend(now: now)
        sustainedDeviationSeconds = PopopxBehaviorCriteria.trailingSustainedSeconds(
            deviations: trend.map(\.deviationDegrees),
            sampleInterval: sampleInterval,
            limit: angleLimitDegrees
        )
        refreshSuspicion(now: now)
    }

    // MARK: Notifications (add in start, remove in stop, the same discipline as module 1's :684-716)

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
        // Screen lock/incoming calls also come through here: by then the user can no longer see the interface, so touch evidence should not keep being banked.
        let resign = center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleDidEnterBackground()
            }
        }
        observers = [background, active, resign]
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
    }

    private func handleDidEnterBackground() {
        // Zero background power drain: locked or not, sampling stops the moment the foreground is left.
        appIsActive = false
        awaitingAuthorization = false
        updateSampling()
    }

    private func handleDidBecomeActive() {
        appIsActive = true
        updateSampling()
    }
}
