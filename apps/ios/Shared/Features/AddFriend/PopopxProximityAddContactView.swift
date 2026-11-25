//
//  PopopxProximityAddContactView.swift
//  POPOPX (iOS)
//
//  [Phase 3 · 3] The face-to-face, dual-engine, physical near-field add-friend page.
//
//  Engine A (automatic): `PopopxProximityEngine` uses MultipeerConnectivity to discover and link, and during the handshake it exchanges
//  `NIDiscoveryToken`, then turns on UWB precise ranging; a distance < 0.15 m triggers a `.heavy` haptic, the lexicographically smaller side sends the packet one-way as arbitration,
//  and the silent side, once it receives the link, writes `IdentityMappingStore` directly to complete the friend add and closes this page automatically.
//  Engine B (manual fallback): the "tap-and-pass link" — first `stopProximityLinkEngine()` to yield the ranging, then use the system share sheet
//  (`UIActivityViewController`, AirDrop) to hand over a one-time connection link, and afterwards `resume`.
//
//  The radio mutual exclusion is really implemented: `onAppear` suspends the mesh master switch (`PopopxMeshKillSwitch.setEnabled(false)` →
//  `startEverything`/`stopEverything` all the way down to `PopopxBLETransport`'s `stopScan()` / `stopAdvertising()`,
//  PopopxMeshKit/BLE/PopopxBLETransport.swift:262, :266), and in `onDisappear` **it is restored only if the master switch was already on before we entered**,
//  only then is it restored. After suspending we re-verify with `verifiedActivitySnapshot().isRadioQuiet` and put the conclusion directly on the page —
//  what the red line demands is "the radio really is quiet", not "we called a method".
//
//  Every design value comes from Shared/Theme/PopopxTheme.swift and the controls from Shared/Components/; this file has no bare colour values,
//  no bare font sizes, and no hand-made buttons.
//
//  ⚠️ Availability: `PopopxProximityEngine` is marked `@available(iOS 17.0, *)` in the package (ruling A: Package.swift stays
//  .iOS(.v15)`), so this page carries the same gate; the project uses `$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)` and must not assume ≥17.
//  ⚠️ Xcode project integration: this file must be dragged by hand into the POPOPX (iOS) target (the iron rule forbids scripting changes to project.pbxproj).
//

import SwiftUI
import PopopxMeshKit
import PopopxMeshUI

// MARK: - View model

/// Holds the near-field engine, and is responsible for yielding and returning the BLE.
///
/// The two radio closures deliberately do not capture the `PopopxMeshKillSwitch` instance: the closures of `PopopxProximityRadioHooks` are
/// `@Sendable () async -> Void`, and capturing one fewer reference is one fewer Sendable argument to make, so inside the `@MainActor` methods we
/// take `PopopxMeshRuntime.shared` at the point of use.
@available(iOS 17.0, *)
@MainActor
final class PopopxProximitySheetModel: ObservableObject {
    /// The "radio is quiet" conclusion re-verified after suspending. nil = nothing is suspended right now (not entered yet, or already returned).
    @Published private(set) var radioYielded: Bool?
    /// The "tap-and-pass link" is yielding the ranging and generating the link.
    @Published private(set) var isPreparingTapDrop = false
    @Published private(set) var tapDropError: String?

    /// `lazy` is there so the yield closure can capture `self`: inside `init`, while `self.engine` is not yet initialised, capturing self is not allowed.
    /// The first access happens when the view `init` takes the engine out (see `PopopxProximityAddContactView.init`), still on the main thread.
    lazy var engine: PopopxProximityEngine = PopopxProximityEngine(
        bridge: PopopxMeshRuntime.shared.bridge,
        radio: PopopxProximityRadioHooks(
            suspend: { [weak self] in await self?.yieldMeshRadio() },
            resume: { [weak self] in await self?.returnMeshRadio() }
        )
    )
    let nickname: String?

    private var meshWasOn = false

    init(nickname: String?) {
        self.nickname = nickname
    }

