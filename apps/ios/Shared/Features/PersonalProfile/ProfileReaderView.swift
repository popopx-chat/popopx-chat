//
//  ProfileReaderView.swift
//  POPOPX (iOS)
//
//  [Encrypted personal profile · module 4b] The receiving side's full-screen reader, plus its own window host.
//
//  Three types, three responsibilities, none crossing into another's bounds:
//
//  1. `ProfileReaderHost` — this feature's **own** `UIWindow` host. It deliberately does not reuse
//     `PopopxSecureWindowManager.shared.present(payload:target:)`: that one's input is
//     `PopopxSecurePayload`, its root view is a hard-wired `PopopxSecureShieldedContent(model:)`, and its
//     `sessionAlreadyOpen` gate (PopopxSecureWindowManager.swift:240) shares one
//     `isWindowOpen` with the top-secret path — opening a card would stop top-secret from opening, and opening top-secret would stop the card from opening, and neither is the product intent.
//     Only three things are copied verbatim here: the window recipe (`:297-309`'s `.alert + 1`), the timer shape (`:492-519`'s 0.1s
//     `.common` mode Timer), and the degradation note "if it cannot start that must be said" (:481-486).
//  2. `PopopxProfileReaderModel` — all state visible during reading: phase, seconds remaining, media slots, the plaintext's lifecycle.
//  3. `ProfileReaderView` — the layout. The shield, blind watermark, countdown banner and offline degradation banner all hang on this layer.
//
//  ### Why this clock is "wall clock sets the deadline, monotonic clock measures the elapsed"
//  The start point must be the **persisted** `firstOpenedAt` (`ProfileStorageManager.markFirstOpened`), otherwise quitting and re-entering
//  would hand out a brand-new time limit for free. The one weakness of a persisted wall clock is the owner changing the clock, so every tick takes
//  `ProcessInfo.systemUptime` to derive "what time it should be right now", and if that differs from the real wall clock by more than the tolerance it is treated as already destroyed —
//  which is exactly the thing the storage layer expresses with `.clockRewound` (ProfileStorageManager.swift:534-536),
//  and the view layer may not turn a blind eye to it. `systemUptime` is only ever used to measure the **elapsed scale**, never to set the **deadline**.
//
//  ### The burn path has three things, and missing one is a lie
//  1. Plaintext: `memset_s` overwrites the one `Data` this model holds (the same technique as `popopxSecureErase`, see
//     PopopxSecurePayload.swift:446-463). The `String` SwiftUI has taken away is managed by ARC, and this layer does not promise to overwrite it
//     — the same honest boundary spelled out in `PopopxSecurePayload.swift:42-46`.
//  2. Media: `ProfileStorageManager.removeAllMedia(profileId:)`, taking the directory away with it.
//  3. Local records: `apiDeleteChatItems(mode: .cidmInternal)` (the call-site shape copies Shared/POPOPXApp.swift:64-86,
//     it deletes only this device's copy and does not broadcast to the other side). The third one **can fail** (offline, DB lock contention). If it fails it must, on the burn page, be
//     said out loud, because within the claim "this one has been burned" it is the only part that might not have happened — same motive as
//     `PopopxSecureChatTarget.isDeletable`（PopopxSecureWindowManager.swift:75-83）。
//
//  ### The outbound one is neither timed nor burned
//  A card with `incoming == false` is the one **the owner sent out**: its `profileId` is the owner's own profile media directory
//  (`ProfileStorageManager` partitions by profileId), so applying the recipient rules and calling `removeAllMedia` would delete the user's own
//  text, images and video. Therefore every timer and every destruction below carries the `privacyRead` gate, and it is true only in the receiving direction.
//
//  ### A key already burned may not revive within this session
//  The destruction path calls `forgetRead` (keeping the record would grow a countdown, ProfileStorageManager.swift:452-456), but once the record is gone
//  `readState` returns to `.unread` — the card grows "not opened" again, and one more tap means a brand-new time limit. So this class keeps an extra
//  in-process `burnedKeys`: when the DB delete succeeds it is only a second lock, and when the delete fails it is the only door still standing.
//  Nothing is promised across launches — that cell relies on the DB delete itself, and this file does not falsely claim to have any other guarantee.
//
//  Colour, font size, corner radius and spacing always come from Shared/Theme/PopopxTheme.swift's tokens; controls use only
//  the atomic library already in Shared/Components; the security shell always reuses the Shared/Features/SecureEphemeral set.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand — the red line forbids scripts from changing project.pbxproj.
//

import AVFoundation
import POPOPXChat
import SwiftUI
import UIKit

// // MARK: - Open failures

/// All the reasons `present` can refuse. One case = one sentence the user must see, and a silent refusal is the worst failure shape.
enum PopopxProfilePresentFailure: Hashable, Sendable {
    /// A card window is already open. Cards **do not support stacked windows**: two plaintexts on one screen turns "view-once" into "view-and-mix".
    case sessionAlreadyOpen
    /// The screen was already being recorded/mirrored before opening.
    case screenCaptured
    /// The anti-debugging test refuses to let it through (this process is being traced).
    case antiDebugBlocked
    /// This profile requires front-camera attendance, and the camera permission was not granted. A privacy card without attendance is a door with no lock on it.
    case cameraPermissionDenied
    /// No `UIWindowScene` able to host a window could be obtained (in the background, or the scene is not built yet).
    case noPresentationContext
    /// This clock has already run out: the time limit hit zero, the clock was rewound, the 24-hour-unread fallback, or it was already burned within this session.
    case readClockExpired
    /// The payload itself does not hold shape: unknown version, duration out of range, or content entirely empty.
    case payloadRejected(reason: String)

    /// The plain human sentence on the card/toast. Same test as `PopopxSecurityAlert.reasonText`: state clearly "which kind of thing blocked it",
    /// do not predict consequences and do not promise a remedy.
    var reasonText: String {
        switch self {
        case .sessionAlreadyOpen: return NSLocalizedString("A profile page is already open — close it first", comment: "profile open refusal")
        case .screenCaptured: return NSLocalizedString("The screen is being recorded or mirrored, so opening was refused", comment: "profile open refusal")
        case .antiDebugBlocked: return NSLocalizedString("This device is being traced by a debugger, so opening was refused", comment: "profile open refusal")
        case .cameraPermissionDenied: return NSLocalizedString("This profile page requires camera watch; allow camera access first", comment: "profile open refusal")
        case .noPresentationContext: return NSLocalizedString("There is no interface available to show this profile page in", comment: "profile open refusal")
        case .readClockExpired: return NSLocalizedString("The reading window for this profile page has expired", comment: "profile open refusal")
        case let .payloadRejected(reason): return reason
        }
    }
}

// // MARK: - Content slots

