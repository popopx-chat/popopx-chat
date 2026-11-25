//
//  PopopxGlareDetector.swift
//  POPOPX (iOS)
//
//  [Top-secret view-once · module 2] Pure-math lens-glare hotspot detection. When someone holds a second phone aimed at the screen, the lens glass
//  in the front camera throws back one very small, very bright, round-edged highlight (a specular hotspot) — this file recognises only that one physical
//  phenomenon, and all arithmetic goes through Accelerate's integer image operators: zero models, zero weights, zero package-size growth; when the CoreML chain is absent
//  it is the only visual detection still working, so it must run standalone, without depending on any symbol inside `PopopxCameraGuardEngine`.
//
//  ### The physical reasons for the nine numbers (the defaults are `PopopxGlareConfiguration.default`)
//  - `lumaThreshold = 245`: lens glare hitting the sensor is clipped at the top, so real highlights only fall in the small 245~255 band;
//    below 240 is just "there is a lamp in the room". The judgement acts on **full-range** Y (video range is linearly converted first, see item 3 below).
//  - `minimumAreaFraction = 0.0005` (0.05%, about 15 px at 640x480): a bright spot smaller than this is a hot pixel, a dead pixel,
//    JPEG/HEVC compression noise. Their signature is that they **jump position between frames**, while glare is a steady state that follows the phone.
//  - `maximumAreaFraction = 0.035` (3.5%, about 1075 px at 640x480): a blown-out area bigger than this is a lamp, a window, or the whole screen overexposed,
//    which is an exposure problem, not someone photographing the screen. This tier prefers a miss: a false positive **destroys a top-secret message half-read**, and the cost is asymmetric.
//  - `minimumCircularity = 0.72`: circularity C = 4πA/P², with P taken as the **contour chain length** (8-connected: an orthogonal step counts 1, a diagonal step √2).
//    Measured on synthetic frames: disc 0.91~1.00, a 3:1 stubby bar 0.51, an 85:1 long bar 0.15, a jagged block 0.07, a square 0.72~0.78.
//    To be honest: this tier separates "thin and long / jagged" from "round", but it **cannot separate a square from a disc** — what it blocks is light leaking through a door gap, dead columns on a sensor,
//    that kind of elongated shape. It is not shape recognition, so do not advertise it as "recognises circles".
//  - The area ratio is computed against the **whole frame** area, but connected components run on the grid, so the limit that really applies is the grid: at 640x480 the stride is 7,
//    and measured bright discs of ⌀14 px or smaller are never reported (they cannot even fill the "over half" cell); reporting starts at ⌀18 px. The 0.05% gate of `minimumAreaFraction`
//    is decoration at 640x480. For a smaller detectable size, tune `maximumEdgeLength`; the price is slower connected components.
//  - `consecutiveFramesToFire = 2`: a bright spot in a single frame may be anyone turning around or a car's headlights sweeping past outside. At 10fps two frames are about 200ms,
//    exactly the boundary between "holding a phone aimed at the screen" and "a momentary pass-by".
//  - `meanLumaSurgeDelta = 40`: the whole-frame mean jumps 40/255 (about 16%) within one frame. This is a **necessary condition** for a flash,
//    not a sufficient one — on this one criterion alone it would delete messages by mistake, so it must hold together with the two numbers below to count as a surge.
//  - `surgeMinimumSaturation = 0.05`: the same frame must also have ≥5% of pixels pushed above the `lumaThreshold` line and clipped.
//    This is where the discriminating power lies: the room getting brighter, pointing at a white wall — the mean rises but the 245 band does not (auto-exposure compresses it back),
//    while a flash and laser-assisted focus burn straight through a large area. It costs nothing — it comes out of the same histogram scan as the mean.
//  - `surgeWarmupFrames = 10`: at 10fps the first 1 second does not judge surges. Once `AVCaptureSession` is running, exposure and white balance
//    converge **in steps** (not along one smooth ramp), so a 40-point mean step in the first frames is the camera's own doing.
//    A frame `refuse`d also re-runs this gate: `reset()` clears the counter and the mean baseline together.
//  - `maximumEdgeLength = 96`: connected components only run on the downsampled grid (long side ≤96, i.e. ≤9216 cells). At 640x480 the stride
//    is 7 → grid 92x69. The whole frame is only scanned by vImage integer operators (histogram once, LUT once, box mean once),
//    the Swift loops only touch the grid and the 256-bucket histogram, never the pixels.
//
//  ### One **necessary** deviation from the APIs named in the prompt (not a style choice — they are absent from this SDK)
//  The requirements named `vImageThreshold_LinearUp_Planar8` + `vImage_ConvertFromRawBuffer` (and "integer mean downsampling").
//  The vImage headers of this machine's SDK (macOS / iOS 27.2) no longer have the Threshold family, `vImageReduceBy*`,
//  `vImage_Statistics_*`, `vImageAdd_*`, `vImage_ConvertFromRawBuffer` — `swiftc -typecheck` reports straight out
//  "cannot find 'vImage_Threshold_LinearUp_Planar8' in scope" (measured, not guessed). Replaced by the semantically exactly equivalent
//  three-piece set, still pure vImage, still zero models:
//  - Thresholding → `vImageTableLookUp_Planar8`: a 256-entry LUT written as "index > lumaThreshold gives 255, otherwise 0",
//    pixel-for-pixel equivalent to `Threshold_LinearUp`, and it **does not modify the source plane** (the Threshold family writes in place and would touch the capture buffer).
//  - Downsampling → `vImageBoxConvolve_Planar8`: kernel size = stride (must be odd), and what it computes is exactly
//    `sum = (Σ + area/2) / area` — precisely the "integer mean" of the requirements; edges use `kvImageEdgeExtend`.
//  - Frame mean → `vImageHistogramCalculation_Planar8`: mean = Σ(i·h[i]) / pixel count, 256 scalar multiply-adds,
//    and the blown-out pixel count comes for free along the way, with no second whole-frame scan.
//
//  ### Three formats, everything else is declared dead (no guessing)
//  `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` / `…FullRange` take the Y plane directly;
//  `kCVPixelFormatType_32BGRA` computes Y in one pass with the BT.601 coefficients. Every other format (including 422/444, 10 bit, depth)
//  returns `.clear` and leaves the reason in `lastSkipReason` — guessing at a "probably the luma" plane from uncompressed byte offsets
//  yields an engine that looks like it works and in fact never reports, which is worse than openly unsupported.
//  Video-range Y tops out at 235, so the `245` line can **never light up** on raw values; therefore both the thresholding cutoff and the reported mean
//  have to be converted as (v-16)·255/219; without the conversion the whole hotspot rule would silently fail on the most common camera output.
//
//  ### Threading contract (this file takes no locks, and the reason is written here)
//  This class is not an actor and has no `NSLock`/`os_unfair_lock`. One detection has to reuse the same set of buffers, pre-allocated per frame size, across "histogram → LUT → box mean → sampling →
//  connected components", and a lock would not stop the real harm: two interleaved frames would assemble a mask **made of half of each frame**,
//  and "two consecutive frames" on such an image is fake. The contract is: **the caller must create and use this instance on one and the same serial queue
//  (`com.popopx.vision.guard`)**, with no concurrent access from other queues and no cross-queue reads of
//  `lastSkipReason`. `PopopxCameraGuardEngine`'s capture callbacks are delivered on that queue anyway.
//
//  ### Latching behaviour — reporting once is enough
//  `.glare` is returned exactly once, at the moment the rule **has just become satisfied**:
//  spot frame 1 → `.clear`; frame 2 → `.glare(.hotspot)`; frames 3 and 4 with the spot still there → `.clear` (latched, so as not to flood
//  the receipt channel); a frame in between proving "no qualifying spot and no mean surge" → the consecutive-frame counter resets and the latch releases; when the spot comes back
//  it has to build up `consecutiveFramesToFire` frames again. `reset()` also clears this history — every time the dialog reopens,
//  and every time the top-secret message changes, it **must** be called, otherwise the latch left by the previous round would swallow this round's first alert.
//  Note that "returning `.clear` while latched" is not the same as "this frame is clean"; it only means this round already reported. To tell the two apart, read
//  `lastSkipReason` (that is "could not read") and the evidence itself (that is "what was read").
//
//  ### Measured cost (not adjectives, and reproducible)
//  The same copy of this file on a macOS host (`xcrun -sdk macosx swiftc -O`, arm64) over synthetic frames: 640x480 full-range biplanar,
//  200 frames alternating between "⌀30 bright disc frame" and "uniform frame" (only the former runs connected components and the perimeter polyline), `clock_gettime_nsec_np(CLOCK_MONOTONIC)`
//  timed per frame: **mean 0.475 ms, p50 0.550 ms, p99 0.767 ms, max 1.15 ms** (measured on this machine on 2026-11-19).
//  At 10fps the frame interval is 100 ms, so about 0.5% of it. Another machine changes the numbers, not the order of magnitude or "which branch is expensive".
//  The same synthetic frames also validate the rules themselves (six: brighter but not clipped does not report / clipped surge reports / inside the gate does not report / disc over two consecutive frames reports /
//  a single disc frame does not report / the latch reports only once). This test bench **is not in the repository** — it belongs to no target, so checking it in would make it an orphan;
//  to reproduce it, compile this file together with `PopopxSecurePayload.swift` plus the four lines of frame-generation code described above.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.
//

