//
//  PopopxMeshKillSwitch.swift
//  PopopxMeshUI
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Red line 28 — the global kill switch. One object owns the decision "is the offline mesh allowed to exist
//  in this process at all", because that decision is the only thing standing between the feature
//  and iron rule 5 (100% zero breakage). Three properties the rest of the package is built around:
//
//  1. The setting is one `Bool` in `UserDefaults`, under `PopopxMeshKillSwitch.enabledDefaultsKey`,
//     which is *the same key* module 1 already models as `IdentityMappingStore.meshEnabled`. There is
//     deliberately no second key: a fuse with two places to be true is a fuse that can be half on.
//  2. Turning it off stops every component the fuse was given — the radio, the monitors, and the
//     UI's own mirror of the event stream — so nothing keeps a `CBCentralManager` scanning, no
//     `Task` keeps a timer running, and no hub subscriber outlives the mesh it watches. With the
//     fuse off the process is the stock POPOPX build again.
//  3. Launch with it off and nothing BLE-related starts at all: `restoreOnLaunch()` reads the key
//     before it touches a component, and a false key means the components are only ever *stopped*
//     (which is safe to call on something that never started) rather than started.
//
//  Whether any BLE work is still running is answerable without a UI: `isActiveSnapshot` reads the
//  fuse's own bookkeeping (synchronous, so a checklist or an assertion can take it anywhere), and
//  `verifiedActivitySnapshot()` cross-checks it against the live event hub's subscriber count.
//

import Combine
import Foundation
import PopopxMeshKit

/// Which half of the mesh a fuse-managed component drives. The distinction is what makes
/// "is the radio quiet" answerable while a UI mirror is still winding down.
public enum PopopxMeshComponentRole: String, Hashable, Sendable {
    /// Touches Bluetooth: the engine, the transport, the health monitor, anything that opens links.
    case radio
    /// Consumes the mesh's events for the interface: state mirrors, timeline, banner.
    case interface
}

/// One component the fuse may start and stop. `PopopxMeshKillSwitch` is the only object allowed to
/// call these, which is what keeps "off means off" from depending on everyone remembering to check.
public protocol PopopxMeshSwitchable: Sendable {
    /// Brings the component up. `nickname` is the plaza's local display name, handed to whoever
    /// advertises it (today `PopopxMeshEngine.start(nickname:)`); conformances that do not
    /// advertise ignore it.
    func meshSwitchDidTurnOn(nickname: String?) async

    /// Takes the component down and leaves it down: safe to call when it was never up.
    func meshSwitchDidTurnOff() async
}

public extension PopopxMeshSwitchable {
    /// A component with nothing to shut down (a pure observer that only reads the mirror) still has
    /// to be told to stop; it just has no radio work to do.
    func meshSwitchDidTurnOn(nickname: String?) async {}
}

/// A component plus the identity the snapshot reports it under.
public struct PopopxMeshSwitchedComponent: Sendable {
    public let name: String
    public let role: PopopxMeshComponentRole
    public let component: any PopopxMeshSwitchable

    public init(name: String, role: PopopxMeshComponentRole, component: any PopopxMeshSwitchable) {
        self.name = name
        self.role = role
        self.component = component
    }
}

/// Where the fuse is, between "nothing is running" and "everything is running".
public enum PopopxMeshFusePhase: String, Hashable, Sendable {
    case off
    case starting
    case on
    case stopping

    public var isRunning: Bool { self == .on || self == .starting }
}

/// The answer to "is any BLE work still running", in a value that can be asserted from anywhere.
public struct PopopxMeshActivitySnapshot: Hashable, Sendable {
    public let phase: PopopxMeshFusePhase
    /// What the persisted key says, independent of what this process has actually started. A
    /// mismatch is a start or stop still in flight — or a crash between the two.
    public let persistedSwitch: Bool
    /// Names of running components that own Bluetooth work.
    public let runningRadioWork: Set<String>
    /// Names of running components that only read the mesh's events.
    public let runningInterfaceWork: Set<String>
    /// Subscribers on the live event hub, or nil when the snapshot came from bookkeeping alone.
    public let eventHubSubscribers: Int?