/// The media's visible state on this device for one slot. `missing`/`unreadable` must **speak**, no blank slot is given:
/// blankness makes people think "the other side sent an image I cannot see", while the real situation is that this device kept no original — the next action for the two is completely different.
enum PopopxProfileReaderMedia: Hashable {
    /// The path has not been asked of storage yet.
    case pending
    /// The slot saved by the Cabin degradation: never displayed, it only serves as proof that the number in the degradation banner exists.
    case omitted
    /// This device has no original (`missing`), or the original is there but cannot be read (`unreadable`).
    case unavailable(kind: PopopxProfileMedia.Kind, reason: String)
    case image(URL)
    case video(URL)
}

/// One row in the reader. `id` uses the block index: a manifest neither grows nor shrinks within one reading, so the index is a stable identity.
struct PopopxProfileReaderEntry: Identifiable {
    let id: Int
    let block: PopopxProfileBlock
    var media: PopopxProfileReaderMedia
}

// // MARK: - Reader state

/// All state visible during reading. `@MainActor`: only the tick, alert and close paths write it, and all of them are on the main thread.
@MainActor
@Observable
final class PopopxProfileReaderModel {
    /// Three phases, mutually exclusive and covering every visible state. The difference from the top-secret tier (`PopopxSecureSheetModel.Phase,
    /// PopopxSecureSheetView.swift:49-64) is deliberate: this feature **does not offer** the "black cover but no destruction"
    /// `locked` phase, because a card has no "run biometrics once more and come back" path, and keeping a locked phase
    /// would have users staring at a black screen guessing whether they can still read it back.
    enum Phase: Hashable {
        /// The body is readable and the privacy tier's countdown is running.
        case reading
        /// The plaintext is erased, and the window is kept so the user can see **why** it closed. `reason` nil = read to the end normally / the deadline arrived normally.
        case burned(reason: String?)
        /// Wrapping up: the view is disappearing and no callback should take effect any more.
        case closing
    }

    /// How far the wall clock and the monotonic clock are allowed to differ. 2 seconds covers an automatic time-sync adjustment, but not "set the time back ten minutes"
    /// (the tolerance value sits in the same bracket as `ProfileStorageManager.clockRewindTolerance`, and so does the test).
    static let clockJumpTolerance: TimeInterval = 2
    /// How long the burn page stays before the window is taken down. Too short explains nothing, too long blocks the way.
    static let burnNoticeSeconds: Double = 1.6

    /// Whether this reading follows "start the timer and destroy once opened". True only for a receiving-direction privacy card, see the file header for why.
    let privacyRead: Bool
    let totalSeconds: Int
    let deliveryMode: PopopxProfileDelivery
    let omittedMediaCount: Int
    /// The blind watermark's session number: one per window, not reused after destruction (forensic value as in `PopopxSecureSheetModel.sessionIdentifier`
    /// — it answers "which viewing did this copy go out from").
    let sessionIdentifier: String

    private(set) var phase: Phase = .reading
    private(set) var remainingSeconds: Int
    private(set) var title: String
    private(set) var subtitle: String?
    private(set) var entries: [PopopxProfileReaderEntry]

    /// Which guard path is missing and why. `nil` = nothing to say. It is **not allowed** to add a false "detection running" promise on top of this:
    /// whatever the engine returns is what gets shown (`PopopxCameraGuardEngine.startupNote` even reports "model missing" truthfully, :269).
    var guardNote: String?
    /// The sentence that triggered the burn (`PopopxSecurityAlert.reasonText` or the clock-change explanation).
    private(set) var burnedBy: String?
    /// Whether the local records were deleted. `nil` = no answer yet. **false must be said in the UI**.
    private(set) var localRecordDeleted: Bool?
    /// Cleanup is still running. When a privacy tier burns fast the UI must say "cleaning up" and must not pretend the cleanup is already done.
    private(set) var isCleaning = false

    /// The deadline: `firstOpenedAt + ttl` on the persisted wall clock. It is **not** derived from `systemUptime`.
    private let deadlineWallClock: TimeInterval?
    /// The wall clock and the monotonic clock at the moment the window opened, used to separate "the clock was changed" from "time really passed".
    private let anchorWallClock: TimeInterval
    private let anchorUptime: TimeInterval

    private let profileId: String
    /// The one plaintext this model holds. The view gets a `String` computed fresh from here, and what gets erased is this `Data` cell.
    private var plaintext: Data?
    private let close: () -> Void
    /// The burn's cleanup work is handed to the host: this class touches no window, no storage and no DB.
    var onBurn: (() -> Void)?

    private var isErased = false
    private var hasBurned = false
    private var mediaIsLoading = false

    #if DEBUG
    /// The single witness's "plaintext has been handed out" proof. Why not read `title`/`entries` directly: `@Observable` wraps them in observation
    /// accessors that inherit `@MainActor`, while `deinit` is non-isolated, so reading them does not compile — the same trap recorded at
    /// PopopxSecureSheetView.swift:90-103. This box is a plain class with no isolation, and a `let` reference does not take part in observation either,
    /// so `deinit` can read it; it exists only in DEBUG and has exactly one write point (`eraseForClose()`).
    private final class EraseWitness {
        var plaintextGivenUp = false
    }

    private let eraseWitness = EraseWitness()
    #endif

    init(
        payload: PopopxProfilePayload,
        firstOpenedAt: TimeInterval?,
        privacyRead: Bool,
        close: @escaping () -> Void
    ) {
        let manifest = payload.manifest
        self.privacyRead = privacyRead
        self.totalSeconds = manifest.ttlSeconds
        self.deliveryMode = manifest.deliveryMode
        self.omittedMediaCount = manifest.omittedMediaCount
        self.profileId = manifest.profileId
        self.title = manifest.title
        self.subtitle = manifest.subtitle
        self.sessionIdentifier = UUID().uuidString
        self.close = close

        var rows: [PopopxProfileReaderEntry] = []
        rows.reserveCapacity(manifest.blocks.count)
        for (index, block) in manifest.blocks.enumerated() {
            rows.append(
                PopopxProfileReaderEntry(
                    id: index,
                    block: block,
                    media: Self.initialSlot(of: block, delivery: manifest.deliveryMode)
                )
            )
        }
        self.entries = rows

        // The plaintext keeps one overwritable buffer only: title + subtitle + all text blocks. It is the source used for display,
        // and also the cell that memset_s must overwrite when burning.
        var joined = manifest.title
        if let subtitle = manifest.subtitle, !subtitle.isEmpty { joined += "\n" + subtitle }
        for block in manifest.blocks {
            if case let .text(body) = block { joined += "\n" + body }
        }
        self.plaintext = joined.isEmpty ? nil : Data(joined.utf8)

        let now = Date().timeIntervalSince1970
        self.anchorWallClock = now
        self.anchorUptime = ProcessInfo.processInfo.systemUptime

        let deadline: TimeInterval?
        if privacyRead, let firstOpenedAt, firstOpenedAt.isFinite, firstOpenedAt > 0 {
            deadline = firstOpenedAt + Double(manifest.ttlSeconds)
        } else {
            deadline = nil
        }
        self.deadlineWallClock = deadline
        if let deadline {
            self.remainingSeconds = max(0, Int((deadline - now).rounded(.up)))
        } else {
            self.remainingSeconds = 0
        }
    }

