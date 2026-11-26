//
//  PopopxTelemetryHeader.swift
//  POPOPX (iOS)
//
//  [Phase 3 · 1] The three-segment top bar navigation.
//
//  Left: identity switcher capsule + brand mark (triple-tap = the second entry point of the panic wipe).
//  Center: the network / Bluetooth dual-mode status capsule.
//  Right: a WeChat-style "+" menu — add friend, start a group chat or encrypted channel, create a public channel, scan, generate a one-time connection link.
//
//  This layer only renders and dispatches: the real clearing, connection setup, and URL planning all live inside the callees, and this file touches none of them.
//  Design values come uniformly from Shared/Theme/PopopxTheme.swift (PopopxPalette / PopopxMetrics / PopopxType /
//  PopopxMaterial); this file contains no raw color value and no raw font size.
//
//  Panic wipe is not reimplemented: the triple-tap detection, the confirmation dialog, and the wipe order all live in `PopopxPanicWipeArming`
//  (PopopxMeshKit/Sources/PopopxMeshUI/PanicWipeManager.swift:360), and the app root has already mounted it once with
//  `PopopxMeshPanicWipeMount` (Shared/Model/POPOPXAPI.swift:4053). The mark in this file merely
//  **second entry point**: forwards the tap into the same state machine, and the confirmation dialog is still presented from that one place at the root - never two alerts
//  competing for the same arming.
//
//  The network tier deliberately does not read `UserNetworkInfo.networkType`: that enum is marked in POPOPXChat/ChatTypes.swift as
//  `@available(*, deprecated, 4.0)`, and its first case itself says "should not happen". Here we use the package's
//  `NetworkStateMonitor` (PopopxMeshKit/Router/NetworkStateMonitor.swift:290) - it is the source of truth for NWPath,
//  and `PopopxNetworkPath.displayText` is already in Chinese, so no second set of wording is needed.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The iron rule forbids scripts from modifying project.pbxproj.
//

import SwiftUI
import PopopxMeshKit
import PopopxMeshUI
import POPOPXChat

// MARK: - Status tiers

/// The semantic tiers of the middle capsule, plus that decision table.
enum PopopxHeaderSignal: Hashable {
    /// No path reading yet: a neutral point, we do not guess on the user's behalf.
    case unknown
    /// The public network is available and the path is clean (Wi-Fi / wired).
    case online
    /// The public network is available but discounted: cellular, restricted (low data mode) or a personal hotspot.
    case degraded(reason: String)
    /// Only BLE near-field is left - it says plainly that the online channel is down.
    case meshOnly(note: String)
    /// Neither side is reachable.
    case offline

    var label: String {
        switch self {
        case .unknown: PopopxTelemetryCopy.unknown
        case .online: PopopxTelemetryCopy.online
        case let .degraded(reason): PopopxTelemetryCopy.onlineDegraded(reason)
        case let .meshOnly(note): note
        case .offline: PopopxTelemetryCopy.offline
        }
    }

    var symbol: String {
        switch self {
        case .unknown: "questionmark"
        case .online: "wifi"
        case .degraded: "wifi"
        case .meshOnly: "antenna.radiowaves.left.and.right"
        case .offline: "wifi.slash"
        }
    }

    /// Colour carries only the channel semantics (§1.1): online and degraded are both SMP and share `brand`, "cellular/restricted" is told apart by the text;
    /// §1.4 clause 4 forbids a permanent green, so the online tier does not use `successInk`, and there is no warning colour at all.
    var tint: Color {
        switch self {
        case .unknown: PopopxPalette.labelHint
        case .online: PopopxPalette.brand
        case .degraded: PopopxPalette.brand
        case .meshOnly: PopopxPalette.meshInk
        case .offline: PopopxPalette.labelSecondary
        }
    }

    /// Only the "near-field" tier breathes: it is a degraded state and needs to be noticed; the other tiers are static facts.
    var isBreathing: Bool {
        if case .meshOnly = self { return true }
        return false
    }