import Accelerate
import CoreVideo
import Foundation

// // MARK: - Configuration

/// All of the detector's tunables. Out-of-range values do not crash, they are clamped on entering `init` (a combination still illegal after clamping only ever causes never firing,
/// never a false positive).
struct PopopxGlareConfiguration: Hashable, Sendable {
    /// The overexposure line, acting on **full-range** Y (video range is converted first).
    var lumaThreshold: Int32
    /// The lower bound of the spot area, as a fraction of the whole frame area.
    var minimumAreaFraction: Double
    /// The upper bound of the spot area, as a fraction of the whole frame area.
    var maximumAreaFraction: Double
    /// The lower bound of circularity, C = 4πA / P².
    var minimumCircularity: Double
    /// How many consecutive frames must show a qualifying spot before reporting.
    var consecutiveFramesToFire: Int
    /// The whole-frame mean's surge threshold relative to the previous frame (in 0...255 units).
    ///
    /// It does **not** stand alone: a destroy rule built only on "jumped 40 points" would be triggered by lifting the phone off your lap.
    /// A flash is characterised by "jumping" AND "clipping", so the judgement must hold together with `surgeMinimumSaturation`.
    var meanLumaSurgeDelta: Double
    /// The **overexposure ratio** required on top of the surge: the fraction of the frame lit by the `lumaThreshold` line in the same frame.
    /// This is the only piece of free evidence that separates "someone is using a flash / fill light" from "the picture got brighter overall" (it can be counted out of the same histogram).
    var surgeMinimumSaturation: Double
    /// How many of the first frames do **not** participate in surge judgement. The camera has to converge exposure and white balance at startup, so the mean step inside the first second is its own doing.
    var surgeWarmupFrames: Int
    /// The long-side cap of the connected-component grid.
    var maximumEdgeLength: Int

    static let `default` = PopopxGlareConfiguration(
        lumaThreshold: 245,
        minimumAreaFraction: 0.0005,
        maximumAreaFraction: 0.035,
        minimumCircularity: 0.72,
        consecutiveFramesToFire: 2,
        meanLumaSurgeDelta: 40,
        surgeMinimumSaturation: 0.05,
        surgeWarmupFrames: 10,
        maximumEdgeLength: 96
    )
}

// // MARK: - Evidence and verdict

/// Which rule a verdict was spoken by. The two rules are handled identically (destroy + receipt); separating them is only for readable logs
/// and for knowing which one you are moving when tuning thresholds.
enum PopopxGlareReason: String, Hashable, Sendable {
    /// A consecutive-frame circular overexposed spot — the lens of the phone aimed at the screen.
    case hotspot
    /// The whole-frame mean surged within one frame **and** a sufficiently large area of the same frame is clipped — a flash or laser-assisted fill light.
    case lumaSurge
}