    func begin() async {
        await engine.start(nickname: nickname)
        await reportProximity(true)
    }

    func finish() async {
        await engine.stop()
        await reportProximity(false)
    }

    func retry() async {
        await engine.stop()
        await engine.start(nickname: nickname)
        await reportProximity(true)
    }

    /// The only write point of the top bar's "near field only" state. It reports the engine's real state rather than the page's presence:
    /// true only after entering and `start()` succeeds, false only after leaving and `stop()`, and false for the whole time the ranging is yielded.
    /// It writes `PopopxTelemetryModel.shared` — the message page renders the top bar, and both ends share this one object,
    /// otherwise we would have to invent another global bus (the comment on `resolve` explicitly refused that).
    private func reportProximity(_ active: Bool) async {
        await PopopxTelemetryModel.shared.update(proximityActive: active)
    }

    /// Engine B: yield the ranging → generate a one-time link → hand it to the system share sheet → restore the near field.
    ///
    /// The order is a hard requirement: if the share sheet comes up while ranging is still running, the UWB session fights the sheet for time slices, and users typically linger there a long time,
    /// during which this machine is effectively holding the radio for nothing. `defer` guarantees that a failed share never leaves the near field permanently stopped.
    ///
    /// The link is a link to **my own card** (`incognito: false`): AirDrop is a point-to-point physical handoff, and what the other side is supposed to connect to is this machine's
    /// current identity; an incognito link here would only make both sides connect to the wrong person.
    func shareByTapDrop() async {
        guard !isPreparingTapDrop else { return }
        isPreparingTapDrop = true
        tapDropError = nil
        defer { isPreparingTapDrop = false }

        await engine.stopProximityLinkEngine()
        await reportProximity(false)
        defer {
            Task {
                await self.engine.resume(nickname: self.nickname)
                await self.reportProximity(true)
            }
        }

        guard let invite = await PopopxInviteLink.mintOneTime(incognito: false) else {
            tapDropError = PopopxProximityCopy.tapDropMintFailed
            return
        }
        showShareSheet(items: [invite.uri])
    }

    private func yieldMeshRadio() async {
        let fuse = PopopxMeshRuntime.shared.killSwitch
        meshWasOn = fuse.isEnabled
        guard meshWasOn else {
            // The master switch was already off: nothing needs suspending, but we also do not falsely claim "already yielded".
            radioYielded = fuse.isActiveSnapshot.isRadioQuiet
            return
        }
        await fuse.setEnabled(false)
        radioYielded = (await fuse.verifiedActivitySnapshot()).isRadioQuiet
    }

    private func returnMeshRadio() async {
        defer { radioYielded = nil }
        guard meshWasOn else { return }
        await PopopxMeshRuntime.shared.killSwitch.setEnabled(true)
    }
}

// MARK: - Page

