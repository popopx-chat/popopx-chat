//
//  MeshPlazaView.swift
//  PopopxMeshUI
//
//  物理半径内的 `#mesh` 本地离线广场 (铁律 1, 模块 7). Everything on this screen is Bluetooth
//  broadcast traffic and nothing else: no Nostr, no keypair, no geohash 同城频道, no relay, and no
//  public network at all — the plaza is what a room of phones can say to itself when the internet
//  cannot. `PopopxMeshEngine.sendBroadcast(text:)` floods the text unencrypted at the mesh's own TTL
//  and never acknowledges it, which is exactly Bitchat's plaza semantics minus the Nostr half.
//
//  The nickname is local display state: a name the user picks for their own broadcast bubbles. It
//  lives as a file in `Documents/popopx_mesh/` — 铁律 5's sandbox — because it is not a secret and
//  must not become a Keychain item, and because a panic wipe has to take it with the rest of the
//  sandbox. It is handed to the mesh only as the announce payload's display name; nothing on this
//  screen puts it, or any plaza text, on the SMP path.
//

import Combine
import Foundation
import PopopxMeshKit
import SwiftUI

/// One plaza post. `PopopxMeshInbound.messageId` of a broadcast is the mesh's content-derived packet
/// id, which is the only identity a flood has.
public struct PopopxMeshPlazaPost: Identifiable, Hashable, Sendable {
    public enum Author: Hashable, Sendable {
        /// Something this device broadcast.
        case local
        /// A neighbour, by the name it announced, or by its 8-byte wire id when it announced none.
        case neighbour(nickname: String?, peerIDHex: String)
    }

    public let id: String
    public let text: String
    public let timestamp: Date
    public let author: Author
    /// How many hops the flood had taken when this device heard it; 0 for our own post.
    public let hopCount: Int

    public init(
        id: String,
        text: String,
        timestamp: Date,
        author: Author,
        hopCount: Int
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.author = author
        self.hopCount = hopCount
    }

    public var displayName: String {
        switch author {
        case .local: "You"
        case let .neighbour(nickname, peerIDHex): nickname?.isEmpty == false ? nickname! : peerIDHex
        }
    }
}

/// Hop count to a distance a person can picture. Bitchat's own UI quotes a radius rather than a
/// hop count for the same reason; the metres-per-hop figure is this layer's estimate of a BLE
/// Class-2 radio in a building, and it is stated here, once, so nobody has to guess where it came
/// from. It is a label, never a routing input: the mesh's real bound on a flood is the TTL.
public enum PopopxMeshReachEstimate {
    public static let metresPerHop = 30

    public static func metres(hops: Int) -> Int {
        max(0, hops) * metresPerHop
    }

    /// The plaza's scope line: how far a broadcast this device sends can travel.
    public static func radius(hops: Int) -> String {
        let metres = Self.metres(hops: hops)
        return metres >= 1_000
            ? String(format: "%.1f km", Double(metres) / 1_000)
            : "\(metres) m"
    }

    public static func description(hops: Int) -> String {
        "\(hops) hop\(hops == 1 ? "" : "s") · ≈\(radius(hops: hops))"
    }
}

/// The plaza's own state: the local broadcast timeline, the draft, the nickname, and whether the
/// radio can carry anything at all.
@MainActor
public final class PopopxMeshPlazaModel: ObservableObject {
    /// A plaza post is a flood; the same cap as the state mirror keeps one screen bounded.
    public static let maxDraftCharacters = 512

    @Published public private(set) var posts: [PopopxMeshPlazaPost] = []

    @Published public var draft: String = ""

    /// Editable by design: the composer's `TextField` binds here, and `saveNickname()` is what turns
    /// the typed text into persisted, clamped state.
    @Published public var nickname: String

    @Published public private(set) var radioState: PopopxBluetoothState = .unknown

    @Published public private(set) var peers: [PopopxMeshPeer] = []

    /// The last failure the mesh reported for a broadcast, so the composer can say why a post stayed
    /// local. `nil` once a send succeeds.
    @Published public private(set) var lastFailure: PopopxMeshSendFailure?

    @Published public private(set) var isSending = false

    private let outbound: any PopopxMeshOutbound
    private let source: PopopxMeshStateSource
    private let nicknameStore: PopopxMeshNicknameStore
    private let nicknameApplier: (any PopopxMeshNicknameApplying)?
    /// 模块 2's engine floods at `config.ttlDefault`; the plaza shows that as a radius, so the number
    /// comes from the config rather than being retyped here.
    private let ttlHops: Int
    private var pumpTask: Task<Void, Never>?