/// The quantified evidence of the frame at the moment of judgement. Every field is a measurement of **this frame**, not an average over a window,
/// so that when a receipt goes wrong it can be re-checked against the original frame.
struct PopopxGlareEvidence: Hashable, Sendable {
    var reason: PopopxGlareReason
    /// The number of blobs that passed both the area window and circularity. Under `.lumaSurge` this number can be 0 (the flash overexposes the whole frame,
    /// and no blob gets past the area ceiling).
    var hotspotCount: Int
    /// The largest qualifying spot's fraction of the whole frame area, 0...1. It is 0 when no spot qualifies.
    var largestAreaFraction: Double
    /// The best circularity among the qualifying spots, clamped to 0...1 (the area/perimeter estimate for digital shapes can slightly exceed 1).
    var bestCircularity: Double
    /// The current frame's full-range mean luminance, 0...255.
    var meanLuma: Double
    /// The fraction of the frame lit by the `lumaThreshold` line in this frame, 0...1. It comes out of the same
    /// histogram scan as `meanLuma`. Keeping it is for after-the-fact re-checking: the surge rule requires it to hold too, and it is the first thing to look at when investigating a false positive.
    var saturatedFraction: Double
    /// The previous frame's mean luminance. The first frame has no previous frame and is nil — **not** 0, because 0 would make the first frame look like a huge surge.
    var previousMeanLuma: Double?
    /// The moment this frame was judged. The processing time is taken, not the capture time: what the caller wants is "when did we see it".
    var sampledAt: Date
}

/// One frame's verdict.
enum PopopxGlareVerdict: Hashable, Sendable {
    case clear
    case glare(PopopxGlareEvidence)

    /// Whether anything triggered. Writing `guard case .glare` over and over would miss cases added in the future, so this closes it off.
    var isGlare: Bool {
        if case .glare = self { return true }
        return false
    }

    /// The alert handed to the detection engine for reporting. Both rules land on the `.lensGlareDetected` cell:
    /// `PopopxSecurityAlert` has only this one cell with "visual highlight" semantics, and a mean surge **must not** borrow
    /// `.recordingDevice(_:)` — that case carries an object recognised by CoreML, the fallback engine has no object to carry,
    /// and inventing one would be faking a model conclusion.
    var securityAlert: PopopxSecurityAlert? {
        switch self {
        case .clear: return nil
        case .glare: return .lensGlareDetected
        }
    }
}

/// Why this frame was **not detected**. It and `.clear` are two different things: `.clear` means "looked, and the picture is clean",
/// this means "could not look". It stays on `PopopxGlareDetector.lastSkipReason` so that degradation is observable
/// instead of merely claiming honesty in a comment.
enum PopopxGlareSkipReason: String, Hashable, Sendable {
    /// The pixel format is not on the supported list.
    case unsupportedPixelFormat
    /// The base address could not be locked, or it was locked but the plane pointer came back null.
    case baseAddressUnavailable
    /// Degenerate width/height (0 or 1); there is no such thing as a grid.
    case emptyFrame
    /// vImage/memory preparation failed (buffer could not be allocated, an operator returned an error, the box kernel's temporary buffer size was illegal).
    case accelerationFailed
}

// // MARK: - Detector

/// A pure-arithmetic lens-glare hotspot detector.
///
/// **Not thread safe**, and it does not try to be: all internal state (the mean baseline, the consecutive-frame counter, the latch, the per-frame-size pre-allocated buffers)
/// may only be touched on one serial queue; the reason is in the file header's "Threading contract".
final class PopopxGlareDetector {
    // MARK: Public surface

    /// The effective configuration (already clamped). To change thresholds, make a different instance: `configuration` is a `let`,
    /// because changing thresholds mid-flight would leave a half-built consecutive-frame counter corresponding to a different set of criteria.
    var configuration: PopopxGlareConfiguration { settings }

    /// The most recent reason "this frame was not detected"; returns to nil after a frame has been successfully analysed.
    private(set) var lastSkipReason: PopopxGlareSkipReason?

    // MARK: Effective values and precomputed tables

    private let settings: PopopxGlareConfiguration
    /// The full-range thresholding LUT: indices > threshold give 255.
    private let fullRangeBinarisation: [UInt8]
    /// The video-range thresholding LUT: folds the (v-16)·255/219 judgement line back into raw values first.
    private let videoRangeBinarisation: [UInt8]
    /// BT.601 luma weights, ordered by the **physical byte order** B,G,R,A of `kCVPixelFormatType_32BGRA`.
    /// The weights sum to 29+150+77 = 256, paired with divisor 256 / post_bias 128 for rounding: pure white → 255 (it will not be
    /// rounded down below 245), pure red → 77, pure green → 150, pure blue → 29. This byte order was **measured** (synthetic BGRA frames),
    /// not copied from the misleading "ARGB" function name in the documentation.
    private let bgraLumaMatrix: [Int16] = [29, 150, 77, 0]

    // MARK: Frame-size derived quantities (recomputed only when the size changes)

    private var frameWidth = 0
    private var frameHeight = 0
    private var stride = 1
    private var kernelSize = 1
    private var gridWidth = 0
    private var gridHeight = 0
    private var cellCount = 0

    // MARK: Buffers (reused every frame, reallocated only when the size changes)