/// The face-to-face add-friend page. Presented as sheet content, and the close button is its own responsibility.
@available(iOS 17.0, *)
struct PopopxProximityAddContactView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var model: PopopxProximitySheetModel
    /// The engine itself is an ObservableObject: only model is observed by SwiftUI, so both have to be held.
    @ObservedObject private var engine: PopopxProximityEngine
    @State private var toast = PopopxToastModel()
    @State private var dismissTask: Task<Void, Never>?

    init(nickname: String?) {
        let created = PopopxProximitySheetModel(nickname: nickname)
        _model = StateObject(wrappedValue: created)
        _engine = ObservedObject(wrappedValue: created.engine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXL) {
            header
            stage
            statusBlock
            Spacer(minLength: PopopxMetrics.spaceM)
            tapDrop
        }
        .padding(PopopxMetrics.spaceXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PopopxPalette.base)
        .popopxToast(toast)
        .onAppear {
            Task { await model.begin() }
        }
        .onDisappear {
            dismissTask?.cancel()
            Task { await model.finish() }
        }
        .onChange(of: engine.didCrossPreciseThreshold) { _, crossed in
            // The engine sets it only the first time 0.15 m is crossed, so this naturally cannot buzz on every frame.
            guard crossed else { return }
            PopopxHaptics.impact(.heavy)
        }
        .onChange(of: engine.phase) { _, phase in
            switch phase {
            case .paired:
                PopopxHaptics.notice(.success)
                toast.show(PopopxProximityCopy.paired, kind: .success)
                dismissTask = Task {
                    try? await Task.sleep(for: PopopxProximityCopy.autoCloseDelay)
                    guard !Task.isCancelled else { return }
                    dismiss()
                }
            case .failed:
                PopopxHaptics.notice(.error)
            default:
                break
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Title

    private var header: some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceM) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(PopopxProximityCopy.title)
                    .font(PopopxType.title)
                    .foregroundStyle(PopopxPalette.label)
                    .accessibilityAddTraits(.isHeader)
                Text(PopopxProximityCopy.subtitle)
                    .font(PopopxType.body)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PopopxMetrics.spaceM)
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                    .contentShape(.circle)
            }
            .accessibilityLabel(PopopxProximityCopy.close)
        }
    }

    // MARK: Radar stage

    @ViewBuilder
    private var stage: some View {
        if engine.supportsPreciseDistance {
            preciseStage
        } else {
            coarseStage
        }
    }

    /// UWB supported: concentric rings + the peer placed directly above at its real distance; closing in = converging upward.
    private var preciseStage: some View {
        GeometryReader { proxy in
            let reach = min(proxy.size.width, proxy.size.height) / 2
            ZStack {
                ForEach(Array(PopopxProximityCopy.ringScales.enumerated()), id: \.offset) { index, scale in
                    Circle()
                        .strokeBorder(PopopxPalette.mesh.opacity(PopopxProximityCopy.ringOpacity(index: index)),
                                      lineWidth: PopopxMetrics.hairline)
                        .frame(width: reach * 2 * CGFloat(scale), height: reach * 2 * CGFloat(scale))
                }
                Circle()
                    .fill(PopopxPalette.meshInk)
                    .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
                if let ratio = peerRatio {
                    PeerMarker(label: peerLabel)
                        // No planar extrapolation: there is only the one straight-up axis, and distance is mapped to a radius ratio.
                        .offset(y: -reach * ratio)
                        .popopxAnimation(PopopxSpring.fluid, value: ratio, reduceMotion: reduceMotion)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(stageAccessibilityLabel)
    }

    /// Precise ranging unsupported (pre-U1 models, the simulator): no fake distance, only the certainty of "currently looking for you".
    private var coarseStage: some View {
        VStack(spacing: PopopxMetrics.spaceL) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(PopopxType.display)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                .foregroundStyle(PopopxPalette.meshInk)
            Text(PopopxProximityCopy.coarseHint)
                .font(PopopxType.body)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PopopxMetrics.space2XL)
        .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard, style: .continuous))
        .accessibilityLabel(PopopxProximityCopy.coarseHint)
    }

    /// Real distance → ring radius ratio. Past `farDistanceMeters` it is shown against the edge, without pretending to be nearer or farther.
    private var peerRatio: CGFloat? {
        guard let distance = engine.distanceMeters else { return nil }
        let limit = max(engine.config.farDistanceMeters, PopopxProximityCopy.minimumReachMeters)
        return min(max(CGFloat(distance / limit), 0), 1)
    }

    private var peerLabel: String {
        engine.peerNickname ?? engine.peerDisplayName ?? PopopxProximityCopy.nearbyPeer
    }

    private var stageAccessibilityLabel: String {
        guard let distance = engine.distanceMeters else { return PopopxProximityCopy.searching }
        return String(format: PopopxProximityCopy.distanceFormat, peerLabel, distance)
    }

    // MARK: Status area

    private var statusBlock: some View {
        PopopxSectionCard(
            footnote: engine.exchange.map { _ in PopopxProximityCopy.exchangeDone }
        ) {
            StatusRow(symbol: engine.phase.popopxStageSymbol,
                      title: phaseWords,
                      note: roleWords,
                      tint: phaseTint)
            StatusRow(symbol: "antenna.radiowaves.left.and.right",
                      title: radioWords,
                      note: rangingNote,
                      tint: radioTint)
            if let failure = engine.failure {
                StatusRow(symbol: "exclamationmark.triangle.fill",
                          title: PopopxProximityCopy.failureHeadline,
                          note: failureWords(failure),
                          tint: .danger)
                PopopxButton(PopopxProximityCopy.retry, systemImage: "arrow.clockwise",
                             role: .secondary, fullWidth: false) {
                    await model.retry()
                }
                .padding(.top, PopopxMetrics.spaceS)
            }
            if let tapDropError = model.tapDropError {
                StatusRow(symbol: "square.and.arrow.up.trianglebadge.exclamationmark",
                          title: PopopxProximityCopy.tapDropErrorHeadline,
                          note: tapDropError,
                          tint: .danger)
            }
        }
        .popopxAnimation(PopopxSpring.snappy, value: phaseWords, reduceMotion: reduceMotion)
    }

    private var phaseWords: String {
        switch engine.phase {
        case .idle: PopopxProximityCopy.idle
        case .starting: PopopxProximityCopy.starting
        case .searching: PopopxProximityCopy.searching
        case .linking: String(format: PopopxProximityCopy.linking, engine.peerDisplayName ?? PopopxProximityCopy.nearbyPeer)
        case .exchanging: PopopxProximityCopy.exchanging
        case .paired: PopopxProximityCopy.paired
        case .stopped: PopopxProximityCopy.stopped
        case .failed: PopopxProximityCopy.failed
        }
    }

    private var phaseTint: PopopxIconTint {
        switch engine.phase {
        case .paired: .success
        case .failed: .danger
        case .linking, .exchanging: .mesh
        default: .neutral
        }
    }

    /// Who sends the packet. "This device receives it quietly" has to be said plainly, otherwise users think it is stuck and keep reopening it.
    private var roleWords: String? {
        switch engine.senderRole {
        case .some(.receiver): PopopxProximityCopy.roleReceiver
        case .some(.sender): PopopxProximityCopy.roleSender
        case .some(.duplicateIdentity), .none: nil
        }
    }

    /// Ranging paused because the distance is too great — the engine has this state, so the page has to state it too.
    private var rangingNote: String? {
        engine.rangingPausedForDistance ? PopopxProximityCopy.rangingPaused : nil
    }

    private var radioWords: String {
        switch model.radioYielded {
        case .some(true): PopopxProximityCopy.radioYielded
        case .some(false): PopopxProximityCopy.radioYieldUnconfirmed
        case .none: PopopxProximityCopy.radioIdle
        }
    }

    private var radioTint: PopopxIconTint {
        switch model.radioYielded {
        case .some(true): .mesh
        case .some(false): .danger
        case .none: .neutral
        }
    }

    private func failureWords(_ failure: PopopxProximityFailure) -> String {
        switch failure {
        case .permissionDenied: PopopxProximityCopy.fPermission
        case let .discoveryUnavailable(reason): PopopxProximityCopy.fDiscovery(reason)
        case let .linkFailed(reason): PopopxProximityCopy.fLink(reason)
        case .remoteClosed: PopopxProximityCopy.fRemoteClosed
        case .nobodyFound: PopopxProximityCopy.fNobody
        case .exchangeTimeout: PopopxProximityCopy.fExchangeTimeout
        case let .unrecognizedFrame(byteCount): PopopxProximityCopy.fFrame(byteCount)
        case let .payloadRejected(reason): PopopxProximityCopy.fPayload(reason)
        case let .inviteMintFailed(reason): PopopxProximityCopy.fMint(reason)
        case let .acceptFailed(reason): PopopxProximityCopy.fAccept(reason)
        case .duplicateIdentity: PopopxProximityCopy.fDuplicate
        case .localIdentityUnavailable: PopopxProximityCopy.fLocalIdentity
        }
    }

    // MARK: Engine B

    private var tapDrop: some View {
        VStack(spacing: PopopxMetrics.spaceS) {
            PopopxButton(
                model.isPreparingTapDrop ? PopopxProximityCopy.tapDropBusy : PopopxProximityCopy.tapDrop,
                systemImage: "shareplay",
                role: .secondary,
                isLoading: model.isPreparingTapDrop
            ) {
                await model.shareByTapDrop()
            }
            Text(PopopxProximityCopy.tapDropFootnote)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelHint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - The peer marker on the radar

@available(iOS 17.0, *)
private struct PeerMarker: View {
    let label: String

    var body: some View {
        VStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: "person.crop.circle.fill")
                .font(PopopxType.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PopopxPalette.brand)
            Text(verbatim: label)
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .lineLimit(1)
                .padding(.horizontal, PopopxMetrics.spaceXS)
                .background(PopopxPalette.card.opacity(0.9), in: .capsule)
        }
        .accessibilityHidden(true)
    }
}