    public init(
        phase: PopopxMeshFusePhase,
        persistedSwitch: Bool,
        runningRadioWork: Set<String>,
        runningInterfaceWork: Set<String>,
        eventHubSubscribers: Int? = nil
    ) {
        self.phase = phase
        self.persistedSwitch = persistedSwitch
        self.runningRadioWork = runningRadioWork
        self.runningInterfaceWork = runningInterfaceWork
        self.eventHubSubscribers = eventHubSubscribers
    }

    /// Anything mesh-related is still alive.
    public var isActive: Bool {
        phase != .off || !runningRadioWork.isEmpty || !runningInterfaceWork.isEmpty
    }

    /// Bluetooth side completely quiet: no scanning, no broadcast, no links, no timers. This is the property red line 28 promises.
    public var isRadioQuiet: Bool {
        phase == .off && runningRadioWork.isEmpty
    }

    /// Radio quiet *and* no UI mirror holding a subscription: the process behaves like stock POPOPX.
    public var isFullyIdle: Bool {
        isRadioQuiet && runningInterfaceWork.isEmpty && (eventHubSubscribers ?? 0) == 0
    }
}

/// The plaza's local nickname: a display name the user chooses for the offline `#mesh` square, not
/// a secret. That is exactly why it is a file in `Documents/popopx_mesh/` and not a Keychain item —
/// and why module 7's panic wipe takes it out with the rest of the sandbox. It is carried only in the
/// mesh's own announce payload; nothing here hands it to the SMP path.
public struct PopopxMeshNicknameStore: Sendable {
    /// The mesh's own peer nicknames are clamped to 120 characters by module 1; a *display* name the
    /// user picks for a plaza bubble is kept shorter so it survives the announce payload's padding.
    public static let maxCharacters = 32

    /// File name inside the mesh sandbox, chosen by this layer; the sandbox directory itself is
    /// module 1's (`PopopxMeshPaths.meshDirectory()`), so a panic wipe erases this with everything else.
    public static let fileName = "plaza_nickname.json"

    /// The fallback when the user has not chosen one: the same "no name" the plaza shows for peers.
    public static let defaultNickname = "mesh user"

    public let directory: URL

    public init(directory: URL = PopopxMeshPaths.meshDirectory()) {
        self.directory = directory
    }

    public var fileURL: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    /// nil when nothing was ever saved, or the file cannot be read: a nickname is display state, so
    /// a damaged one is treated as absent rather than fatal.
    public func read() -> String? {
        guard let payload = try? PopopxMeshFileStore.read(Payload.self, from: fileURL) else { return nil }
        let clamped = Self.clamped(payload.nickname)
        return clamped?.isEmpty == false ? clamped : nil
    }

    /// Writes the clamped name, or removes the file when the name is blank, so "no nickname" is one
    /// representation instead of three.
    public func write(_ raw: String) throws {
        let clamped = Self.clamped(raw)
        guard let clamped, !clamped.isEmpty else {
            try? PopopxMeshFileStore.remove(fileURL)
            return
        }
        try PopopxMeshFileStore.write(Payload(nickname: clamped, updatedAt: .now), to: fileURL)
    }

    public func clear() {
        try? PopopxMeshFileStore.remove(fileURL)
    }

    /// Trims and cuts on grapheme boundaries so a pasted emoji name cannot be split in half.
    public static func clamped(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxCharacters))
    }

    private struct Payload: Codable, Hashable {
        let nickname: String
        let updatedAt: Date
    }
}

/// Global kill switch.
@MainActor
public final class PopopxMeshKillSwitch: ObservableObject {
    /// The one persisted key of the whole feature: `chat.popopx.mesh.enabled`, the same constant
    /// module 1 exposes as `IdentityMappingStore.meshEnabledDefaultsKey` and reads back as
    /// `meshEnabled`. Off by default, because `UserDefaults.bool` on an absent key is false and a
    /// fuse must not be on just because nobody decided yet.
    public static let enabledDefaultsKey = IdentityMappingStore.meshEnabledDefaultsKey

    /// The live wiring: the core's singletons, in the order the fuse needs them. Nobody has to touch
    /// this — an app that builds its own engine passes its own components to `init`.
    public static let shared = PopopxMeshKillSwitch()

    /// The switch, as the UI sees it. Written to `UserDefaults` before anything is started, so a
    /// crash mid-transition cannot leave a running radio behind an off switch.
    @Published public private(set) var isEnabled: Bool

    @Published public private(set) var phase: PopopxMeshFusePhase = .off