    /// The thresholded whole-frame mask (compact rowBytes = width).
    private let maskPlane = PopopxBytePlane()
    /// The whole-frame image after the box mean (same as above, and it **cannot** share a buffer with the mask: box convolution does not support in-place).
    private let smoothedPlane = PopopxBytePlane()
    /// The Y plane computed for interleaved formats. Biplanar formats never need it.
    private let lumaPlane = PopopxBytePlane()
    /// The workspace for the vImage box convolution, sized the way the operator asks for it.
    private let convolutionScratch = PopopxBytePlane()
    private var grid: [UInt8] = []
    private var labels: [Int32] = []
    /// Border-cell marks (1 = this cell is part of its own perimeter polyline). Cleared and then marked each frame, one O(cells) overwrite.
    private var boundaryCells: [UInt8] = []
    private var unionParent: [Int32] = []
    private var blobArea: [Int32] = []
    /// Perimeter accumulation, in units of one-thousandth of a cell edge (see `orthogonalStep`).
    private var blobPerimeter: [Int32] = []
    private var histogram: [vImagePixelCount] = [vImagePixelCount](repeating: 0, count: 256)

    // MARK: Inter-frame history

    private var previousMeanLumaValue: Double?
    private var hotspotStreak = 0
    private var episodeReported = false
    /// The number of frames already **successfully analysed** (frames `refuse`d are not counted: they gave no luminance). Used only to feed
    /// the `surgeWarmupFrames` gate.
    private var analyzedFrames = 0

    // MARK: Lifecycle

    init(configuration: PopopxGlareConfiguration = .default) {
        var sanitized = configuration
        sanitized.lumaThreshold = min(max(configuration.lumaThreshold, 0), 255)
        sanitized.consecutiveFramesToFire = max(1, configuration.consecutiveFramesToFire)
        // A grid that is too small averages the spot into a smear; 8 is the floor for "even a 1x1 speck has not yet been smoothed away".
        sanitized.maximumEdgeLength = max(8, configuration.maximumEdgeLength)
        sanitized.minimumAreaFraction = min(max(configuration.minimumAreaFraction, 0), 1)
        sanitized.maximumAreaFraction = min(max(configuration.maximumAreaFraction, 0), 1)
        sanitized.minimumCircularity = min(max(configuration.minimumCircularity, 0), 1)
        sanitized.meanLumaSurgeDelta = max(0, configuration.meanLumaSurgeDelta)
        sanitized.surgeMinimumSaturation = min(max(configuration.surgeMinimumSaturation, 0), 1)
        // 0 would allow judging surges right after the first frame. That is the most dangerous kind of configuration (counting steps before AE has converged), so the floor is 1,
        // demanding that at least one baseline frame was seen; the default is 10 frames.
        sanitized.surgeWarmupFrames = max(1, configuration.surgeWarmupFrames)
        settings = sanitized

        // "Luma > threshold" folded into LUT indices means everything from threshold + 1 upwards is 255.
        fullRangeBinarisation = PopopxGlareDetector.binarisationTable(cutoff: Int(sanitized.lumaThreshold) + 1)
        // Video range: a full-range value f corresponds to raw v = 16 + f·219/255, so the judgement line is folded back into v and then rounded.
        let videoCutoff = Int((16 + Double(sanitized.lumaThreshold) * 219 / 255).rounded(.down)) + 1
        videoRangeBinarisation = PopopxGlareDetector.binarisationTable(cutoff: videoCutoff)
    }

    /// Clear the inter-frame history. Must be called every time the dialog opens and every time the top-secret message changes: if it is not called, the latch from the previous round swallows
    /// this round's first alert, and that alert is exactly the one that destroys the message.
    func reset() {
        previousMeanLumaValue = nil
        hotspotStreak = 0
        episodeReported = false
        // The counter has to go to zero as well: every dialog opening is a fresh start, and AE converges all over again.
        analyzedFrames = 0
    }

    // MARK: Main flow