    /// Decision priority: near-field link > no reading > unavailable > discounted online > clean online.
    ///
    /// - Parameter proximityActive: reported by whoever mounts this as "the proximity engine is running right now". Deliberately no global signal bus is built:
    ///   `PopopxProximityEngine` is an `ObservableObject` held by the face-to-face page itself, the header cannot reach it and should not guess,
    ///   so this tier can only be set by the host that holds both ends, calling `PopopxTelemetryModel.update(proximityActive:)` when that page appears/disappears.
    ///   The wiring was completed in the fourth phase: `PopopxProximitySheetModel.begin()`/`finish()` (:64/:69) and
    ///   `shareByTapDrop()` (:101, handing over the period while ranging) write to `PopopxTelemetryModel.shared`.
    /// - Parameter path: nil = not a single NWPath has been read yet.
    static func resolve(proximityActive: Bool, directPeerCount: Int, path: PopopxNetworkPath?) -> PopopxHeaderSignal {
        if proximityActive {
            return .meshOnly(note: directPeerCount > 0
                ? PopopxTelemetryCopy.nearby(directPeerCount)
                : PopopxTelemetryCopy.nearbyOnly)
        }
        guard let path else { return .unknown }
        if !path.isConnected {
            return directPeerCount > 0 ? .meshOnly(note: PopopxTelemetryCopy.meshOnly(directPeerCount)) : .offline
        }
        if path.isExpensive || path.isConstrained || path.interface == .cellular {
            return .degraded(reason: degradedReason(path))
        }
        return .online
    }

    private static func degradedReason(_ path: PopopxNetworkPath) -> String {
        if path.isConstrained { return PopopxTelemetryCopy.lowDataMode }
        switch path.interface {
        case .cellular: return PopopxTelemetryCopy.cellular
        case .wifi: return PopopxTelemetryCopy.personalHotspot
        default: return PopopxTelemetryCopy.restricted
        }
    }
}

// MARK: - Status sources

/// Twists three real sources into a single tier: `NetworkStateMonitor` (public network path), `BluetoothHealthMonitor` (radio),
/// `PopopxMeshStateSource` (direct node count), plus the host reporting that "the proximity engine is running".
///
/// The pure decision lives in `PopopxHeaderSignal.resolve`; this class only subscribes and caches, so that table can be verified on its own, outside SwiftUI.
@MainActor
@Observable
final class PopopxTelemetryModel {
    /// The single process-wide instance of the top bar tier. It exists for exactly one reason: the end that reports "near-field is running" (the face-to-face page) and the end that renders the top bar
    /// (the messages page) are not the same host - the messages page `ChatsListView.swift:189` renders it, while `PopopxProximityAddContactView`
    /// writes it from its `begin()`/`finish()`. Building yet another bus just for it would be the redundant part; the "host that holds both ends" the `resolve` comment asks for
    /// is therefore this one object. `start()` is idempotent (it subscribes only when `pathStream == nil`), so repeated mounts cannot double-subscribe.
    static let shared = PopopxTelemetryModel()

    private(set) var signal: PopopxHeaderSignal = .unknown
    private(set) var radioState: PopopxBluetoothState = .unknown

    private var path: PopopxNetworkPath?
    private var proximityActive = false
    private var directPeerCount = 0
    private var pathStream: Task<Void, Never>?

    /// Written in the method body rather than on a default parameter: `= .shared` evaluates in a non-isolated context and would hit the `@MainActor` Swift 6 isolation error.
    private var mesh: PopopxMeshRuntime { .shared }

    /// Subscribes to public network path changes. Idempotent: if already subscribed it returns straight away, so one stream is never consumed twice.
    func start(runtime: PopopxMeshRuntime? = nil) async {
        guard pathStream == nil else { return }
        let runtime = runtime ?? mesh
        pathStream = Task { [weak self] in
            for await path in await NetworkStateMonitor.shared.pathChanges() {
                self?.apply(path: path)
            }
        }
        await refresh(runtime: runtime)
    }

    func stop() {
        pathStream?.cancel()
        pathStream = nil
    }

    /// Entry point for the near-field tier: called by the host that holds both the top bar and the face-to-face page when that page appears/disappears (see the notes on `resolve`).
    func update(proximityActive: Bool, runtime: PopopxMeshRuntime? = nil) async {
        self.proximityActive = proximityActive
        await refresh(runtime: runtime)
    }

    /// Re-reads the radio and the direct node count.
    ///
    /// `directPeerCount` refreshes only here and on path changes: `PopopxMeshStateSource.state` is observable, it is true,
    /// but attaching another layer of subscription for one capsule would invalidate the whole view tree along with it, which is not worth it.
    /// `BluetoothHealthMonitor` is an actor (`:59`), so this has to be async.
    func refresh(runtime: PopopxMeshRuntime? = nil) async {
        let runtime = runtime ?? mesh
        radioState = await runtime.healthMonitor.currentRadioState
        directPeerCount = runtime.stateSource.state.peers.filter(\.isDirect).count
        recompute()
    }

    private func apply(path: PopopxNetworkPath) {
        self.path = path
        recompute()
    }

    private func recompute() {
        signal = .resolve(proximityActive: proximityActive, directPeerCount: directPeerCount, path: path)
    }
}

// MARK: - Left: identity switching