    /// The nickname currently advertised, if any.
    @Published public private(set) var nickname: String?

    @Published private(set) var runningRadioWork: Set<String> = []
    @Published private(set) var runningInterfaceWork: Set<String> = []

    private var components: [PopopxMeshSwitchedComponent]
    private let hub: PopopxMeshEventHub
    private let defaults: UserDefaults
    private let nicknameStore: PopopxMeshNicknameStore
    /// Bumped by every transition. A second flip while the first is still awaiting does not queue
    /// behind it — it supersedes it, because the only answer that matters is the newest one.
    private var generation = 0

    public init(
        engine: any PopopxMeshSwitchable = PopopxMeshEngine.shared,
        healthMonitor: any PopopxMeshSwitchable = BluetoothHealthMonitor.shared,
        pairing: (any PopopxMeshSwitchable)? = nil,
        interface: any PopopxMeshSwitchable = PopopxMeshStateSource.shared,
        hub: PopopxMeshEventHub = .shared,
        defaults: UserDefaults = .standard,
        nicknameStore: PopopxMeshNicknameStore = PopopxMeshNicknameStore()
    ) {
        var declared: [PopopxMeshSwitchedComponent] = [
            PopopxMeshSwitchedComponent(name: "engine", role: .radio, component: engine),
            PopopxMeshSwitchedComponent(name: "healthMonitor", role: .radio, component: healthMonitor)
        ]
        if let pairing {
            declared.append(
                PopopxMeshSwitchedComponent(name: "pairing", role: .radio, component: pairing)
            )
        }
        declared.append(
            PopopxMeshSwitchedComponent(name: "interface", role: .interface, component: interface)
        )
        self.components = declared
        self.hub = hub
        self.defaults = defaults
        self.nicknameStore = nicknameStore
        self.isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        self.nickname = nicknameStore.read()
    }

    // MARK: - Reading the switch

    /// Whether the fuse is on *and* whether it is supposed to be, straight from disk, without
    /// waiting on an actor hop. The settings screen's `@AppStorage` and this cannot disagree.
    public var persistedIsEnabled: Bool {
        defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    /// Bookkeeping only — synchronous, so it can be read from a non-isolated assertion.
    public var isActiveSnapshot: PopopxMeshActivitySnapshot {
        PopopxMeshActivitySnapshot(
            phase: phase,
            persistedSwitch: persistedIsEnabled,
            runningRadioWork: runningRadioWork,
            runningInterfaceWork: runningInterfaceWork,
            eventHubSubscribers: nil
        )
    }

    /// The same snapshot, cross-checked against the event hub: a subscriber left on the hub after
    /// `stop()` is exactly the leak this exists to catch.
    public func verifiedActivitySnapshot() async -> PopopxMeshActivitySnapshot {
        let subscribers = await hub.subscriberCount
        return PopopxMeshActivitySnapshot(
            phase: phase,
            persistedSwitch: persistedIsEnabled,
            runningRadioWork: runningRadioWork,
            runningInterfaceWork: runningInterfaceWork,
            eventHubSubscribers: subscribers
        )
    }

    /// The names the fuse would start, for diagnostics and for the settings page's own footer.
    public var componentNames: [String] {
        components.map(\.name)
    }

    /// Adds a component the host created after the fuse (a second engine, the app-side router).
    /// Calling it while the fuse is on starts the newcomer immediately, so a late registration
    /// cannot become a permanently silent exception.
    public func register(_ component: PopopxMeshSwitchedComponent) async {
        guard !components.contains(where: { $0.name == component.name }) else { return }
        components.append(component)
        guard isEnabled else { return }
        await Self.start(component, nickname: nickname)
        switch component.role {
        case .radio: runningRadioWork.insert(component.name)
        case .interface: runningInterfaceWork.insert(component.name)
        }
    }

    // MARK: - The switch

    /// Called once at launch. Off means off: no component is started, and every component is
    /// *stopped* first anyway, because a switch that was left on by a crashed session must not be
    /// able to leave a half-initialized radio behind.
    public func restoreOnLaunch() async {
        await stopEverything()
        guard isEnabled else {
            phase = .off
            return
        }
        await startEverything()
    }

    /// Turns the fuse on or off. Mid-session is the normal case: the user finds the switch in
    /// `MeshPrivacySettingsView` and flips it without restarting.
    public func setEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        isEnabled = enabled
        if enabled {
            guard phase != .on else { return }
            await startEverything()
        } else {
            await stopEverything()
        }
    }