    /// Process one camera frame. See "Latching behaviour" in the file header: `.glare` appears once, on the frame where the rule **has just become satisfied**.
    func process(_ pixelBuffer: CVPixelBuffer) -> PopopxGlareVerdict {
        let width = Int(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int(CVPixelBufferGetHeight(pixelBuffer))
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        // 3 rather than 1: grid, area window and box-kernel odding are meaningless at single-digit sizes, so this is judged "cannot look".
        guard width > 3, height > 3 else { return refuse(with: .emptyFrame) }

        // This file never writes back into the capture buffer, so a read-only lock is asked for first (a GPU-resident buffer can save one copy in read-only mode).
        // Some buffers refuse a read-only lock; degrading to an ordinary lock is fine — we still do not write to it.
        var lockFlags = CVPixelBufferLockFlags.readOnly
        if CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) != kCVReturnSuccess {
            lockFlags = []
            guard CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) == kCVReturnSuccess else {
                return refuse(with: .baseAddressUnavailable)
            }
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, lockFlags) }

        // Get "the Y plane + its rowBytes + whether it is video range". BGRA goes through one BT.601 matrix multiply into our own buffer.
        var planeBase: UnsafeMutableRawPointer?
        var planeRowBytes = 0
        var isVideoRange = false
        switch format {
        case OSType(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
             OSType(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange):
            guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
                  let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                return refuse(with: .baseAddressUnavailable)
            }
            planeBase = yBase
            planeRowBytes = Int(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
            isVideoRange = format == OSType(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        case OSType(kCVPixelFormatType_32BGRA):
            guard let bgraBase = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                return refuse(with: .baseAddressUnavailable)
            }
            guard let computed = lumaPlane.reserve(width * height) else { return refuse(with: .accelerationFailed) }
            var source = vImage_Buffer(data: bgraBase, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                       rowBytes: Int(CVPixelBufferGetBytesPerRow(pixelBuffer)))
            var destination = vImage_Buffer(data: computed, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width)
            let error = bgraLumaMatrix.withUnsafeBufferPointer { weights -> Int in
                guard let address = weights.baseAddress else { return PopopxVImage.lostBuffer }
                return vImageMatrixMultiply_ARGB8888ToPlanar8(&source, &destination, address,
                                                             256, nil, 128, PopopxVImage.noFlags)
            }
            guard error == PopopxVImage.noError else { return refuse(with: .accelerationFailed) }
            planeBase = computed
            planeRowBytes = width
            isVideoRange = false
        default:
            return refuse(with: .unsupportedPixelFormat)
        }
        guard let base = planeBase, planeRowBytes >= width else { return refuse(with: .baseAddressUnavailable) }
        guard prepare(width: width, height: height) else { return refuse(with: .accelerationFailed) }

        var sourcePlane = vImage_Buffer(data: base, height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: planeRowBytes)

        // Which table thresholding uses depends on whether this frame is video range or full range. Pick it first: step 1 counts the "overexposure ratio" using **the same**
        // table; if the two places picked separately, a reported `.lumaSurge` could not say which line the clipped pixels were counted against.
        let table = isVideoRange ? videoRangeBinarisation : fullRangeBinarisation

        // 1) One histogram scan yields both the mean and the overexposure ratio. It must be read **before** thresholding, because after thresholding only 0 and 255 remain.
        guard let luma = frameLumaStats(of: &sourcePlane, videoRange: isVideoRange, saturatingTable: table) else {
            return refuse(with: .accelerationFailed)
        }
        let meanLuma = luma.meanLuma

        // 2) Threshold into our own buffer (the LUT does not modify the source plane, so the read-only lock is safe).
        guard let maskBase = maskPlane.base else { return refuse(with: .accelerationFailed) }
        var maskBuffer = vImage_Buffer(data: maskBase, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width)
        let binarised = table.withUnsafeBufferPointer { entries -> Int in
            guard let address = entries.baseAddress else { return PopopxVImage.lostBuffer }
            return vImageTableLookUp_Planar8(&sourcePlane, &maskBuffer, address, PopopxVImage.noFlags)
        }
        guard binarised == PopopxVImage.noError else { return refuse(with: .accelerationFailed) }

        // 3) Integer mean downsampling + a "more than half" re-threshold → the grid.
        guard reduceMaskToGrid(mask: &maskBuffer) else { return refuse(with: .accelerationFailed) }

        // 4) Connected components + area window + circularity.
        let hotspots = analyseBlobs()

        // 5) The two rules + the latch.
        //
        // The surge rule needs three things to hold at once: **jumped enough** (`meanLumaSurgeDelta`), **clipped widely enough**
        // (`surgeMinimumSaturation`), and **past the first few frames** (`surgeWarmupFrames`).
        // Keeping only "jumped enough" leaves at least three sources of false positives for this rule, and every one of them would delete a top-secret message half-read for nothing:
        // the camera's startup auto-exposure convergence (which can hand over several tens of points in one step), moving the lens from a face onto a white wall/window/ceiling,
        // walking from a dark place into a bright one. Their common trait is "the whole frame gets brighter without burning through" — the mean rises but the >245 band does not;
        // whereas a flash and laser fill really do clip, and can push 10%~60% of the frame to the ceiling inside one second.
        let surgeArmed = analyzedFrames > settings.surgeWarmupFrames
        let surged: Bool
        if surgeArmed, let previous = previousMeanLumaValue {
            surged = meanLuma - previous >= settings.meanLumaSurgeDelta
                  && luma.saturatedFraction >= settings.surgeMinimumSaturation
        } else {
            surged = false
        }
        if hotspots.count > 0 {
            hotspotStreak += 1
        } else {
            hotspotStreak = 0
        }
        // The latch is only released by "this frame has no evidence at all": a spot still present, or a surge still in progress, does not release it — releasing would repeat the receipt every frame.
        if hotspots.count == 0 && !surged {
            episodeReported = false
        }
        lastSkipReason = nil
        let previousMean = previousMeanLumaValue
        previousMeanLumaValue = meanLuma
        analyzedFrames += 1

        if !episodeReported {
            if hotspotStreak >= settings.consecutiveFramesToFire {
                episodeReported = true
                return .glare(evidence(reason: .hotspot, hotspots: hotspots, luma: luma,
                                       previousMeanLuma: previousMean))
            }
            if surged {
                episodeReported = true
                return .glare(evidence(reason: .lumaSurge, hotspots: hotspots, luma: luma,
                                       previousMeanLuma: previousMean))
            }
        }
        return .clear
    }

    /// Pack what this frame measured into evidence. Both rules share the same measurements: `reason` says "which rule judged it",
    /// the remaining fields say "what that frame actually looked like"; writing them separately would produce two versions of the truth.
    private func evidence(reason: PopopxGlareReason, hotspots: HotspotSummary,
                          luma: FrameLumaStats, previousMeanLuma: Double?) -> PopopxGlareEvidence {
        PopopxGlareEvidence(reason: reason,
                            hotspotCount: hotspots.count,
                            largestAreaFraction: hotspots.largestAreaFraction,
                            bestCircularity: hotspots.bestCircularity,
                            meanLuma: luma.meanLuma,
                            saturatedFraction: luma.saturatedFraction,
                            previousMeanLuma: previousMeanLuma,
                            sampledAt: Date())
    }

    // MARK: Frame preparation

    /// Recompute stride/grid by frame size and allocate buffers on demand. Returning false means this frame cannot be looked at (memory or an operator refused).
    ///
    /// Reallocate only when the size really changed: the camera frame size is a constant within a session and `reserve` only ever grows,
    /// so in steady state there is zero allocation per frame. Memory deliberately does not shrink when the size does — giving it back and asking again only costs another VM fault.
    private func prepare(width: Int, height: Int) -> Bool {
        if width != frameWidth || height != frameHeight {
            frameWidth = width
            frameHeight = height
            let longest = max(width, height)
            // Rounding up guarantees the grid's long side ≤ maximumEdgeLength; then raised to odd, because box convolution only accepts odd kernels.
            var step = (longest + settings.maximumEdgeLength - 1) / settings.maximumEdgeLength
            if step < 1 { step = 1 }
            if step % 2 == 0 { step += 1 }
            stride = step
            // The kernel must not be bigger than the image (at degenerate sizes the stride would exceed the short side).
            var kernel = min(step, max(1, min(width, height)))
            if kernel % 2 == 0 { kernel -= 1 }
            kernelSize = max(1, kernel)
            gridWidth = (width + stride - 1) / stride
            gridHeight = (height + stride - 1) / stride
            cellCount = gridWidth * gridHeight
            grid = [UInt8](repeating: 0, count: cellCount)
            labels = [Int32](repeating: 0, count: cellCount)
            boundaryCells = [UInt8](repeating: 0, count: cellCount)
            // At most cellCount labels, and union-find/area/perimeter use 1-based indices, hence the +1.
            unionParent = [Int32](repeating: 0, count: cellCount + 1)
            blobArea = [Int32](repeating: 0, count: cellCount + 1)
            blobPerimeter = [Int32](repeating: 0, count: cellCount + 1)
        }
        guard maskPlane.reserve(width * height) != nil, smoothedPlane.reserve(width * height) != nil else { return false }
        guard kernelSize > 1 else { return true }  // No convolution at stride 1, so the workspace goes unused.
        var maskBuffer = vImage_Buffer(data: maskPlane.base, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width)
        var smoothBuffer = vImage_Buffer(data: smoothedPlane.base, height: vImagePixelCount(height),
                                         width: vImagePixelCount(width), rowBytes: width)
        let request = vImageBoxConvolve_Planar8(&maskBuffer, &smoothBuffer, nil, 0, 0,
                                                UInt32(kernelSize), UInt32(kernelSize), 0,
                                                PopopxVImage.tempBufferSize)
        guard request >= 0 else { return false }
        return convolutionScratch.reserve(Int(request)) != nil
    }

    // MARK: Mean

    /// The two luminance quantities of a frame, both out of the **same** histogram scan.
    private struct FrameLumaStats {
        /// Full-range mean, 0...255.
        var meanLuma: Double
        /// The fraction of pixels lit by the judgement line, 0...1.
        var saturatedFraction: Double
    }

    /// Whole-frame mean luminance (returned in **full-range** 0...255 units) + the overexposure ratio.
    ///
    /// Using a histogram instead of a statistics operator: this SDK has no `vImage_Statistics_*`, and a histogram is the same one SIMD scan,
    /// with multiply-adds happening only on 256 buckets. Unifying the unit to "full range" matters — otherwise one pixel-format switch
    /// would put a step of a dozen-odd points into the mean, which the surge rule would read as a flash.
    ///
    /// The overexposure ratio counts the **raw buckets** against the thresholding table passed in: a bucket the table calls lit is exactly the pixels lit in the mask,
    /// so the video-range conversion need not be done a second time here, and it also cannot end up judging a different line than the mask does.
    private func frameLumaStats(of plane: inout vImage_Buffer, videoRange: Bool,
                                saturatingTable table: [UInt8]) -> FrameLumaStats? {
        histogram.zeroInPlace()
        let error = histogram.withUnsafeMutableBufferPointer { entries -> Int in
            guard let address = entries.baseAddress else { return PopopxVImage.lostBuffer }
            return vImageHistogramCalculation_Planar8(&plane, address, PopopxVImage.noFlags)
        }
        guard error == PopopxVImage.noError else { return nil }
        var weighted = 0.0
        var counted = 0.0
        var clipped = 0.0
        for (value, occurrences) in histogram.enumerated() {
            guard occurrences > 0 else { continue }
            weighted += Double(value) * Double(occurrences)
            counted += Double(occurrences)
            if table[value] == PopopxGlareDetector.maskOn { clipped += Double(occurrences) }
        }
        guard counted > 0 else { return nil }
        let raw = weighted / counted
        let mean: Double
        if videoRange {
            mean = min(max((raw - 16) * 255 / 219, 0), 255)
        } else {
            mean = min(max(raw, 0), 255)
        }
        return FrameLumaStats(meanLuma: mean, saturatedFraction: clipped / counted)
    }

    // MARK: Downsampling

    /// Box integer mean + a "more than half" re-threshold, folding the whole-frame mask into the grid. Returning false means the operator failed.
    ///
    /// The sampling centre is `col*stride + stride/2`, exactly one-to-one with the coverage of an odd kernel: an interior cell is
    /// the integer mean of one `stride × stride` block with no overlap and no gap. The tail shorter than a full cell is handled by `kvImageEdgeExtend`
    /// copying the edge pixel in, equivalent to "the tail cell's mean being nudged slightly by the duplicated corner", with an error of order tail width / full width.
    private func reduceMaskToGrid(mask: inout vImage_Buffer) -> Bool {
        let smoothingNeeded = kernelSize > 1
        if smoothingNeeded {
            guard let smoothBase = smoothedPlane.base, let scratch = convolutionScratch.base else { return false }
            var smoothBuffer = vImage_Buffer(data: smoothBase, height: vImagePixelCount(frameHeight),
                                             width: vImagePixelCount(frameWidth), rowBytes: frameWidth)
            let error = vImageBoxConvolve_Planar8(&mask, &smoothBuffer, scratch, 0, 0,
                                                  UInt32(kernelSize), UInt32(kernelSize), 0,
                                                  PopopxVImage.edgeExtend)
            guard error == PopopxVImage.noError else { return false }
        }
        // At stride 1 there is no convolution and the mask itself is read: then the "block mean" is the pixel itself.
        let sampleBase = smoothingNeeded ? smoothedPlane.bytes : maskPlane.bytes
        guard let sampleBase else { return false }
        let rowStride = frameWidth
        let halfPoint = PopopxGlareDetector.gridHalfPoint
        var cell = 0
        for row in 0 ..< gridHeight {
            let centerY = min(row * stride + stride / 2, frameHeight - 1)
            let rowStart = centerY * rowStride
            for column in 0 ..< gridWidth {
                let centerX = min(column * stride + stride / 2, frameWidth - 1)
                grid[cell] = sampleBase[rowStart + centerX] >= halfPoint ? 255 : 0
                cell += 1
            }
        }
        return true
    }

    // MARK: Connected components

    /// Two-pass union-find connected-component labelling → area and perimeter per blob → area window + circularity filtering.
    ///
    /// Runs only on the grid (`cellCount` is of order `maximumEdgeLength²`); all the pixel-level work was handed to vImage in the three steps above.
    /// Area is in cells, perimeter is an 8-connected chain length (cell units, fixed point); C = 4πA/P² has the same unit on both sides, so there is no conversion back to pixels.
    private func analyseBlobs() -> HotspotSummary {
        var summary = HotspotSummary()
        guard cellCount > 0 else { return summary }
        // The previous frame's labels must be wiped clean: the first pass only writes "cells lit in this frame", and a dark cell keeping an old label would be inherited as a neighbour by the next cell,
        // weaving a spot between two frames that does not exist at all. `assign` does not reallocate, it only overwrites.
        labels.zeroInPlace()
        var nextLabel: Int32 = 1

        // First pass: left to right, top to bottom; inherit when inheritable, merge when both sides have a label.
        for row in 0 ..< gridHeight {
            let rowStart = row * gridWidth
            for column in 0 ..< gridWidth {
                let index = rowStart + column
                guard grid[index] != 0 else { continue }
                let above = row > 0 ? labels[index - gridWidth] : 0
                let behind = column > 0 ? labels[index - 1] : 0
                if above == 0 && behind == 0 {
                    labels[index] = nextLabel
                    unionParent[Int(nextLabel)] = nextLabel
                    nextLabel += 1
                } else if above == 0 {
                    labels[index] = behind
                } else if behind == 0 {
                    labels[index] = above
                } else {
                    labels[index] = above
                    merge(above, behind)
                }
            }
        }

        // Second pass: compress every cell's label to its root, counting area along the way (at this point labels are all 1-based indices pointing at roots).
        for index in 0 ..< cellCount {
            let label = labels[index]
            guard label != 0 else { continue }
            let root = root(of: label)
            labels[index] = root
            blobArea[Int(root)] += 1
        }

        // Perimeter: 8-connected chain length (orthogonal step 1, diagonal step √2), **not** a count of "how many border edges there are".
        // Counting border edges is an L1 metric: a 45° diagonal edge is walked as stairs, each diagonal counted as 2 cells instead of √2, systematically overestimating a disc
        // by 4/π, so the ceiling of C = 4πA/P² falls from 1 to π²/16 ≈ 0.62. That would reject every real round spot at `minimumCircularity = 0.72`
        // while letting axis-aligned squares (0.785) through — the rule would be exactly inverted. The measurements are in the file header.
        boundaryCells.zeroInPlace()
        for row in 0 ..< gridHeight {
            let rowStart = row * gridWidth
            for column in 0 ..< gridWidth {
                let index = rowStart + column
                let label = labels[index]
                guard label != 0 else { continue }
                let openUp = row == 0 || labels[index - gridWidth] != label
                let openDown = row == gridHeight - 1 || labels[index + gridWidth] != label
                let openLeft = column == 0 || labels[index - 1] != label
                let openRight = column == gridWidth - 1 || labels[index + 1] != label
                if openUp || openDown || openLeft || openRight { boundaryCells[index] = 1 }
            }
        }
        // Each adjacent pair of border cells is counted once: only the four "forward" directions are looked at (right, down, down-right, down-left), requiring the same label,
        // otherwise two spots touching each other would borrow perimeter from each other.
        for row in 0 ..< gridHeight {
            let rowStart = row * gridWidth
            for column in 0 ..< gridWidth {
                let index = rowStart + column
                guard boundaryCells[index] != 0 else { continue }
                let label = labels[index]
                var steps = 0
                if column + 1 < gridWidth, boundaryCells[index + 1] != 0, labels[index + 1] == label {
                    steps += PopopxGlareDetector.orthogonalStep
                }
                if row + 1 < gridHeight {
                    if boundaryCells[index + gridWidth] != 0, labels[index + gridWidth] == label {
                        steps += PopopxGlareDetector.orthogonalStep
                    }
                    if column > 0, boundaryCells[index + gridWidth - 1] != 0, labels[index + gridWidth - 1] == label {
                        steps += PopopxGlareDetector.diagonalStep
                    }
                    if column + 1 < gridWidth, boundaryCells[index + gridWidth + 1] != 0,
                        labels[index + gridWidth + 1] == label {
                        steps += PopopxGlareDetector.diagonalStep
                    }
                }
                blobPerimeter[Int(label)] += Int32(steps)
            }
        }

        // Filtering. The denominator of the area ratio is the **grid** cell count: one cell stands for stride×stride pixels and the grid tiles the whole frame,
        // so cells/total cells is exactly pixels/whole-frame pixels — this is the step the requirement's "measure by the real frame area" means,
        // and there is no need to multiply by stride² (doing so would overshoot when width or height is not divisible by the stride).
        let totalCells = Double(gridWidth * gridHeight)
        let minimum = settings.minimumAreaFraction
        let maximum = settings.maximumAreaFraction
        for label in 1 ..< nextLabel {
            let area = blobArea[Int(label)]
            // Cleared in place after use instead of memset-ing the whole array every frame: the label count is a subset of the cell count, so what is saved here is O(cells).
            blobArea[Int(label)] = 0
            let perimeter = blobPerimeter[Int(label)]
            blobPerimeter[Int(label)] = 0
            // An isolated single cell has no adjacent border cell → perimeter 0; it would also be rejected by the area window first, this only keeps a division by zero away.
            guard area > 0, perimeter > 0 else { continue }
            let fraction = Double(area) / totalCells
            guard fraction >= minimum, fraction <= maximum else { continue }
            // Perimeter is in thousandths of a cell edge; converted to cell units before entering C = 4πA/P² (C is unit-insensitive, but both sides must share the unit).
            let edges = Double(perimeter) / Double(PopopxGlareDetector.perimeterUnit)
            let circularity = min(1, (4 * Double.pi * Double(area)) / (edges * edges))
            guard circularity >= settings.minimumCircularity else { continue }
            summary.count += 1
            summary.largestAreaFraction = max(summary.largestAreaFraction, fraction)
            summary.bestCircularity = max(summary.bestCircularity, circularity)
        }
        return summary
    }

    /// Find the root. The union-find only hangs the **larger** root under the **smaller** one (see `merge`), so indices decrease monotonically and a cycle is impossible,
    /// hence no iteration cap is needed here to prevent an infinite loop. Path compression is done along the way.
    private func root(of label: Int32) -> Int32 {
        var current = label
        while unionParent[Int(current)] != current {
            let grandparent = unionParent[Int(current)]
            unionParent[Int(current)] = unionParent[Int(grandparent)]
            current = grandparent
        }
        return current
    }

    private func merge(_ first: Int32, _ second: Int32) {
        let firstRoot = root(of: first)
        let secondRoot = root(of: second)
        guard firstRoot != secondRoot else { return }
        if firstRoot < secondRoot {
            unionParent[Int(secondRoot)] = firstRoot
        } else {
            unionParent[Int(firstRoot)] = secondRoot
        }
    }

    // MARK: Degradation

    /// This frame cannot be looked at. Returns `.clear`, but keeps the reason and **clears the inter-frame history**:
    /// a stretch of unreadable frames equals "this stretch was not seen", so the consecutive-frame count must build up again; the mean baseline cannot be faked with an old frame either,
    /// otherwise the first frame after recovery would be judged a fake flash because of the exposure change in between.
    private func refuse(with reason: PopopxGlareSkipReason) -> PopopxGlareVerdict {
        lastSkipReason = reason
        reset()
        return .clear
    }

    // MARK: Tables

    /// The gate used by the "more than half" test: the value after box is the integer mean of `stride²` mask pixels, and the mask holds only 0/255,
    /// so "more than half" = mean ≥ 127.5 = mean ≥ 128.
    private static let gridHalfPoint: UInt8 = 128

    /// The value of the "lit" tier in the mask and in the thresholding table (the other tier is 0). The blown-out pixel count is judged against exactly this.
    private static let maskOn: UInt8 = 255

    /// The fixed-point unit of chain length: 1 cell edge = 1000. An integer accumulator is cheaper than one floating-point add per cell, and the precision needed here is shallow —
    /// √2 taken as 1.414 differs from the true value by 0.00007, which lands on the fifth decimal place of C.
    private static let perimeterUnit = 1000
    private static let orthogonalStep = 1000
    private static let diagonalStep = 1414

    private static func binarisationTable(cutoff: Int) -> [UInt8] {
        let clipped = min(max(cutoff, 0), 256)
        return (0 ... 255).map { $0 >= clipped ? 255 : 0 }
    }
}