/// The row label in Shared/Components is `private`, so this page ships its own row of the same specification:
/// the same icon size, the same three-segment spacing, no new visual language invented.
@available(iOS 17.0, *)
private struct StatusRow: View {
    let symbol: String
    let title: String
    var note: String?
    let tint: PopopxIconTint

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(spacing: PopopxMetrics.spaceS) {
                Image(systemName: symbol)
                    .font(PopopxType.secondary)
                    .foregroundStyle(tint.ink)
                    .frame(width: PopopxMetrics.spaceXL)
                Text(verbatim: title)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(verbatim: note)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .padding(.leading, PopopxMetrics.spaceXL + PopopxMetrics.spaceS)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stage icon

extension PopopxProximityPhase {
    /// The SF Symbol for each stage. Placed on the app side rather than in the package: the package only owns the state machine, the icon is this version's visual-language decision.
    fileprivate var popopxStageSymbol: String {
        switch self {
        case .idle: "circle"
        case .starting: "rays"
        case .searching: "magnifyingglass"
        case .linking: "link"
        case .exchanging: "envelope.closed.fill"
        case .paired: "checkmark.circle.fill"
        case .stopped: "stop.circle"
        case .failed: "exclamationmark.circle"
        }
    }
}

// MARK: - Copy and geometry

private enum PopopxProximityCopy {
    static let title = NSLocalizedString("Add a friend face to face", comment: "")
    static let subtitle = NSLocalizedString("Get close and it senses the other phone automatically, or tap to link at the bottom", comment: "")
    static let close = NSLocalizedString("Close", comment: "")
    static let nearbyPeer = NSLocalizedString("Nearby person", comment: "")
    static let searching = NSLocalizedString("Looking for a POPOPX nearby", comment: "")
    static let distanceFormat = NSLocalizedString("%1$@, about %2$.2f m away", comment: "")
    static let coarseHint = NSLocalizedString("This device has no precise ranging: stay within 1 metre and the cards exchange themselves once linked", comment: "")
    static let autoCloseDelay = Duration.seconds(1.4)

    static let idle = NSLocalizedString("Getting ready", comment: "")
    static let starting = NSLocalizedString("Turning on the near field", comment: "")
    static let linking = NSLocalizedString("Linked to %@", comment: "")
    static let exchanging = NSLocalizedString("Exchanging encrypted cards", comment: "")
    static let paired = NSLocalizedString("Added as a friend", comment: "")
    static let stopped = NSLocalizedString("Near field stopped", comment: "")
    static let failed = NSLocalizedString("Did not complete", comment: "")
    static let exchangeDone = NSLocalizedString("Cards exchanged", comment: "")

    static let roleSender = NSLocalizedString("This device sends the invitation", comment: "")
    static let roleReceiver = NSLocalizedString("This device only receives it quietly, nothing to do", comment: "")
    static let rangingPaused = NSLocalizedString("Too far apart, ranging paused", comment: "")

    static let radioIdle = NSLocalizedString("Bluetooth is not being used by this page", comment: "")
    static let radioYielded = NSLocalizedString("Bluetooth handed over to face-to-face friend adding", comment: "")
    static let radioYieldUnconfirmed = NSLocalizedString("Handing over Bluetooth is unconfirmed: if nothing happens for a while, close this page and try again", comment: "")

    static let failureHeadline = NSLocalizedString("Face-to-face friend adding did not complete", comment: "")
    static let retry = NSLocalizedString("Retry", comment: "")
    static let tapDrop = NSLocalizedString("Tap-and-pass link", comment: "")
    static let tapDropBusy = NSLocalizedString("Creating the link…", comment: "")
    static let tapDropErrorHeadline = NSLocalizedString("The tap-and-pass link did not go out", comment: "")
    static let tapDropMintFailed = NSLocalizedString("Could not create the link; check your network and try again", comment: "")
    static let tapDropFootnote = NSLocalizedString("When you are too far apart, or the other device has no near field: hand the link over directly with the system share sheet (AirDrop)", comment: "")

    static let fPermission = NSLocalizedString("Bluetooth permission is missing: turn it on in Settings › Privacy & Security › Bluetooth, then try again", comment: "")
    static func fDiscovery(_ reason: String) -> String { String(format: NSLocalizedString("Nearby discovery is unavailable: %@", comment: ""), reason) }
    static func fLink(_ reason: String) -> String { String(format: NSLocalizedString("The near-field link could not be established: %@", comment: ""), reason) }
    static let fRemoteClosed = NSLocalizedString("The other side left the near field", comment: "")
    static let fNobody = NSLocalizedString("No other POPOPX with the near field switched on was found", comment: "")
    static let fExchangeTimeout = NSLocalizedString("The card exchange timed out, move close again", comment: "")
    static func fFrame(_ byteCount: Int) -> String { String(format: NSLocalizedString("Received data it cannot recognise (%lld bytes), discarded", comment: ""), byteCount) }
    static func fPayload(_ reason: String) -> String { String(format: NSLocalizedString("The card content was rejected: %@", comment: ""), reason) }
    static func fMint(_ reason: String) -> String { String(format: NSLocalizedString("Link creation failed: %@", comment: ""), reason) }
    static func fAccept(_ reason: String) -> String { String(format: NSLocalizedString("Accepting the invitation failed: %@", comment: ""), reason) }
    static let fDuplicate = NSLocalizedString("The other device is the same identity as this one", comment: "")
    static let fLocalIdentity = NSLocalizedString("This device has no usable identity; turn on Cabin in Settings first", comment: "")

    /// The ring radius ratios (outer / middle / inner), plus the ones derived from the outer.
    static let ringScales: [Double] = [1.0, 0.66, 0.33]

    /// The further in a ring, the more solid it is: it reads as a "distance scale", not as decoration.
    static func ringOpacity(index: Int) -> Double { 0.3 + Double(index) * 0.2 }

    /// The floor used when `farDistanceMeters` is configured as 0, to avoid dividing the ratio by zero.
    static let minimumReachMeters = 0.01
}

// MARK: - Preview

/// The page body carries an iOS 17 gate, so the preview cannot construct it directly: here is an ungated shell that decides at runtime.
#if DEBUG
struct PopopxProximityPreviewHost_Previews: PreviewProvider {
    static var previews: some View {
        PopopxProximityPreviewHost()
    }
}

private struct PopopxProximityPreviewHost: View {
    var body: some View {
        if #available(iOS 17.0, *) {
            PopopxProximityAddContactView(nickname: nil)
        } else {
            Text(NSLocalizedString("Requires iOS 17 or later", comment: ""))
                .font(PopopxType.body)
                .padding(PopopxMetrics.spaceXL)
        }
    }
}
#endif