    deinit {
        #if DEBUG
        // Deallocation assertion: when the model is released the plaintext must already have been handed out. false means the destroy/close path was skipped —
        // usually the host forgot to call `eraseForClose()` while taking the window down.
        if !eraseWitness.plaintextGivenUp {
            assertionFailure("PopopxProfileReaderModel was released without giving up the plaintext: the destroy or close path was skipped")
        }
        #endif
    }

    // // MARK: Projections

    var isReading: Bool {
        if case .reading = phase { return true }
        return false
    }

    var isBurned: Bool {
        if case .burned = phase { return true }
        return false
    }

    /// The fraction already elapsed (0…1). The permanent tier has no clock, and giving 1 means "no progress bar should appear".
    var progress: Double {
        guard privacyRead, totalSeconds > 0 else { return 1 }
        return 1 - min(1, max(0, Double(remainingSeconds) / Double(totalSeconds)))
    }

    // // MARK: Lifecycle

    /// Opening the window. The phase is `.reading` from creation onwards, and this step only serves as the point "the window is visible": the host may start
    /// side channels only after it (the landing point of the hard constraint "the guard runs only while the window is visible").
    func open() {
        phase = .reading
    }

    /// Per tick. Returning false = this clock no longer needs to be asked (already burned, already closed, or there was never a clock), and the host stops the timer on that.
    ///
    /// Elapsed scale uses `ProcessInfo.systemUptime` (changing the clock cannot touch it), the deadline uses the persisted wall clock (quit and re-enter does not reset it).
    /// The two disagreeing by more than the tolerance means the wall clock was changed — treat it as already destroyed, rather than picking whichever side flatters the reading.
    @discardableResult
    func tick(now wall: Date = Date()) -> Bool {
        guard privacyRead, isReading, let deadlineWallClock else { return false }
        let wallNow = wall.timeIntervalSince1970
        let monotonicEstimate = anchorWallClock + (ProcessInfo.processInfo.systemUptime - anchorUptime)
        guard abs(wallNow - monotonicEstimate) <= Self.clockJumpTolerance else {
            beginBurn(reason: Copy.burnedByClockRewound)
            return false
        }
        let remaining = deadlineWallClock - wallNow
        guard remaining > 0 else {
            remainingSeconds = 0
            beginBurn(reason: nil)
            return false
        }
        // Rounding up: rounding down means every crossing of a second boundary hands out up to 1 extra second for free — the same definition as `deriveState`.
        remainingSeconds = Int(remaining.rounded(.up))
        return true
    }

    /// A security alert. The card side offers no "locked but kept" intermediate state: any path that hits means burn, because there is no
    /// second biometrics run that could let the user come back (the difference from the top-secret path is in `Phase`'s comment).
    func handle(_ alert: PopopxSecurityAlert) {
        guard isReading else { return }
        beginBurn(reason: alert.reasonText)
    }

    /// The user pressed close. Closing a privacy tier is **equally** a burn: the "burn" of "view-once" is not decided by the user
    /// (same as `PopopxSecureWindowManager`'s `closeAndBurn` ruling).
    func requestClose() {
        guard isReading else { return }
        if privacyRead {
            beginBurn(reason: nil)
        } else {
            phase = .closing
            eraseForClose()
            close()
        }
    }

    /// Reaching the burn: stop the body and erase the plaintext first, then hand the cleanup work to the host. Idempotent — a second call no longer triggers `onBurn`.
    func beginBurn(reason: String?) {
        guard !hasBurned else { return }
        hasBurned = true
        burnedBy = reason
        phase = .burned(reason: reason)
        eraseForClose()
        onBurn?()
    }

    /// Cleanup has started (the "cleaning up" in the UI).
    func beginCleaning() {
        isCleaning = true
    }

    /// The cleanup's reply. `deletedLocalRecord` nil = no verdict yet, and neither of those two UI sentences may be said.
    func reportCleaning(deletedLocalRecord: Bool?) {
        if let deletedLocalRecord { localRecordDeleted = deletedLocalRecord }
        isCleaning = false
    }

    /// Clearing the plaintext goes through this one exit only: bypassing it and changing the field directly would make `deinit`'s deallocation assertion say "never cleared". Idempotent.
    func eraseForClose() {
        guard !isErased else { return }
        isErased = true
        title = ""
        subtitle = nil
        entries = []
        // The mutable bytes must be taken directly on the `plaintext` l-value: doing `if var copy = plaintext` first
        // shares the buffer out, so memset lands on the copy while the original is not touched by a single byte
        // (`PopopxSecurePayload.swift:453-462` records the same thing, and there it is the same form too).
        popopxSecureErase(&plaintext)
        #if DEBUG
        eraseWitness.plaintextGivenUp = true
        #endif
    }

    // // MARK: Media

    /// Asks storage once for every media block that has no path yet. Re-entrant: a second call returns immediately and will not ask for the same batch of paths twice.
    ///
    /// Only the `URL` is taken here, not a single byte is read — decoding leaves the main thread inside the tile's own `.task`.
    func loadMissingMedia() async {
        guard !mediaIsLoading, !isErased else { return }
        mediaIsLoading = true
        defer { mediaIsLoading = false }
        let storage = ProfileStorageManager.shared
        for entry in entries {
            guard case .pending = entry.media else { continue }
            guard let media = Self.media(of: entry.block) else { continue }
            let loaded = await storage.loadMedia(media, profileId: profileId)
            // The view may already be gone and the content already erased: after every hop the check is redone before writing.
            if Task.isCancelled || isErased { return }
            let next: PopopxProfileReaderMedia
            switch loaded {
            case let .loaded(url):
                switch media.kind {
                case .image: next = .image(url)
                case .video: next = .video(url)
                }
            case .missing:
                next = .unavailable(kind: media.kind, reason: Copy.mediaMissing)
            case let .unreadable(_, reason):
                next = .unavailable(kind: media.kind, reason: reason)
            }
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].media = next
            }
        }
    }

    /// The initial value. In the degraded tier media blocks were already removed wholesale at the `normalized()` step, and the `.omitted` kept here
    /// only catches the malformed "the peer sends a meshTextOnly plus media blocks directly" combination — and it too may not be shown as a blank slot.
    private static func initialSlot(
        of block: PopopxProfileBlock,
        delivery: PopopxProfileDelivery
    ) -> PopopxProfileReaderMedia {
        switch block {
        case .text:
            return .pending
        case .image, .video:
            return delivery == .meshTextOnly ? .omitted : .pending
        }
    }

    private static func media(of block: PopopxProfileBlock) -> PopopxProfileMedia? {
        switch block {
        case .text: return nil
        case let .image(media): return media
        case let .video(media): return media
        }
    }
}