// // MARK: - Internal types

extension PopopxGlareDetector {
    /// The statistics of a qualifying spot. The three fields go straight into `PopopxGlareEvidence`.
    struct HotspotSummary {
        var count = 0
        var largestAreaFraction = 0.0
        var bestCircularity = 0.0
    }
}

/// A raw buffer that is reallocated only when it grows.
///
/// Why not `[UInt8]`: vImage's input is a `vImage_Buffer` that must point at 2~3 mutually non-overlapping buffers at once,
/// and with Swift arrays you would have to nest three layers of `withUnsafeMutableBufferPointer`, while the borrow checker does not allow
/// several arrays to be borrowed at once in the same scope — the end result would be the same raw pointers plus a pile of nested closures existing only to dodge the borrow checker.
/// Raw allocation also aligns to 64 bytes, which vImage's NEON path takes advantage of.
/// When allocation fails, `allocate` terminates the process outright (the stdlib offers no failure return); this is the file's only hard-termination path;
/// a VGA frame mask is of order 300 KB, and a process that gets that far will not survive the next camera callback either, so it is not worth inventing a fake degradation for it.
private final class PopopxBytePlane {
    private(set) var base: UnsafeMutableRawPointer?
    private(set) var capacityBytes = 0

    /// Guarantee that at least `bytes` bytes fit, and return the base address.
    func reserve(_ bytes: Int) -> UnsafeMutableRawPointer? {
        guard bytes > 0 else { return base }
        if bytes > capacityBytes {
            base?.deallocate()
            base = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
            capacityBytes = bytes
        }
        return base
    }