    /// Tears the mesh down and brings it back up, so a component that never restarts on its own
    /// still sees the new settings. The nickname is the one value read only at start.
    public func restart() async {
        await stopEverything()
        guard isEnabled else { return }
        await startEverything()
    }

    /// Stores the plaza nickname and re-applies it to the mesh. The engine's only entry point for
    /// its advertised name is `start(nickname:)` — there is no update — so changing the name
    /// restarts the mesh: sessions re-handshake on the next send, which is cheap next to the
    /// alternative of a name the user typed that nothing ever shows.
    public func setNickname(_ raw: String) async {
        let clamped = PopopxMeshNicknameStore.clamped(raw) ?? ""
        try? nicknameStore.write(clamped)
        nickname = clamped.isEmpty ? nil : clamped
        guard isEnabled else { return }
        await restart()
    }

    /// Same rule as module 1's `maxNicknameCharacters`: a nickname is clamped, never refused, so a
    /// peer can no longer grow the announce payload by typing.
    public func clearNickname() async {
        nicknameStore.clear()
        nickname = nil
        guard isEnabled else { return }
        await restart()
    }

    // MARK: - Transitions

    /// Interface components subscribe first, so the mirror is listening before the engine publishes
    /// its very first radio state.
    private func startEverything() async {
        generation += 1
        let mine = generation
        phase = .starting
        let ordered = components.sorted { Self.roleOrder($0.role) < Self.roleOrder($1.role) }
        for component in ordered {
            guard mine == generation else { return }
            await Self.start(component, nickname: nickname)
            guard mine == generation else { return }
            switch component.role {
            case .radio: runningRadioWork.insert(component.name)
            case .interface: runningInterfaceWork.insert(component.name)
            }
        }
        guard mine == generation else { return }
        phase = .on
        PopopxMeshLog.route.notice("🔌 mesh fuse on — \(ordered.count, privacy: .public) component(s)")
    }

    /// The radio goes down first: nothing should be delivering events to a mirror of a mesh that is
    /// already stopped, and a mirror that outlives its radio is the leak `isFullyIdle` looks for.
    private func stopEverything() async {
        guard !runningRadioWork.isEmpty || !runningInterfaceWork.isEmpty || phase != .off else { return }
        generation += 1
        let mine = generation
        phase = .stopping
        let ordered = components.sorted { Self.roleOrder($0.role) > Self.roleOrder($1.role) }
        for component in ordered {
            await component.component.meshSwitchDidTurnOff()
            runningRadioWork.remove(component.name)
            runningInterfaceWork.remove(component.name)
        }
        guard mine == generation else { return }
        phase = .off
        PopopxMeshLog.route.notice("🧯 mesh fuse off — radio quiet")
    }

    private static func start(_ component: PopopxMeshSwitchedComponent, nickname: String?) async {
        await component.component.meshSwitchDidTurnOn(nickname: nickname)
    }

    private static func roleOrder(_ role: PopopxMeshComponentRole) -> Int {
        switch role {
        case .interface: 0
        case .radio: 1
        }
    }
}

// MARK: - Core conformances

// The three actors module 3/4/6 already provide, told how to obey the fuse. These are the binding
// points of this layer: nothing here adds state, each just calls the lifecycle method the actor
// already has. `PopopxMeshEngine` and `BluetoothHealthMonitor` are the package's singletons;
// `ManualPairingManager` has none (module 3 needs the app's chat core), so the host constructs it and
// hands it to `PopopxMeshKillSwitch.init(pairing:)`.

extension PopopxMeshEngine: PopopxMeshSwitchable {
    public func meshSwitchDidTurnOn(nickname: String?) async {
        await start(nickname: nickname)
    }

    public func meshSwitchDidTurnOff() async {
        await stop()
    }
}

extension BluetoothHealthMonitor: PopopxMeshSwitchable {
    public func meshSwitchDidTurnOn(nickname: String?) async {
        await start()
    }

    public func meshSwitchDidTurnOff() async {
        stop()
    }
}

extension ManualPairingManager: PopopxMeshSwitchable {
    public func meshSwitchDidTurnOn(nickname: String?) async {
        await startObserving()
    }

    public func meshSwitchDidTurnOff() async {
        stopObserving()
    }
}