// // MARK: - Window host

/// The card's own full-screen window host. The division of labour with `PopopxSecureWindowManager` is written in this file's header;
/// in one sentence: **that manager should not know the card exists**.
@MainActor
final class ProfileReaderHost {
    static let shared = ProfileReaderHost()

    /// The keys already burned within this session. For its purpose see the file header's "a key already burned may not revive within this session".
    private(set) var burnedKeys: Set<PopopxProfileReadKey> = []

    private var window: UIWindow?
    private var model: PopopxProfileReaderModel?
    private var countdownTimer: Timer?
    private var captureMonitor: PopopxCaptureMonitor?
    private var guardEngine: PopopxCameraGuardEngine?
    private var dismissTask: Task<Void, Never>?

    var isPresented: Bool { window != nil }

    /// Whether this card has already been burned within this session. The card uses it to block "the record grows unread again after being forgotten".
    func isBurned(_ key: PopopxProfileReadKey) -> Bool { burnedKeys.contains(key) }

    private init() {}

    /// Opens a profile. Returning nil = it was shown; a returned value = the reason it was blocked, and the caller (the card) **must** display it.
    func present(
        payload: PopopxProfilePayload,
        target: PopopxProfileReadKey,
        incoming: Bool,
        createdAt: Date
    ) async -> PopopxProfilePresentFailure? {
        guard !isPresented else { return .sessionAlreadyOpen }
        if let rejected = Self.validate(payload) { return rejected }
        // The outbound one does not consult this ledger: it was never burned by this feature, and the owner's own card should not be erased by the receiving rules.
        if incoming, isBurned(target) { return .readClockExpired }

        let privacyRead = payload.isEphemeral && incoming
        var firstOpenedAt: TimeInterval?
        if privacyRead {
            // The order of the three pre-checks is deliberate: the first two are pure reads, the third raises a system sheet, and a system sheet must be placed
            // before opening the window (the card window's level is `.alert + 1`, which would press the permission sheet underneath — :245-253 uses the same test).
            //
            // The plan said `UIScreen.main.isCaptured`, and here it was replaced per the shipped ruling with
            // `PopopxScreenCapture.anyScreenIsCaptured`: the former is deprecated and reads "the one global screen",
            // so it misses cases under multiple/external screens (PopopxScreenCaptureShieldView.swift:457-464 has already fixed the test at scene level).
            guard !PopopxScreenCapture.anyScreenIsCaptured else { return .screenCaptured }
            guard PopopxAntiDebug.allowsSecurePresentation else { return .antiDebugBlocked }
            if payload.manifest.enableAntiSpyCamera, let denied = await Self.ensureCameraAccess() {
                return denied
            }
            switch await Self.openingClock(payload: payload, target: target, createdAt: createdAt) {
            case let .opened(openedAt):
                firstOpenedAt = openedAt
            case .blocked:
                return .readClockExpired
            }
        }

        guard let scene = Self.currentWindowScene() else { return .noPresentationContext }

        let model = PopopxProfileReaderModel(
            payload: payload,
            firstOpenedAt: firstOpenedAt,
            privacyRead: privacyRead,
            close: { [weak self] in self?.dismissProfileWindow() }
        )
        model.onBurn = { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.destroyLocalCopy(payload: payload, target: target, privacyRead: privacyRead)
            }
            // Zeroing out and an alert both close automatically: the explanation is kept for one screen's worth of time, then the window is taken down.
            dismissTask?.cancel()
            dismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.autoDismissNanoseconds)
                guard !Task.isCancelled else { return }
                self?.dismissProfileWindow()
            }
        }
        model.open()
        self.model = model

        let window = UIWindow(windowScene: scene)
        window.rootViewController = Self.hostController(for: model)
        // Copies PopopxSecureWindowManager.swift:299-302: only `.alert + 1` can outrank the system sheets inside the app,
        // otherwise one photo-library/permission sheet buries the body underneath while the countdown keeps running. `UIWindow.Level` does not support `+`, so rawValue is used.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        // The appearance follows the host window: an orphan window defaults to the device appearance, and when the app forces light/dark this would be misaligned.
        // It must be read before `isHidden = false`, otherwise it reads itself.
        if let host = scene.windows.first(where: \.isKeyWindow) {
            window.overrideUserInterfaceStyle = host.overrideUserInterfaceStyle
        }
        window.isHidden = false
        self.window = window

        if privacyRead {
            startSideChannels(in: window, model: model, antiSpy: payload.manifest.enableAntiSpyCamera)
            startCountdown()
        }
        PopopxHaptics.notice(.success)
        return nil
    }

    /// Takes the window down. Idempotent: if it was never open this is a no-op. All four things must happen — stop the timer, stop the side channels, erase the plaintext, then drop the window.
    func dismissProfileWindow() {
        dismissTask?.cancel()
        dismissTask = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        // `stop()` sets `onAlert` to nil (PopopxScreenCaptureShieldView.swift:393-399):
        // a monitor that "revives itself carrying the old callbacks" cannot be reused safely, so once it is taken down it is dropped.
        captureMonitor?.stop()
        captureMonitor = nil
        // `startMonitoring`/`stopMonitoring` both carry a main-thread precondition
        // (PopopxCameraGuardEngine.swift:159, :202); this class is `@MainActor`, so this is on the main thread.
        guardEngine?.stopMonitoring()
        guardEngine = nil
        // Order: erase the plaintext first, then drop the reference. Reversed, DEBUG's deallocation assertion would blow up at the very moment the window comes down,
        // and that time it really would be "released without erasing".
        model?.eraseForClose()
        model = nil
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    // // MARK: Validation and clocks

    /// The last re-check of the payload's shape. `parse` has already measured it once, and what this gate stops is payloads handed in by **other entries**
    /// (scanning, deep links) — those entries get a string and do not necessarily go through `parse`.
    private static func validate(_ payload: PopopxProfilePayload) -> PopopxProfilePresentFailure? {
        guard payload.manifest.profileVersion == PopopxProfileManifest.version else {
            return .payloadRejected(reason: PopopxProfileError.unknownVersion(payload.manifest.profileVersion).reasonText)
        }
        if payload.isEphemeral {
            guard (PopopxProfilePayload.minimumTTLSeconds...PopopxProfilePayload.maximumTTLSeconds)
                .contains(payload.manifest.ttlSeconds) else {
                return .payloadRejected(reason: PopopxProfileError.invalidTTL(payload.manifest.ttlSeconds).reasonText)
            }
        }
        let hasTitle = !payload.manifest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBody = payload.manifest.blocks.contains { block in
            switch block {
            case let .text(body): return !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image, .video: return true
            }
        }
        guard hasTitle || hasBody else { return .payloadRejected(reason: Copy.emptyProfile) }
        return nil
    }

    /// `openingClock`'s verdict: readable (with a start point), or it should be refused.
    private enum OpeningClock {
        case opened(TimeInterval)
        case blocked
    }

    /// Persists `firstOpenedAt` and takes back this clock's start point.
    ///
    /// ⚠️ The call order is a hard requirement, not a style choice: `markFirstOpened` on a **cold record** can return
    /// `counting(remainingSeconds: 0)` — its signature has no duration parameter, so it can only read the cell that `readState` bound
    /// (ProfileStorageManager.swift:428-437 and :525-539 record the same thing). So after marking it here
    /// **`readState` must be asked once more** before the remaining-seconds value it gives can be trusted.
    private static func openingClock(
        payload: PopopxProfilePayload,
        target: PopopxProfileReadKey,
        createdAt: Date
    ) async -> OpeningClock {
        let ttl = payload.manifest.ttlSeconds
        let now = Date()
        // Step one: bind the ttl to the record first (the first time a given key is asked, `readState` writes this cell).
        let before = await ProfileStorageManager.shared.readState(target, ttlSeconds: ttl, now: now)
        switch before {
        case .expired, .clockRewound:
            return .blocked
        case .counting(let openedAt, let remaining):
            // A start point already exists: the same cell is reused and never reset. Quitting and re-entering, or going to background and back, cannot conjure a new time limit.
            guard remaining > 0 else { return .blocked }
            _ = await ProfileStorageManager.shared.markFirstOpened(target)   // idempotent
            return .opened(openedAt)
        case .unread:
            // The 24-hour-unread fallback. That rule in the presentation layer belongs to the card, but the **opening side** must also block it, otherwise a
            // card displayed as burned could still read out a brand-new time limit. The constant sits on the card side (a presentation-layer policy),
            // and here the same value is referenced so that no second table appears.
            if now.timeIntervalSince1970 - createdAt.timeIntervalSince1970 > ProfileCardBubbleView.unreadAutoBurnAfter {
                return .blocked
            }
            _ = await ProfileStorageManager.shared.markFirstOpened(target)
            // On a cold record markFirstOpened's return value cannot be trusted (see the paragraph above), so it is read once more and settled.
            let settled = await ProfileStorageManager.shared.readState(target, ttlSeconds: ttl, now: Date())
            switch settled {
            case .unread:
                // Just marked, yet it still returns `.unread`: a local anomaly such as a disk-write failure. Give a "counting from this moment" start point
                // instead of refusing to open — refusing would make the user think the feature is broken, and this clock was starting from this moment anyway.
                return .opened(now.timeIntervalSince1970)
            case let .counting(openedAt, remaining):
                return remaining > 0 ? .opened(openedAt) : .blocked
            case .expired, .clockRewound:
                return .blocked
            }
        }
    }

    // // MARK: Permissions and scenes

    /// Requests the permission only in the "never asked" state. When it is already denied the system is not pestered (that path never shows a sheet again), and the plain sentence is given directly.
    private static func ensureCameraAccess() async -> PopopxProfilePresentFailure? {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return nil
        case .notDetermined:
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                PopopxCameraGuardEngine.requestCameraAccess { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? nil : .cameraPermissionDenied
        case .denied, .restricted:
            return .cameraPermissionDenied
        @unknown default:
            return .cameraPermissionDenied
        }
    }

    private static func currentWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) { return active }
        // The same test as `PopopxSecureWindowManager.currentWindowScene()` (:567-572): not getting active
        // can only be the instant a scene is switching, and `foregroundInactive` hosts a window just as well. The extra `scenes.first`
        // fallback is the only place here that is looser than it — a created window merely sits in the scene and is visible only once the user is back in the foreground,
        // and the first two pre-checks of `present` already hold the "invisible means it may not open" door.
        // (no "exclude archived scenes": `UIScene.ActivationState` has no `.archived` case, and in practice it does not compile.)
        return scenes.first(where: { $0.activationState == .foregroundInactive }) ?? scenes.first
    }

    private static func hostController(for model: PopopxProfileReaderModel) -> UIViewController {
        let controller = UIHostingController(rootView: PopopxProfileReaderRootView(model: model))
        // The privacy tier needs a pure black background: the shield draws black for the capturing side too, and leaving a system grey background leaves a
        // breach where "outside the content area is not pure black" (same as :294-296). The permanent tier uses `base`, and that tier is an ordinary page to begin with.
        controller.view.backgroundColor = model.privacyRead ? .black : UIColor(PopopxPalette.base)
        return controller
    }

    // // MARK: Side channels and countdown

    private func startSideChannels(in window: UIWindow, model: PopopxProfileReaderModel, antiSpy: Bool) {
        let monitor = PopopxCaptureMonitor()
        monitor.onAlert = { [weak self, weak model] alert in
            self?.handleAlert(alert, model: model)
        }
        monitor.start(in: window)
        captureMonitor = monitor

        guard antiSpy else {
            // This profile does not require camera attendance: state clearly "which path is missing" instead of leaving an icon that looks like it is running.
            model.guardNote = Copy.antiSpyOffNote
            return
        }
        let engine = PopopxCameraGuardEngine()
        engine.onAlert = { [weak self, weak model] alert in
            self?.handleAlert(alert, model: model)
        }
        // Not being able to start is not business as usual: which path is missing and why it is missing must be visible to the user (copies the :481-486 ruling).
        // When the model was not imported `startupNote` says on its own that "object detection is not enabled, only the specular-highlight fallback is working",
        // and this layer may not smooth that into "protection is on".
        if let failure = engine.startMonitoring() {
            model.guardNote = failure.reasonText
        } else {
            model.guardNote = engine.startupNote
        }
        guardEngine = engine
    }

    private func handleAlert(_ alert: PopopxSecurityAlert, model: PopopxProfileReaderModel?) {
        guard let model, model.isReading else { return }
        PopopxHaptics.notice(.error)
        model.handle(alert)
    }

    /// A 0.1s `Timer` + `.common` mode: the shape copies PopopxSecureWindowManager.swift:492-507.
    /// It must also run while a finger holds a scroll — with `.default` the countdown stops during the whole time the user drags the card.
    private func startCountdown() {
        tick()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func tick() {
        guard let model else { return }
        // The model decides the deadline has passed itself and triggers `onBurn`; returning false means this clock no longer needs asking.
        if !model.tick() {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }

    /// The burn's three things: media, the read record, and this device's copy of the message. The DB step's outcome has to come back to the model,
    /// so that the UI's sentence "the local record was not deleted" has a basis.
    private func destroyLocalCopy(
        payload: PopopxProfilePayload,
        target: PopopxProfileReadKey,
        privacyRead: Bool
    ) async {
        guard privacyRead else { return }
        model?.beginCleaning()
        burnedKeys.insert(target)
        let storage = ProfileStorageManager.shared
        await storage.removeAllMedia(profileId: payload.manifest.profileId)
        // The record must be erased: keep it and the card grows a countdown again on the next render (ProfileStorageManager.swift:452-456).
        // After erasing it `readState` returns to `.unread`, and that cell is caught by the in-process ledger `burnedKeys` above.
        await storage.forgetRead(target)
        let deleted = await Self.deleteChatRow(target: target)
        model?.reportCleaning(deletedLocalRecord: deleted)
    }

    /// Physically deletes this device's chat item. The call-site shape copies Shared/POPOPXApp.swift:64-86.
    ///
    /// `PopopxProfileReadKey.chatId` is an `Int64` (= `ChatInfo.apiId`), while `ChatModel.getChat(_:)`
    /// takes the `ChatInfo.id` String key, so the row is looked up by `apiId` among the existing chats instead of hand-assembling
    /// keys like `"@\(id)"` — assembling a key would mean rewriting `ChatInfo.id`'s implementation inside this feature (same reason as
    /// `PopopxSecureWindowManager.swift:66-72`). When nothing is found only an error is reported and `false` is handed back:
    /// better that this one row is not deleted **and that it is said**, than deleting somebody else's row with a guessed key.
    private static func deleteChatRow(target: PopopxProfileReadKey) async -> Bool {
        let model = ChatModel.shared
        guard let chat = model.chats.first(where: { $0.chatInfo.apiId == target.chatId }) else {
            logger.error("POPOPX profile: no chat found for apiId \(target.chatId); the local record was not deleted")
            return false
        }
        do {
            // `.cidmInternal` = deletes only this device's copy and does not broadcast the deletion to the other side (same as POPOPXApp.swift:65-73).
            let deletions = try await apiDeleteChatItems(
                type: chat.chatInfo.chatType,
                id: chat.chatInfo.apiId,
                scope: chat.chatInfo.groupChatScope(),
                itemIds: [target.itemId],
                mode: .cidmInternal
            )
            for deletion in deletions {
                if let toItem = deletion.toChatItem {
                    _ = model.upsertChatItem(chat.chatInfo, toItem.chatItem)
                } else {
                    model.removeChatItem(chat.chatInfo, deletion.deletedChatItem.chatItem)
                }
                model.updateChatInfo(deletion.deletedChatItem.chatInfo)
            }
            return true
        } catch {
            // This log line is the acceptance measure: every occurrence of "read it but did not delete it" is counted by it.
            logger.error("POPOPX profile: apiDeleteChatItems failed \(responseError(error))")
            return false
        }
    }

    /// How long the burn page lingers (nanoseconds). It lives here because this class is the only one that takes windows down.
    private static var autoDismissNanoseconds: UInt64 {
        UInt64(PopopxProfileReaderModel.burnNoticeSeconds * 1_000_000_000)
    }
}

// // MARK: - Projections of the read state

/// This group of projections is shared by two files (the card decides here "should it be drawn as burned"), so they are `internal` rather than a
/// `private extension` — `private` on an extension means "private to this file", and the card's file could not reach them.
extension PopopxProfileReadState {
    /// Whether this cell should no longer be read. The card and the host share this one test, so the two do not grow separate definitions of "expired".
    var blocksReading: Bool {
        switch self {
        case .unread, .counting: return false
        case .expired, .clockRewound: return true
        }
    }
}

// // MARK: - Window root view

/// The window root. The privacy tier wraps a shield around it **from the outside**: the shield's job is to move content into the canvas "the system cannot capture",
/// and the content scrolls inside it by itself, which is exactly its intended use (PopopxScreenCaptureShieldView.swift:61-76).
private struct PopopxProfileReaderRootView: View {
    private let model: PopopxProfileReaderModel

    init(model: PopopxProfileReaderModel) {
        self.model = model
    }

    var body: some View {
        if model.privacyRead {
            PopopxScreenCaptureShieldView {
                ProfileReaderView(model: model)
            }
            .background(Color.black)
        } else {
            ProfileReaderView(model: model)
        }
    }
}

// // MARK: - Reader layout

/// The card's reading face.
///
/// The layout is hand-built instead of wrapped in `PopopxSheetContainer`: that one wraps the whole content in a `ScrollView`
/// (PopopxControls.swift:758-763), while the image slots here must hold a `ZoomableScrollView` (also a
/// `UIScrollView`) — a ScrollView inside a ScrollView means "cannot scroll" or "steals the scroll" during a gesture.
/// The price of hand-building is drawing the top bar and the corner radii yourself, and the precedent is the very same thing `PopopxSecureSheetView` did.
@MainActor
struct ProfileReaderView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable private var model: PopopxProfileReaderModel

    init(model: PopopxProfileReaderModel) {
        self.model = model
    }

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
            columns
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            // The blind watermark. Here it is **stacked on the topmost layer**: its own comment (PopopxAntiPhotoRenderView.swift:817-821)
            // says it should be drawn under the body, but the real shipped usage covers it from above with `.overlay`
            // (PopopxSecureSheetView.swift:299-302), so the real usage is followed rather than the comment.
            if model.privacyRead {
                PopopxBlindWatermarkOverlay(sessionIdentifier: model.sessionIdentifier)
                    .allowsHitTesting(false)
            }
        }
        .task { await model.loadMissingMedia() }
    }

    private var backdrop: some View {
        (model.privacyRead ? Color.black : PopopxPalette.base)
            .ignoresSafeArea()
    }

    private var columns: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.deliveryMode == .meshTextOnly {
                meshBanner
            }
            if model.privacyRead {
                safetyBanner
            }
            scrollArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if !model.isReading {
                closingCover
            }
        }
    }

    // // MARK: Top bar

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(headline)
                    .font(PopopxType.title)
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = model.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(PopopxType.meta)
                        .foregroundStyle(secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            closeButton
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.top, PopopxMetrics.spaceS)
        .padding(.bottom, PopopxMetrics.spaceXS)
    }

    /// When the title is empty a placeholder word is given: the title comes from the peer and may perfectly well be whitespace throughout.
    private var headline: String {
        let trimmed = model.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Copy.untitled : trimmed
    }

    private var closeButton: some View {
        Button {
            model.requestClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .background(closeFill, in: .circle)
                .overlay(
                    Circle().strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.close)
        .accessibilityIdentifier(model.privacyRead ? "popopx.profile.reader.close" : "popopx.profile.reader.standard.close")
    }

    private var closeFill: Color {
        model.privacyRead ? Color.popopx(0xFFFFFF, opacity: 0.08) : PopopxPalette.cardHigh
    }

    // // MARK: Banners

    /// The offline Cabin degradation banner. The verbatim wording is set by product and may appear in this one place only.
    private var meshBanner: some View {
        Label {
            Text(Copy.meshOmitted(model.omittedMediaCount))
                .font(PopopxType.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "antenna.radiowaves.left.and.right")
        }
        .foregroundStyle(model.privacyRead ? PopopxSurface.ink : PopopxPalette.meshInk)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PopopxMetrics.spaceS)
        .padding(.vertical, PopopxMetrics.spaceXS)
        .background(
            PopopxPalette.mesh.opacity(model.privacyRead ? 0.18 : 0.12),
            in: .rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
        )
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.bottom, PopopxMetrics.spaceXS)
    }

    /// The countdown security banner **permanently** at the top of the privacy tier. It stays until zero: how many seconds are left must be said by the screen itself,
    /// rather than waiting for the user to guess when the burn happened.
    private var safetyBanner: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "timer")
                    .font(PopopxType.meta)
                    .accessibilityHidden(true)
                Text(Copy.countdown(model.remainingSeconds))
                    .font(PopopxType.metric)
                    .accessibilityLabel(Copy.countdownSpoken(model.remainingSeconds))
                Spacer(minLength: PopopxMetrics.spaceXS)
                Text(Copy.countdownTotal(model.totalSeconds))
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxSurface.inkTertiary)
            }
            .foregroundStyle(countdownInk)
            // The progress bar does not use GeometryReader: `scaleEffect(anchor: .leading)` alone can shrink a Capsule
            // by the remaining proportion while the layout width is unaffected (GeometryReader would make this cell eat space of its own).
            ZStack(alignment: .leading) {
                Capsule().fill(Color.popopx(0xFFFFFF, opacity: 0.14))
                Capsule()
                    .fill(countdownInk)
                    .scaleEffect(x: max(0.002, 1 - model.progress), y: 1, anchor: .leading)
            }
            .frame(height: PopopxMetrics.space2XS)
            // Goes through the design system's switch rather than a bare `.animation`: the reduce-motion test may exist only inside `PopopxMotion`.
            .popopxAnimation(PopopxSpring.fluid, value: model.remainingSeconds, reduceMotion: reduceMotion)
            if let guardNote = model.guardNote {
                // The degradation told honestly: say which path is missing for the missing path it is, and never pretend the detection is still effective.
                Label {
                    Text(guardNote)
                        .font(PopopxType.microTag)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                }
                .foregroundStyle(PopopxSurface.inkSecondary)
                .padding(.top, PopopxMetrics.space2XS)
            }
        }
        .padding(.horizontal, PopopxMetrics.spaceS)
        .padding(.vertical, PopopxMetrics.spaceXS)
        .background(
            PopopxSurface.cardFill,
            in: .rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
        )
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.bottom, PopopxMetrics.spaceXS)
    }

    private var countdownInk: Color {
        // The last 5 seconds turn red. The threshold is in the same bracket as the top-secret tier's (the test at PopopxSecureSheetView.swift:278-282).
        model.remainingSeconds <= 5 ? PopopxPalette.danger : PopopxSurface.ink
    }

    // // MARK: Body (manages its own scrolling)

    private var scrollArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                ForEach(model.entries) { entry in
                    row(for: entry)
                }
                if model.entries.isEmpty {
                    Text(Copy.emptyBody)
                        .font(PopopxType.meta)
                        .foregroundStyle(secondaryInk)
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func row(for entry: PopopxProfileReaderEntry) -> some View {
        switch entry.block {
        case let .text(body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let isEmpty = trimmed.isEmpty
            Text(isEmpty ? Copy.emptyTextBlock : trimmed)
                .font(isEmpty ? PopopxType.caption : PopopxType.body)
                .foregroundStyle(isEmpty ? tertiaryInk : ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .image(media):
            PopopxProfileMediaTile(
                kind: media.kind,
                caption: media.caption,
                bytes: media.bytes,
                durationSeconds: nil,
                state: entry.media
            )
        case let .video(media):
            PopopxProfileMediaTile(
                kind: media.kind,
                caption: media.caption,
                bytes: media.bytes,
                durationSeconds: media.durationSeconds,
                state: entry.media
            )
        }
    }

    // // MARK: Burn overlay

    private var closingCover: some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(PopopxPalette.brand)
                .accessibilityHidden(true)
            Text(model.isBurned ? Copy.burnedTitle : Copy.closingTitle)
                .font(PopopxType.sectionHeader)
                .foregroundStyle(ink)
            if let burnedBy = model.burnedBy {
                Text(burnedBy)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxSurface.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            if model.isCleaning {
                Text(Copy.cleaning)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxSurface.inkTertiary)
            } else if model.localRecordDeleted == false {
                // This must be said: this cell is the only part of the "already burned" claim that may not have been done, and papering over it is the same as
                // making that claim no longer true (same motive as PopopxSecureWindowManager.swift:75-83).
                Text(Copy.burnedWithoutDeletion)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(PopopxMetrics.spaceL)
        .frame(maxWidth: .infinity)
        .background(PopopxSurface.cardFill, in: .rect(cornerRadius: PopopxMetrics.radiusCard, style: .continuous))
        .padding(.horizontal, PopopxMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(backdrop)
        .accessibilityElement(children: .combine)
    }

    // // MARK: Ink

    /// The ink on a security surface must stay constant: those few palette colours flip with colorScheme, in dark mode `onBrand` is close to black,
    /// and in light mode `label` is close to black, so mixing them into the shield gives a screen of "a card that is invisible in one mode".
    /// So this place uses the non-flipping `Color.popopx(_:)` overload (same as the `PopopxSecureSurface` ruling,
    /// PopopxSecureSheetView.swift:421-434）。
    private var ink: Color {
        model.privacyRead ? PopopxSurface.ink : PopopxPalette.label
    }

    private var secondaryInk: Color {
        model.privacyRead ? PopopxSurface.inkSecondary : PopopxPalette.labelSecondary
    }

    private var tertiaryInk: Color {
        model.privacyRead ? PopopxSurface.inkTertiary : PopopxPalette.labelHint
    }
}

/// The reader screen's fixed surface. Same family as `PopopxSecureSurface` but **not the same source**: the top-secret face is a safe's door,
/// while the card face is something consulted over and over, and one set of constants shared by the two would sooner or later let a single change rewrite two features at once.
private enum PopopxSurface {
    static let ink = Color.popopx(0xF4F4F6)
    static let inkSecondary = Color.popopx(0xA6A6B0)
    static let inkTertiary = Color.popopx(0x8A8A94)
    static let cardFill = Color.popopx(light: 0x1A1030, dark: 0x140C26)
}

// // MARK: - Media tiles

/// One media cell. Images are zoomable (reusing the shipped `ZoomableScrollView`, Shared/Views/ZoomableScrollView.swift:12),
/// and video reuses the shipped `VideoPlayerView` (Shared/Views/Helpers/VideoPlayerView.swift:12,
/// the inline precedent being CIVideoView.swift:209) — this feature builds no new player and no new zoomer.
private struct PopopxProfileMediaTile: View {
    /// The height cap of the zoom area: an image two screens tall would push the countdown bar off screen.
    private static let mediaMaxHeight: CGFloat = 420
    private static let mediaMinHeight: CGFloat = PopopxMetrics.space2XL * 3
    /// The video cell reserves its space at 4:3: the export preset is exactly `AVAssetExportPreset640x480` (ProfileStorageManager.swift:332),
    /// so space is reserved at its real ratio instead of guessing a different 16:9.
    private static let videoAspectRatio: CGFloat = 640.0 / 480.0

    let kind: PopopxProfileMedia.Kind
    let caption: String?
    let bytes: Int
    var durationSeconds: Int?
    let state: PopopxProfileReaderMedia

    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            media
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Decoding leaves the main thread: a 2 MiB JPEG should not hold up that frame while the page is being scrolled.
        .task(id: url) { image = await Self.decode(url: url, kind: kind) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var media: some View {
        switch state {
        case .pending:
            placeholder(systemImage: kind == .video ? "play.rectangle" : "photo", note: Copy.loadingMedia)
        case .omitted:
            // A slot saved by the degradation normally never reaches here (the layer above already lays out text only, per `.meshTextOnly`).
            // And if it does get here, no blank cell is drawn but "this device has no original" — which is exactly its fact at this moment.
            placeholder(systemImage: "photo", note: Copy.mediaMissing)
        case let .unavailable(_, reason):
            placeholder(systemImage: "exclamationmark.triangle", note: reason)
        case .image:
            if let image {
                ZoomableScrollView {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, minHeight: Self.mediaMinHeight, maxHeight: Self.mediaMaxHeight)
                .clipShape(.rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous))
            } else {
                placeholder(systemImage: "photo", note: Copy.mediaUnreadable)
            }
        case let .video(url):
            VideoPlayerView(
                player: VideoPlayerView.getOrCreatePlayer(url, false),
                url: url,
                showControls: true
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(Self.videoAspectRatio, contentMode: .fit)
            .clipShape(.rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous))
        }
    }

    @ViewBuilder private var footer: some View {
        let meta = Self.metaText(bytes: bytes, durationSeconds: durationSeconds)
        if let caption, !caption.isEmpty {
            Text(caption)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !meta.isEmpty {
            Text(meta)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelHint)
        }
    }

    private var url: URL? {
        switch state {
        case let .image(url): return url
        case let .video(url): return url
        case .pending, .omitted, .unavailable: return nil
        }
    }

    private func placeholder(systemImage: String, note: String) -> some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            Image(systemName: systemImage)
                .font(PopopxType.title)
                .accessibilityHidden(true)
            Text(note)
                .font(PopopxType.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(PopopxPalette.labelHint)
        .frame(maxWidth: .infinity, minHeight: Self.mediaMinHeight)
        .background(PopopxPalette.separator, in: .rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
    }

    private static func metaText(bytes: Int, durationSeconds: Int?) -> String {
        var parts: [String] = []
        if bytes > 0 { parts.append("\(max(1, bytes / 1_024)) KB") }
        if let durationSeconds { parts.append(PopopxSecureCopy.duration(durationSeconds)) }
        return parts.joined(separator: " · ")
    }

    /// Only images need decoding: the video tracks are pulled by `AVPlayerViewController` itself, and decoding them once more here would just spend memory twice.
    private static func decode(url: URL?, kind: PopopxProfileMedia.Kind) async -> UIImage? {
        guard let url, kind == .image else { return nil }
        return await Task.detached(priority: .utility) {
            UIImage(contentsOfFile: url.path)
        }.value
    }
}

// // MARK: - Copy

private enum Copy {
    static let untitled = NSLocalizedString("Untitled profile page", comment: "reader title fallback")
    static let close = NSLocalizedString("Close", comment: "reader close button")
    static let emptyProfile = NSLocalizedString("This profile page has nothing to show", comment: "reader empty state")
    static let emptyBody = NSLocalizedString("This profile page has no content blocks.", comment: "reader empty state")
    static let emptyTextBlock = NSLocalizedString("(empty text block)", comment: "reader empty block placeholder")
    static let loadingMedia = NSLocalizedString("Reading the original kept on this device…", comment: "reader media placeholder")
    static let mediaMissing = NSLocalizedString("Media not kept on this device: this slot was never written here when the message arrived", comment: "reader media placeholder")
    static let mediaUnreadable = NSLocalizedString("Media not kept on this device: the local file cannot be read", comment: "reader media placeholder")
    static let cleaning = NSLocalizedString("Deleting the local record and the originals…", comment: "reader burn progress")
    static let burnedTitle = NSLocalizedString("Burned after reading", comment: "reader closing sheet title")
    static let closingTitle = NSLocalizedString("Closing", comment: "reader closing sheet title")
    static let burnedWithoutDeletion = NSLocalizedString("The plaintext and the originals were cleared, but this device's message row could not be deleted; open the chat again to confirm", comment: "reader burn warning")
    static let burnedByClockRewound = NSLocalizedString("This device's clock was changed; the content was destroyed", comment: "reader burn reason")
    static let antiSpyOffNote = NSLocalizedString("This profile page does not use the front camera watch; only screenshot and screen recording detection stay on.", comment: "reader privacy note")

    /// The Cabin degradation sentence is verbatim copy and may appear in this one place only.
    static func meshOmitted(_ count: Int) -> String {
        String(format: NSLocalizedString("Received offline over the Bluetooth mesh; %lld images or videos were skipped automatically to keep delivery fast with no network", comment: "reader degraded delivery banner"), count)
    }

    static func countdown(_ seconds: Int) -> String { String(format: NSLocalizedString("Burn after reading · %lld seconds left", comment: "reader countdown"), seconds) }
    static func countdownSpoken(_ seconds: Int) -> String { String(format: NSLocalizedString("Burn-after-reading countdown, %lld seconds left", comment: "reader countdown, spoken"), seconds) }
    static func countdownTotal(_ seconds: Int) -> String { String(format: NSLocalizedString("Readable for %@ after opening", comment: "reader countdown total"), PopopxSecureCopy.duration(seconds)) }
}