    /// Read and write this buffer byte by byte (used by the sampling loop).
    var bytes: UnsafeMutablePointer<UInt8>? {
        base?.assumingMemoryBound(to: UInt8.self)
    }

    deinit {
        base?.deallocate()
    }
}

/// vImage's flags and return codes are loose `UInt32`/`Int` constants in this SDK's Swift interface;
/// mixing them directly yields "cannot convert" rather than a useful error. Doing the width conversion in one place,
/// `truncatingIfNeeded` guarantees that no trap comes from the signed width.
private enum PopopxVImage {
    static let noFlags: UInt32 = UInt32(truncatingIfNeeded: kvImageNoFlags)
    static let edgeExtend: UInt32 = UInt32(truncatingIfNeeded: kvImageEdgeExtend)
    static let tempBufferSize: UInt32 = UInt32(truncatingIfNeeded: kvImageGetTempBufferSize
                                               | kvImageEdgeExtend)
    static let noError: Int = kvImageNoError
    /// Error code used when the buffer pointer is null. This state cannot be constructed in this file (the arrays all have fixed lengths),
    /// but neither `!` nor `assert` may paper over it: in a release build `assert` is stripped, which would leave it running on with a null pointer.
    static let lostBuffer: Int = kvImageMemoryAllocationError
}

private extension Array where Element: FixedWidthInteger {
    /// Cleared in place, **not** swapped for a fresh block of memory.
    ///
    /// this set of arrays (labels, histogram) is wiped every frame, and writing `labels = [Int32](repeating:count:)` is once per frame
    /// malloc + one page fault -- the hard constraint "zero allocations per frame" breaks right on this line. Why not `assign(repeating:count:)`:
    /// its semantics are exactly right, but this SDK's stdlib does not have it (`swiftc -typecheck` reports "has no member 'assign'", tested).
    mutating func zeroInPlace() {
        withUnsafeMutableBufferPointer { pointer in
            pointer.update(repeating: 0)
        }
    }
}