    public init(
        outbound: any PopopxMeshOutbound,
        source: PopopxMeshStateSource = .shared,
        nicknameStore: PopopxMeshNicknameStore = PopopxMeshNicknameStore(),
        nicknameApplier: (any PopopxMeshNicknameApplying)? = nil,
        ttlHops: Int = Int(PopopxMeshConfig.default.ttlDefault)
    ) {
        self.outbound = outbound
        self.source = source
        self.nicknameStore = nicknameStore
        self.nicknameApplier = nicknameApplier
        self.ttlHops = max(1, ttlHops)
        self.nickname = nicknameStore.read() ?? PopopxMeshNicknameStore.defaultNickname
    }

    public var scopeDescription: String {
        PopopxMeshReachEstimate.description(hops: ttlHops)
    }

    public var neighbourCount: Int { peers.count }

    public var canBroadcast: Bool {
        radioState.isUsable && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Mirrors the mesh's broadcast stream. Idempotent; a plaza opened while the fuse is off simply
    /// shows nothing.
    public func start() {
        guard pumpTask == nil else { return }
        source.start()
        let stream = source.observeState()
        pumpTask = Task { @MainActor [weak self] in
            for await state in stream {
                if Task.isCancelled { break }
                self?.apply(state: state)
            }
        }
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        posts = []
    }

    /// The composer's send. A broadcast that the radio could not take stays visible as a local post —
    /// the plaza has no queue and no acknowledgement by design, so saying so is the whole error
    /// handling it deserves.
    public func broadcastDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let trimmed = String(text.prefix(Self.maxDraftCharacters))
        draft = ""
        isSending = true
        defer { isSending = false }
        do {
            try await outbound.sendBroadcast(text: trimmed)
            lastFailure = nil
            appendLocalPost(trimmed)
        } catch {
            lastFailure = error.failure
            appendLocalPost(trimmed)
            PopopxMeshLog.route.warning(
                "📡 plaza broadcast refused: \(String(describing: error.failure), privacy: .public)"
            )
        }
    }

    /// Saves the nickname to the mesh sandbox and re-applies it to the radio. The engine reads the
    /// advertised name only at `start(nickname:)`, so applying it restarts the mesh — see
    /// `PopopxMeshKillSwitch.setNickname(_:)`.
    public func saveNickname() async {
        let clamped = PopopxMeshNicknameStore.clamped(nickname)
            ?? PopopxMeshNicknameStore.defaultNickname
        nickname = clamped
        try? nicknameStore.write(clamped)
        await nicknameApplier?.applyNickname(clamped)
    }

    /// Reads the nickname back from the sandbox — the round trip a test asserts, and what a host
    /// calls after a panic wipe told it that the directory is gone.
    public func reloadNickname() {
        nickname = nicknameStore.read() ?? PopopxMeshNicknameStore.defaultNickname
    }

    // MARK: - Reduction

    private func apply(state: PopopxMeshStreamState) {
        radioState = state.radioState
        peers = state.peers
        rebuildPosts(from: state.broadcasts)
    }

    private func rebuildPosts(from messages: [PopopxMeshTimelineMessage]) {
        var next: [PopopxMeshPlazaPost] = []
        next.reserveCapacity(messages.count + localPosts.count)
        for message in messages where !message.isControlSignal {
            next.append(
                PopopxMeshPlazaPost(
                    id: message.messageID,
                    text: message.text,
                    timestamp: message.timestamp,
                    author: .neighbour(
                    nickname: message.senderNickname,
                    peerIDHex: message.senderPeerIDHex ?? message.messageID
                ),
                    hopCount: message.channel.hopCount ?? 0
                )
            )
        }
        next.append(contentsOf: localPosts)
        posts = Self.deduped(next)
    }

    /// Our own posts are kept here because the mesh never echoes a broadcast back to its sender:
    /// `PopopxMeshEngine.receive` drops a packet whose sender id is our own, and a plaza that showed
    /// only the neighbours' traffic would look like the composer did nothing.
    private var localPosts: [PopopxMeshPlazaPost] = []

    private func appendLocalPost(_ text: String) {
        let post = PopopxMeshPlazaPost(
            id: "local:\(UUID().uuidString.lowercased())",
            text: text,
            timestamp: .now,
            author: .local,
            hopCount: 0
        )
        localPosts.append(post)
        if localPosts.count > PopopxMeshStateSource.defaultCapacity {
            localPosts.removeFirst(localPosts.count - PopopxMeshStateSource.defaultCapacity)
        }
        rebuildPosts(from: source.state.broadcasts)
    }