/// Identity-switch capsule: a plain `Picker` that only writes the selected userId back into the host's binding.
///
/// Deliberately does not call `changeActiveUserAsync_` here: switching the current user makes the api layer reload sessions and rebuild the whole chat view tree,
/// and that is the host's job. `identities` is passed `chatModel.users.map(\.user)`.
struct PopopxIdentitySwitcher: View {
    @Binding var userId: Int64?
    var identities: [User] = []

    var body: some View {
        Picker(selection: $userId) {
            ForEach(identities) { user in
                Text(verbatim: user.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsTightening(false)
                    .tag(Optional(user.userId))
            }
        } label: {
            HStack(spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "person.crop.circle")
                    .font(PopopxType.secondary)
                    .fixedSize()
                Text(verbatim: currentName)
                    .font(PopopxType.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // No letter-spacing tightening, no font-size reduction: a long name may only be truncated. From real-device round 5 onwards this element's footprint in the top bar
                    // is capped by `headerIdentityMaxWidth` (115); the trio is written out in full so that "wrapping" is impossible
                    // structurally at this layer, instead of depending on the width the outer layer hands out.
                    .allowsTightening(false)
                    // Real-device round 9: a cap alone does not stop wrapping. The label of `Picker(.menu)` is laid out on the UIKit side,
                    // so once the outer clamp of 115 reaches the `HStack` it still has to be shared with the symbol and the chevron, and by the time the proposal reaches the text it is already
                    // narrower than the name, while `lineLimit(1)` does not stop line breaks inside a menu label. Here the text's own width is clamped hard:
                    // 115 minus the left/right insets 16×2, the person symbol 18, the chevron 11, two gaps 4×2 = 46pt,
                    // then pinning `fixedSize(horizontal: false, vertical: true)` - vertically it may occupy only one line height,
                    // and any name beyond 46pt is truncated instead of ever making this row taller.
                    .frame(maxWidth: 46, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(PopopxType.microTag)
                    .fixedSize()
                    .opacity(0.7)
            }
            .foregroundStyle(PopopxPalette.label)
            .padding(.horizontal, PopopxMetrics.spaceM)
            .frame(height: PopopxMetrics.space2XL)
            .background(PopopxPalette.card, in: .capsule)
            .overlay {
                Capsule().strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            }
            .contentShape(.capsule)
        }
        .pickerStyle(.menu)
        .accessibilityLabel(PopopxTelemetryCopy.switchIdentity)
        .accessibilityValue(currentName)
    }

    private var currentName: String {
        identities.first { $0.userId == userId }?.displayName ?? PopopxTelemetryCopy.noIdentity
    }
}

// MARK: - Middle: capsules

/// A single status capsule. Also reused on its own, e.g. the Bluetooth health page uses it to show the radio tier.
struct PopopxStatusPill: View {
    let symbol: String
    let text: String
    let tint: Color
    var pulsing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        // The two tiers each have their own outer shape. The previous version had only a single `.frame(height: 48)` plus `minWidth: 32`:
        // so the dot tier was always a capsule 32 wide × 48 high - that is not "squashed out of shape", those dimensions are themselves a vertical ellipse.
        // This tier is now locked to a 32×32 square (`.frame(width:height:)` pins min/ideal/max to the same value,
        // no matter how much the parent layout yields), and the background and stroke switch to a true circle with it.
        Group {
            if dotOnly {
                cluster
                    .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                    .background(PopopxPalette.card, in: .circle)
                    .overlay {
                        Circle().strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
                    }
            } else {
                cluster
                    .padding(.horizontal, PopopxMetrics.spaceM)
                    .frame(height: PopopxMetrics.space2XL)
                    .background(PopopxPalette.card, in: .capsule)
                    .overlay {
                        Capsule().strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
                    }
                    // Real-device round 9, the "outer ring deformed" tier: `.frame(height: 48)` pins only the height while the width still yields to the outer
                    // proposal, so a 48-high capsule could be clamped narrower than the dot + symbol inside it, and the stroke was crushed into a horizontal ellipse.
                    // `fixedSize` clamps this one back to its content width: better that the whole row overflows (`ViewThatFits` first downshifts to the dot tier,
                    // whose 32×32 frame is locked and takes no part in yielding) than that the outer ring be smaller than what it has to enclose.
                    // Does not conflict with the `:364-365` line about "callers must not apply `.fixedSize()` to it again": that one says do not clamp
                    // outside `PopopxDualStatusCapsule`, which would pin the three tiers to the widest one; what is clamped here is inside a single candidate.
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .onAppear { restart() }
        .onChange(of: pulsing) { _, _ in restart() }
        .onChange(of: text) { _, _ in restart() }
    }

    /// The dot-only tier (the wide-screen downgrade tier), whose outer ring is a true circle.
    private var dotOnly: Bool { text.isEmpty }

    /// Content shared by both tiers: status dot + symbol + (only in the labelled tier) a short phrase.
    private var cluster: some View {
        HStack(spacing: PopopxMetrics.spaceXS) {
            Circle()
                .fill(tint)
                .frame(width: PopopxMetrics.spaceXS, height: PopopxMetrics.spaceXS)
                // When the top bar is squeezed narrow by a long nickname, `frame(width:height:)` only clamps down to the smaller proposal, and the 8×8 dot
                // gets crushed into a horizontal ellipse (real-device round 3: the "outer ring deformed" on the network and Bluetooth capsules).
                // `fixedSize` locks only this one dot; the whole cluster still yields under the original rules - see the two corollaries in
                // `PopopxDualStatusCapsule.body` about callers not applying `.fixedSize()` to it again.
                .fixedSize()
                .opacity(dimmed ? 0.45 : 1)
                .scaleEffect(dimmed ? 0.8 : 1)
            Image(systemName: symbol)
                .font(PopopxType.microTag)
                .symbolRenderingMode(.hierarchical)
                .fixedSize()
            if !text.isEmpty {
                Text(verbatim: text)
                    .font(PopopxType.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tint)
    }

    /// The breathing is on only when it genuinely needs to be noticed: under Reduce Motion it goes completely still, not merely shorter.
    private func restart() {
        guard pulsing, !reduceMotion else {
            dimmed = false
            return
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dimmed = true }
    }
}

/// Network capsule + Bluetooth capsule. On narrow screens `ViewThatFits` falls back to the "dots only" version, **the Chinese wording is never truncated**.
struct PopopxDualStatusCapsule: View {
    let network: PopopxHeaderSignal
    let bluetooth: PopopxStatusPill
    let bluetoothSpoken: String

    init(network: PopopxHeaderSignal, radio: PopopxBluetoothState, radioNote: String? = nil) {
        self.network = network
        let words = PopopxDualStatusCapsule.words(for: radio)
        self.bluetoothSpoken = radioNote ?? words
        self.bluetooth = PopopxStatusPill(
            symbol: radio.isUsable ? "radiowaves.right" : "antenna.radiowaves.left.and.right.slash",
            text: words,
            tint: radio.isUsable ? PopopxPalette.meshInk : PopopxPalette.labelHint
        )
    }

    var body: some View {
        // Three tiers: both ends fully labelled → radio falls back to a dot → both ends fall back to dots. The downgrade comes from switching tiers, not from truncating the Chinese wording.
        // The footprints were recomputed on 2026-11-20 after the top bar merged into the first row: fully labelled tier 206, mixed tier 141, double-dot tier 76,
        // and out of 393pt only the 76 tier is left for this cluster (the full row breakdown is in the `PopopxTelemetryHeader` file header),
        // so iPhone portrait always stays on the double dots - the three tiers are not written in vain, wide screens and iPad step back up.
        // Callers must not apply `.fixedSize()` to it again: that turns the proposal into nil, the three tiers always sit on the widest one,
        // and the overflowing HStack is centre-aligned, so both ends get pushed out of the safe area at once (that is where T0 first went red).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PopopxMetrics.spaceS) { networkPill; bluetooth }
            HStack(spacing: PopopxMetrics.spaceS) { networkPill; bluetoothDot }
            HStack(spacing: PopopxMetrics.spaceS) { networkDot; bluetoothDot }
        }
    }

    private var networkPill: some View {
        PopopxStatusPill(symbol: network.symbol, text: network.label, tint: network.tint,
                         pulsing: network.isBreathing)
            .accessibilityLabel(PopopxTelemetryCopy.networkSpoken(network.label))
    }

    private var networkDot: some View {
        PopopxStatusPill(symbol: network.symbol, text: "", tint: network.tint,
                         pulsing: network.isBreathing)
            .accessibilityLabel(PopopxTelemetryCopy.networkSpoken(network.label))
    }

    private var bluetoothDot: some View {
        PopopxStatusPill(symbol: bluetooth.symbol, text: "", tint: bluetooth.tint)
            .accessibilityLabel(PopopxTelemetryCopy.bluetoothSpoken(bluetoothSpoken))
    }

    /// Plain wording for the radio tiers. `unknown` and `resetting` cannot support a conclusion yet, so they get no danger colour.
    static func words(for radio: PopopxBluetoothState) -> String {
        switch radio {
        case .poweredOn: PopopxTelemetryCopy.radioOn
        case .poweredOff: PopopxTelemetryCopy.radioOff
        case .unauthorized: PopopxTelemetryCopy.radioUnauthorized
        case .unsupported: PopopxTelemetryCopy.radioUnsupported
        case .resetting: PopopxTelemetryCopy.radioResetting
        case .unknown: PopopxTelemetryCopy.radioUnknown
        }
    }
}

// MARK: - Right: one-time link

/// One-time connection link.
struct PopopxMintedInvite: Hashable {
    let uri: String
    /// The same invitation with the server address visible, or nil when `uri` never hid one (a short
    /// link). The card only offers the fold when this is set, so the plain path stays exactly as wide.
    var original: String?
}

/// Creates the one-time connection link.
enum PopopxInviteLink {
    /// Uses the app's real interface `apiAddContact(incognito:)` to create a one-time connection, then wraps it in this app's route prefix.
    ///
    /// Deliberately does not call `PopopxOfflineBridge.normalizedInviteLink`: it only validates and normalises, it does not generate links.
    /// - Returns: nil = the connection failed (`apiAddContact` swallows its own errors and returns nil instead of throwing). Callers must give visible feedback and must never fake a link.
    static func mintOneTime(incognito: Bool) async -> PopopxMintedInvite? {
        guard let (link, _) = await apiAddContact(incognito: incognito) else { return nil }
        // A freshly minted invitation has no short link yet, so what comes back names the SMP server
        // that holds the queue. Sealing it here covers the card, the QR and the share sheet at once.
        let form = PopopxInviteShareForm.make(from: link, short: true)
        return PopopxMintedInvite(uri: form.display, original: form.sealed ? form.original : nil)
    }
}

/// The "+" menu. All five items are real: the four that need host context are injected as closures and are **disabled** while unwired,
/// rather than an empty button that looks tappable; the fifth item (the one-time connection link) works on its own and carries no closure.
struct PopopxPlusMenu: View {
    var onAddFriend: (() -> Void)? = nil
    var onStartGroupChat: (() -> Void)? = nil
    var onCreateChannel: (() -> Void)? = nil
    var onScan: (() -> Void)? = nil

    @State private var invite: PopopxMintedInvite?
    @State private var showsInvite = false
    @State private var showsFailure = false
    @State private var isMinting = false

    var body: some View {
        Menu {
            Button(PopopxTelemetryCopy.addFriends, systemImage: "person.badge.plus") { onAddFriend?() }
                .disabled(onAddFriend == nil)
            Button(PopopxTelemetryCopy.startGroup, systemImage: "person.3") { onStartGroupChat?() }
                .disabled(onStartGroupChat == nil)
            Button(PopopxTelemetryCopy.createChannel, systemImage: "antenna.radiowaves.left.and.right") { onCreateChannel?() }
                .disabled(onCreateChannel == nil)
            Button(PopopxTelemetryCopy.scan, systemImage: "qrcode.viewfinder") { onScan?() }
                .disabled(onScan == nil)
            Divider()
            Button {
                Task { await mint() }
            } label: {
                if isMinting {
                    Label(PopopxTelemetryCopy.minting, systemImage: "hourglass")
                } else {
                    Label(PopopxTelemetryCopy.mintLink, systemImage: "link")
                }
            }
            .disabled(isMinting)
        } label: {
            Image(systemName: "plus")
                .font(PopopxType.sectionHeader)
                .foregroundStyle(PopopxPalette.label)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .contentShape(.circle)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(PopopxTelemetryCopy.moreActions)
        .sheet(isPresented: $showsInvite, onDismiss: { invite = nil }) {
            if let invite {
                PopopxQRCardSheet(uri: invite.uri, identityName: PopopxTelemetryCopy.oneTimeLink, originalURI: invite.original)
            }
        }
        .alert(PopopxTelemetryCopy.mintFailedTitle, isPresented: $showsFailure) {
            Button(PopopxTelemetryCopy.dismiss, role: .cancel) {}
        } message: {
            Text(PopopxTelemetryCopy.mintFailedBody)
        }
    }

    private func mint() async {
        guard !isMinting else { return }
        isMinting = true
        defer { isMinting = false }
        guard let minted = await PopopxInviteLink.mintOneTime(incognito: true) else {
            showsFailure = true
            return
        }
        invite = minted
        showsInvite = true
        PopopxHaptics.notice(.success)
    }
}

// MARK: - Brand mark (second entry point for panic wipe)

/// Three taps in a row forward the tap into the panic-wipe state machine; it performs no wipe itself.
///
/// A completed triple only adds one `.heavy` haptic as the confirmation of "armed"; the real wipe must wait for the user to press the
/// destructive button in the confirmation dialog at the root (that path belongs to `PopopxPanicWipeGate`). Nothing is forwarded while the fuse is off - the root has no confirmation dialog mounted then,
/// so arming would become an intermediate state with no way out.
struct PopopxPanicWipeTrigger: View {
    /// It is an entry point only while the fuse is on.
    var isArmed: Bool = PopopxMeshRuntime.shared.isFuseOn

    var body: some View {
        Button {
            guard isArmed else { return }
            if PopopxMeshRuntime.shared.panicWipe.tap() {
                PopopxHaptics.impact(.heavy)
            }
        } label: {
            Image(PopopxBrandAsset.mark)
                .resizable()
                .aspectRatio(contentMode: .fit)
                // 24 visual + 44 hit target. The previous version had 48 visual wrapping a 44 hit target: the outer layer gave 44 while the inner one still laid out at 48,
                // so the mark overflowed 2pt on each side into the row gap, and this row's gap is only 4.
                .frame(width: PopopxMetrics.spaceL, height: PopopxMetrics.spaceL)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("POPOPX")
        .accessibilityHint(PopopxTelemetryCopy.panicHint)
    }
}

// MARK: - Three-section header

/// The three-section top navigation. Use it inside the host's `NavigationStack` (or in any toolbar position).
///
/// 2026-11-20 real-device round 2: this row is the messages page's **first row** (the "Messages" title that used to take a whole row and
/// the `.searchable` drawer were both withdrawn with it, see `chrome` in `ChatsListView.swift`), so the width was computed item by item against iPhone 15 Pro's
/// 393pt, with the rule "take each item's minimum tier, and count the longest identity name as 3 Chinese characters":
/// insets 16×2 = 32, mark 44, identity 104 (`headerIdentityMaxWidth` 115 is a cap, not a footprint),
/// badge 48 (the `compact` tier = 12+24+12, the symbol chip itself 24), dual-mode capsules 76 (the two-dot tier 32 + inner gap 12),
/// "+" 44, six row gaps 4×6 = 24, two `Spacer(minLength: 4)` = 8 - **380 in total, leaving 13pt of slack**.
/// Real-device round 5 recomputed these three figures for the worst case: with the name filling its 115 cap (the previous version used 120) the row's minimum sum is
/// 391, so 393 still has 2pt left - the previous version's figure for this tier was 396, negative 3pt, and those overflowing 3pt were spread over the whole row, which is exactly
/// the step that deformed long nicknames. The dot tier changed from a 32×48 capsule into a 32×32 true circle (its width footprint is unchanged, so this budget needs no recompute).
///
/// Three corollaries, all deliberate design in this version rather than compromises:
/// 1. The top bar's first row **cannot fit any status wording at all**: carrying the word "Online" would need another +65 (445), a labelled badge another +96 (476),
///    and 393pt is not enough for either. So status always travels on the four cues "symbol + colour + stroke + glow", and the words live on the detail page it opens;
///    on wide screens (iPad / landscape) `ViewThatFits` automatically steps back up to the labelled tiers, and this downgrade is exactly the badge's two tiers.
/// 2. The only compressible item is the identity name (it has `lineLimit(1)` + trailing truncation + no letter-spacing tightening), so its
///    `.layoutPriority` is explicitly written as 0, while the mark, the badge, the dual-mode capsules and the "+" all get 2: the order of yielding is
///    declared here rather than decided by accident of width. The previous version gave the priority to the identity, and at 375pt the whole row overflowed with
///    both ends pushed out of the safe area at once (`PopopxDualStatusCapsule`'s comment records the same kind of blow-up at T0).
/// 3. Row gaps drop from `spaceS`(12) to `space2XS`(4), page margins tighten from `spaceL`(24) to `gutter`(16),
///    and the floor of the two `Spacer`s comes down to 4 as well: these three together free 76pt, exactly paying for the 52pt of the newly added brand mark
///    (by the same measure the previous version's row without the mark was 404: 393 was never enough, and the gap was swallowed by the identity name's truncation, so it stayed invisible).
///    16 also happens to line up with the filter bar's `gutter` below, so the first row no longer sits 8pt inside the list content.
struct PopopxTelemetryHeader: View {
    @Binding var currentUserId: Int64?
    var identities: [User] = []
    /// When `telemetry` is supplied it drives everything; `network`/`radio` are the explicit entry points for unit tests and previews without the runtime.
    var telemetry: PopopxTelemetryModel? = nil
    var network: PopopxHeaderSignal = .unknown
    var radio: PopopxBluetoothState = .unknown
    /// The presentation binding for the top-bar badge sheet always comes in from the host page (the messages page passes its own `$badgeSheet`).
    /// No `@State` here: the host already mounts `.popopxBadgeSheets`, and mounting another copy on the top bar would be two sheets on the same chain,
    /// so writing `.detail` while the trial dialog is up gets dropped by the system - the root cause of real-device round 9's "tapping 'Badge details' did nothing".
    @Binding var badgeSheet: PopopxBadgeSheet?
    var onAddFriend: (() -> Void)? = nil
    var onStartGroupChat: (() -> Void)? = nil
    var onCreateChannel: (() -> Void)? = nil
    var onScan: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            // The purple brand mark = the second entry point into the panic wipe. The triple-tap detection and the confirmation dialog both live on the state machine side,
            // and while the fuse is off it is just a graphic (the condition behind `PopopxPanicWipeTrigger.isArmed`).
            PopopxPanicWipeTrigger()
                .layoutPriority(2)
                .accessibilityIdentifier("popopx.header.mark")
            // Priority 0 = an explicit "this is the item in the row that must yield": the identity name truncates itself (`lineLimit(1)` +
            // trailing ellipsis + no letter-spacing tightening), so it shrinks first; the previous version gave it the priority, and at 375pt the whole row overflowed with
            // both ends pushed out of the safe area, see corollary 2 above.
            PopopxIdentitySwitcher(userId: $currentUserId, identities: identities)
                .frame(maxWidth: PopopxMetrics.headerIdentityMaxWidth, alignment: .leading)
                .layoutPriority(0)
                .accessibilityIdentifier("popopx.header.identity")
            Spacer(minLength: PopopxMetrics.space2XS)
            // The middle cluster as a whole is not fixedSize: only when the remaining width really reaches both capsules do their tiers have something to choose between.
            // The badge's two tiers: the labelled one needs 144 (even shortened to "trial 3d 4h"), which 393pt cannot hold, so on iPhone it always
            // falls back to the symbol-only 48; iPad / landscape steps back up to the labelled tier automatically. The status meaning is carried by the solid colour chip + stroke + glow,
            // see the `PopopxBadgeCapsuleView.swift` file header.
            // The tier is chosen here (`ViewThatFits` picks between the two tiers), the sheet presentation is not: `sheet` is passed up to
            // the host page's single `.popopxBadgeSheets`, and the top bar no longer mounts a second sheet of its own.
            // The previous version got both places wrong: a wrapper carrying its own `.sheet` was staged as two candidates, so each tier had its own presentation layer;
            // and keeping only one still coexisted with the host page's, so two sheets sat on the same chain and tapping "Badge details" inside the trial dialog was silently dropped.
            // Real-device round 9's "tapping 'Badge details' did nothing" was exactly this second case.
            PopopxBadgeHeaderEntry(sheet: $badgeSheet)
                .layoutPriority(2)
                .accessibilityIdentifier("popopx.header.badge")
            PopopxDualStatusCapsule(network: signal, radio: radioState)
                .layoutPriority(2)
            Spacer(minLength: PopopxMetrics.space2XS)
            PopopxPlusMenu(onAddFriend: onAddFriend, onStartGroupChat: onStartGroupChat, onCreateChannel: onCreateChannel, onScan: onScan)
                .fixedSize()
                .layoutPriority(2)
                .accessibilityIdentifier("popopx.header.plus")
        }
        // 16 rather than 24: lines up with the filter bar's `gutter` below and hands 8pt back to the status cluster.
        .padding(.horizontal, PopopxMetrics.gutter)
        // The two capsules want 48 themselves: clamping them at 44 left only 34 on screen, and the tap targets shrank with it.
        .frame(height: PopopxMetrics.space2XL)
        .background(PopopxMaterial.bar)
        .accessibilityElement(children: .contain)
    }

    private var signal: PopopxHeaderSignal { telemetry?.signal ?? network }

    private var radioState: PopopxBluetoothState {
        guard let telemetry else { return radio }
        return telemetry.radioState
    }
}

// MARK: - Copy

/// All of the top bar's wording. The source text is the English sentence, and the English sentence is the Key (same convention as `key(_:)` in `PopopxCabinView.swift`):
/// `en.lproj` is not written by convention, a missing entry falls back to the Key itself, which is exactly English; the 16 translation directories each carry their own translation.
///
/// The 2026-11-20 real-device round 2 ruling on leftover Chinese was to **translate only this top bar**, so this file and
/// the short phrases used by the top bar in `PopopxBadgeCapsuleView.swift` go through entries, while the Chinese copy in the rest of the BadgeCredits modules stays as it is.
///
/// Sentences carrying numbers get exactly one placeholder (`%@` or `%d`); where two really are needed they are written as `%1$d ... %2$d`.
/// 16 languages order things differently, so laying out arguments by order of appearance would read "3 days 2 hours" as "2 hours 3 days" in some language.
enum PopopxTelemetryCopy {
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX telemetry header")
    }

    private static func fmt(_ value: String, _ argument: CVarArg) -> String {
        String(format: key(value), argument)
    }

    static let unknown = key("Status unknown")
    static let online = key("Online")
    static let offline = key("Offline")
    static func onlineDegraded(_ reason: String) -> String { fmt("Online · %@", reason) }
    static let lowDataMode = key("Low data mode")
    static let cellular = key("Cellular")
    static let personalHotspot = key("Personal hotspot")
    static let restricted = key("Restricted")
    static func nearby(_ nodes: Int) -> String { fmt("Nearby · %d nodes", nodes) }
    static let nearbyOnly = key("Nearby only")
    static func meshOnly(_ nodes: Int) -> String { fmt("Offline · %d nodes", nodes) }

    static let radioOn = key("Bluetooth")
    static let radioOff = key("Bluetooth off")
    static let radioUnauthorized = key("Bluetooth not allowed")
    static let radioUnsupported = key("Not supported here")
    static let radioResetting = key("Bluetooth resetting")
    static let radioUnknown = key("Bluetooth unknown")

    static func networkSpoken(_ label: String) -> String { fmt("Network: %@", label) }
    static func bluetoothSpoken(_ label: String) -> String { fmt("Bluetooth: %@", label) }

    static let switchIdentity = key("Switch identity")
    static let noIdentity = key("No identity selected")
    static let panicHint = key("Tap three times to clear local nearby data")

    static let addFriends = key("Add friends")
    static let startGroup = key("Start a group chat or an encrypted channel")
    /// Reuses an existing entry: `"Create public channel"` is the same sentence as the `AddChannelView` row button and the old menu title
    /// (already translated as "Create public channel" in `zh-Hans`); this page only moves it from the old menu into the "+".
    static let createChannel = key("Create public channel")
    static let scan = key("Scan")
    static let minting = key("Generating…")
    static let mintLink = key("Create a one-time connection link")
    static let oneTimeLink = key("One-time connection link")
    static let moreActions = key("More actions")
    static let mintFailedTitle = key("The link could not be created")
    static let mintFailedBody = key("Not connected: check the network or try again later.")
    /// Reuses an existing entry: `"OK"` already has a translation in all 17 directories, so no new sentence is invented
    /// (same rule as the reuse lines in `PopopxCabinView.swift` that call `NSLocalizedString("Cancel", ...)` directly).
    static let dismiss = NSLocalizedString("OK", comment: "Telemetry: dismissing the failed invite link")
}

// MARK: - Previews

struct PopopxTelemetryHeaderOnline_Previews: PreviewProvider {
    static var previews: some View {
        PopopxTelemetryHeader(
            currentUserId: .constant(1),
            network: .online,
            radio: .poweredOn,
            badgeSheet: .constant(nil)
        )
        .padding(.vertical, PopopxMetrics.spaceS)
        .background(PopopxPalette.base)
        .preferredColorScheme(.dark)
    }
}

struct PopopxTelemetryHeaderCellular_Previews: PreviewProvider {
    static var previews: some View {
        PopopxTelemetryHeader(
            currentUserId: .constant(1),
            network: .resolve(proximityActive: false, directPeerCount: 0,
                              path: PopopxNetworkPath(isConnected: true, interface: .cellular, isExpensive: true)),
            radio: .poweredOn,
            badgeSheet: .constant(nil)
        )
        .padding(.vertical, PopopxMetrics.spaceS)
        .background(PopopxPalette.base)
    }
}

struct PopopxTelemetryHeaderProximityOnly_Previews: PreviewProvider {
    static var previews: some View {
        PopopxTelemetryHeader(
            currentUserId: .constant(1),
            network: .resolve(proximityActive: true, directPeerCount: 2, path: .unknown),
            radio: .poweredOn,
            badgeSheet: .constant(nil)
        )
        .padding(.vertical, PopopxMetrics.spaceS)
        .background(PopopxPalette.base)
    }
}

struct PopopxTelemetryHeaderBluetoothOff_Previews: PreviewProvider {
    static var previews: some View {
        PopopxTelemetryHeader(
            currentUserId: .constant(1),
            network: .offline,
            radio: .unauthorized,
            badgeSheet: .constant(nil)
        )
        .padding(.vertical, PopopxMetrics.spaceS)
        .background(PopopxPalette.base)
    }
}