    /// Strict dedup on the post id, oldest first, so a text a neighbour flooded twice appears once.
    static func deduped(_ posts: [PopopxMeshPlazaPost]) -> [PopopxMeshPlazaPost] {
        var seen: Set<String> = []
        var out: [PopopxMeshPlazaPost] = []
        for post in posts where seen.insert(post.id).inserted {
            out.append(post)
        }
        return out.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
    }
}

/// Applying a nickname is the kill switch's job; the plaza names it through this so the two do not
/// have to know about each other. `@MainActor`, not `Sendable`: both sides are UI-side objects, and
/// a retroactive `Sendable` conformance declared away from the class is a Swift 6 warning.
@MainActor
public protocol PopopxMeshNicknameApplying {
    func applyNickname(_ nickname: String) async
}

extension PopopxMeshKillSwitch: PopopxMeshNicknameApplying {
    public func applyNickname(_ nickname: String) async {
        await setNickname(nickname)
    }
}

/// The 本地 `#mesh` 广场.
@MainActor
public struct MeshPlazaView: View {
    @ObservedObject private var model: PopopxMeshPlazaModel

    public init(model: PopopxMeshPlazaModel) {
        self.model = model
    }

    /// The one-line mount for a host that has an engine and a fuse at hand.
    public init(
        outbound: any PopopxMeshOutbound = PopopxMeshEngine.shared,
        source: PopopxMeshStateSource = .shared,
        killSwitch: PopopxMeshKillSwitch = .shared
    ) {
        self.init(
            model: PopopxMeshPlazaModel(
                outbound: outbound,
                source: source,
                nicknameApplier: killSwitch
            )
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            timeline
            Divider()
            footer
            composer
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var timeline: some View {
            List {
                Section {
                    if model.posts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No one within Bluetooth range has said anything yet.")
                            Text("This square is local only: what is typed here floods the mesh and never leaves it.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .foregroundColor(.secondary)
                    } else {
                        ForEach(model.posts) { post in
                            bubble(post)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("#mesh")
                        Spacer()
                        Text(PopopxMeshReachEstimate.description(hops: model.posts.last?.hopCount ?? 0))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }

    private func bubble(_ post: PopopxMeshPlazaPost) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(post.displayName)
                        .font(.caption.weight(.semibold))
                    PopopxMeshChannelBadge(channel: .offlineMesh(hopCount: post.hopCount))
                }
                Text(post.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(MeshPlazaView.clock(post.timestamp))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: model.radioState.isUsable ? "antenna.radiowaves.left.and.right" : "wifi.slash")
                .foregroundColor(model.radioState.isUsable ? .orange : .gray)
            Text(
                model.radioState.isUsable
                    ? "\(model.neighbourCount) neighbour(s) · broadcast radius \(model.scopeDescription)"
                    : PopopxMeshBannerModel.radioTitle(model.radioState)
            )
            .font(.caption)
            .foregroundColor(.secondary)
            Spacer()
            if let failure = model.lastFailure {
                Text(MeshPlazaView.words(for: failure))
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.text.rectangle")
                    .foregroundColor(.secondary)
                TextField("Local nickname", text: $model.nickname)
                    .textFieldStyle(.plain)
                Button("Save") {
                    Task { await model.saveNickname() }
                }
            }
            HStack(spacing: 8) {
                TextField("Say something to the room", text: $model.draft)
                    .disabled(!model.radioState.isUsable)
                Button {
                    Task { await model.broadcastDraft() }
                } label: {
                    if model.isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(!model.canBroadcast)
                .accessibilityLabel(Text(verbatim: "Broadcast to #mesh"))
            }
        }
        .padding(12)
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: date)
    }

    /// 模块 4 and 模块 5 speak in failure values; the plaza says them in one line of copy.
    static func words(for failure: PopopxMeshSendFailure) -> String {
        switch failure {
        case .noLinkToPeer: "No link — nothing in range"
        case .linkDropped: "Link dropped"
        case .ttlExhausted: "TTL exhausted"
        case let .oversized(payloadBytes, limitBytes):
            "Too long for one frame (\(payloadBytes) > \(limitBytes))"
        case .noSessionWithPeer: "No session with peer"
        case let .radioUnavailable(state): PopopxMeshBannerModel.radioTitle(state)
        }
    }
}
