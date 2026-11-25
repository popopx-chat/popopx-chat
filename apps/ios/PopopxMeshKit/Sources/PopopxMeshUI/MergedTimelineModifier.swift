//
//  MergedTimelineModifier.swift
//  PopopxMeshUI
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  module 7's merged-rendering component. The mesh's private messages have to appear in the same ordered timeline as
//  the chat history, with control signalling (`SYS_POPOPX_REQ:`, `SYS_POPOPX_ACK:`, `BLE_ACK:`)
//  filtered out, one row per global `messageId`, and a badge that says which way the text travelled:
//  Blue shield = SMP public network, orange ripple + hop count = Bitchat offline, grey clock = awaiting relay.
//
//  red line "zero-breakage UI mounting" (POPOPX_MESH_PROMPT.md section 1.5) forbids rewriting `ChatView`, so this is a
//  `ViewModifier`: the app's own list stays the
//  app's own list, and the rows the app does not have yet are inserted through the safe area. The
//  full merged order is still computed and published, so the day the app adopts the timeline
//  natively it reads the same rows — `PopopxMeshTimelineMerger` is not SwiftUI and has no idea how
//  they are drawn.
//
//  The merge itself runs on Combine (`app ⨯ offline ⨯ awaiting-relay`, one reduce per change), never
//  in `body`.
//

import Combine
import Foundation
import PopopxMeshKit
import SwiftUI

// MARK: - Channels

/// Which way a message travelled, and therefore which badge it gets.
public enum PopopxMeshTimelineChannel: Hashable, Sendable {
    /// Blue shield: the POPOPX SMP server carried it.
    case smpPublicNetwork
    /// Orange ripple + hop count: the offline Bluetooth mesh carried it, this many hops away.
    case offlineMesh(hopCount: Int)
    /// Grey clock: handed off, no acknowledgement yet — waiting for a relay to take it.
    case awaitingRelay

    /// The hop count the badge shows, if the channel carries one.
    public var hopCount: Int? {
        if case let .offlineMesh(hopCount) = self { return hopCount }
        return nil
    }

    /// The order rows fall into when two messages share a timestamp: the one that has NOT arrived yet
    /// is the one the user has to see first. module 7 sells the grey clock as the honest "awaiting relay", and a
    /// same-instant mesh row that renders above it would put a delivered bubble where the pending one
    /// belongs. Between the two copies that did leave the device, the app's own (SMP) row goes first,
    /// because that is the one `ChatView` already renders and the overlay is inserted around it.
    var precedence: Int {
        switch self {
        case .awaitingRelay: 0
        case .smpPublicNetwork: 1
        case .offlineMesh: 2
        }
    }
}

/// How the row should be aligned, so an inserted offline row reads like the app's own bubbles.
public enum PopopxMeshTimelineDirection: String, Hashable, Sendable {
    case incoming
    case outgoing
}

/// One message in either stream. The app maps its own chat items in with
/// `PopopxMeshTimelineMessage(application:)`; the mesh side is built from `PopopxMeshInbound` by the
/// state source. `messageID` is the globally unique id every dedup and ACK in the system keys on.
public struct PopopxMeshTimelineMessage: Identifiable, Hashable, Sendable {
    public let messageID: String
    public let timestamp: Date
    public let text: String
    public let direction: PopopxMeshTimelineDirection
    public let channel: PopopxMeshTimelineChannel
    /// Control signalling never reaches the screen; the flag is honoured by the merger, which also
    /// re-derives it from the text so a leak from either stream is caught.
    public let isControlSignal: Bool
    /// A peer's announced name, when the mesh knows one. Never the user's own: that is display state
    /// of the local device, and the plaza reads it from the sandbox.
    public let senderNickname: String?
    /// The sender's 8-byte wire id, for the window in which a flood has been heard but a handshake
    /// has not yet resolved the public key. nil for the app's own stream.
    public let senderPeerIDHex: String?

    public var id: String { messageID }

    public init(
        messageID: String,
        timestamp: Date,
        text: String,
        direction: PopopxMeshTimelineDirection,
        channel: PopopxMeshTimelineChannel,
        isControlSignal: Bool = false,
        senderNickname: String? = nil,
        senderPeerIDHex: String? = nil
    ) {
        self.messageID = messageID
        self.timestamp = timestamp
        self.text = text
        self.direction = direction
        self.channel = channel
        self.isControlSignal = isControlSignal
        self.senderNickname = senderNickname
        self.senderPeerIDHex = senderPeerIDHex
    }

    /// A row the app already renders: SMP, by definition, because that is the only path its own
    /// database knows.
    public static func application(
        messageID: String,
        timestamp: Date,
        text: String,
        direction: PopopxMeshTimelineDirection,
        senderNickname: String? = nil
    ) -> PopopxMeshTimelineMessage {
        PopopxMeshTimelineMessage(
            messageID: messageID,
            timestamp: timestamp,
            text: text,
            direction: direction,
            channel: .smpPublicNetwork,
            isControlSignal: PopopxMeshTimelineMerger.isControlText(text),
            senderNickname: senderNickname
        )
    }

    /// The mesh side, from plain values. `PopopxMeshInbound`'s memberwise initialiser is internal to
    /// module 2, so a host that decodes a flood itself — and every test of the merge rule — comes in
    /// through here instead.
    public static func offline(
        messageID: String,
        timestamp: Date,
        text: String,
        hopCount: Int,
        direction: PopopxMeshTimelineDirection = .incoming,
        senderNickname: String? = nil,
        senderPeerIDHex: String? = nil,
        isControlSignal: Bool = false
    ) -> PopopxMeshTimelineMessage {
        PopopxMeshTimelineMessage(
            messageID: messageID,
            timestamp: timestamp,
            text: text,
            direction: direction,
            channel: .offlineMesh(hopCount: hopCount),
            isControlSignal: isControlSignal || PopopxMeshTimelineMerger.isControlText(text),
            senderNickname: senderNickname,
            senderPeerIDHex: senderPeerIDHex
        )
    }

    /// The mesh's own inbound frame. `PopopxMeshInbound` carries `receivedAt` and no send timestamp
    /// (the envelope's `sentAt` stays inside the engine), so a mesh row is ordered by when it
    /// arrived — the only honest clock a node that was out of range has.
    public init(offline inbound: PopopxMeshInbound, senderNickname: String? = nil) {
        self.messageID = inbound.messageId
        self.timestamp = inbound.receivedAt
        self.direction = .incoming
        self.channel = .offlineMesh(hopCount: inbound.hopCount)
        self.senderNickname = senderNickname
        self.senderPeerIDHex = inbound.sender.hex
        switch inbound.body {
        case let .text(text):
            self.text = text
            // A flood that is not a control frame can still *read* like one; the merger checks the
            // prefixes too, so an unauthenticated stranger cannot put `BLE_ACK:` on the screen.
            self.isControlSignal = inbound.controlFrame != nil
                || PopopxMeshTimelineMerger.isControlText(text)
        case .control:
            self.text = inbound.controlFrame?.text ?? ""
            self.isControlSignal = true
        case let .binary(data):
            self.text = String(decoding: data, as: UTF8.self)
            self.isControlSignal = false
        }
    }
}

// MARK: - Rows

/// A message after the merge: deduplicated, re-channeled, and knowing whether the app already draws
/// it.
public struct PopopxMeshTimelineRow: Identifiable, Hashable, Sendable {
    public let messageID: String
    public let timestamp: Date
    public let text: String
    public let direction: PopopxMeshTimelineDirection
    public let channel: PopopxMeshTimelineChannel
    public let senderNickname: String?
    /// True when the app's own stream carries this id, so the overlay must not draw it a second time.
    public let presentInApplicationStream: Bool

    public var id: String { messageID }

    public var badge: PopopxMeshBadgeDescriptor { PopopxMeshBadgeDescriptor(channel: channel) }

    /// The hop count the badge shows, if any.
    public var hopCount: Int? { channel.hopCount }
}

/// What a merge produced: the whole timeline in order, plus the subset the overlay has to render.
public struct PopopxMeshTimelineMergeResult: Hashable, Sendable {
    public let rows: [PopopxMeshTimelineRow]

    public init(rows: [PopopxMeshTimelineRow]) {
        self.rows = rows
    }

    /// Rows the app does not have: mesh-only traffic, including the queue of messages waiting for a
    /// relay. This is what `MergedTimelineModifier` draws.
    public var offlineOnlyRows: [PopopxMeshTimelineRow] {
        rows.filter { !$0.presentInApplicationStream }
    }
}

// MARK: - Merger

/// The whole merge/dedup/sort rule, with no SwiftUI in it and no state to leak: two sequences in, one
/// ordered sequence out. Everything the checklist asks about the timeline is answerable here.
public struct PopopxMeshTimelineMerger: Hashable, Sendable {
    /// The pairs this merger uses when a caller does not hand its own. Empty by default, which is the
    /// behaviour before the dual-id mapping: the two streams are matched by id only.
    public let flushedAppChatItemIDs: [String: Int64]

    public init(flushedAppChatItemIDs: [String: Int64] = [:]) {
        self.flushedAppChatItemIDs = flushedAppChatItemIDs
    }

    /// Control prefixes are the wire protocol's own (`PopopxMeshControlFrame`), not a copy: if module 3
    /// changes a prefix, this filter changes with it.
    public static let controlPrefixes: [String] = [
        PopopxMeshControlFrame.pairingRequestPrefix,
        PopopxMeshControlFrame.pairingAckPrefix,
        PopopxMeshControlFrame.deliveryAckPrefix
    ]

    public static func isControlText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if Self.controlPrefixes.contains(where: { trimmed.hasPrefix($0) }) { return true }
        return PopopxMeshControlFrame(trimmed) != nil
    }

    /// Strictly idempotent dedup on the globally unique `messageId`: one row per id, no matter how many neighbours flooded it
    /// or how many times the router re-sent the same text over SMP with the id it already had.
    ///
    /// - The application stream wins an id both streams carry: that copy is in the chat database, so
    ///   the app renders it and the overlay must not duplicate it.
    /// - An id in `awaitingRelayMessageIDs` is re-badged to the grey clock, which is the routing
    ///   layer's verdict overriding the transport's: a message the router still owes an ACK for is
    ///   "awaiting relay" even if the engine once reported it as mesh-delivered.
    /// - A flushed offline message is the SAME message as the row the app stored, under two names. When
    ///   `flushedAppChatItemIDs` pairs a mesh id with a row id, both rows are looked up under the row id
    ///   and the application copy wins, so the bubble appears once. Without the pair the two streams
    ///   cannot recognize each other and the user sees the message twice after a restore.
    /// - Ordering is timestamp ascending, then channel precedence, then the id, so the result is a
    ///   total order and cannot depend on how the two arrays happened to arrive.
    public static func merge(
        application: [PopopxMeshTimelineMessage],
        offline: [PopopxMeshTimelineMessage],
        awaitingRelayMessageIDs: Set<String> = [],
        flushedAppChatItemIDs: [String: Int64] = [:]
    ) -> PopopxMeshTimelineMergeResult {
        var byID: [String: PopopxMeshTimelineRow] = [:]
        byID.reserveCapacity(application.count + offline.count)
        // The one shared key for a pair of ids that name a single message. Both streams are looked up
        // through it, so a host that hands the app's rows in as mesh ids and one that hands them in as
        // row ids canonicalize to the same bucket either way.
        var canonical: [String: String] = [:]
        canonical.reserveCapacity(flushedAppChatItemIDs.count)
        for (messageID, appChatItemID) in flushedAppChatItemIDs {
            canonical[messageID] = String(appChatItemID)
        }

        for message in offline where !isSuppressed(message) {
            byID[canonical[message.messageID] ?? message.messageID] = row(
                for: message,
                presentInApplicationStream: false,
                awaitingRelayMessageIDs: awaitingRelayMessageIDs
            )
        }
        // Second, so an application copy overwrites the mesh copy of the same id rather than the
        // reverse.
        for message in application where !isSuppressed(message) {
            byID[canonical[message.messageID] ?? message.messageID] = row(
                for: message,
                presentInApplicationStream: true,
                awaitingRelayMessageIDs: awaitingRelayMessageIDs
            )
        }

        let rows = byID.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.channel.precedence != $1.channel.precedence {
                return $0.channel.precedence < $1.channel.precedence
            }
            return $0.messageID < $1.messageID
        }
        return PopopxMeshTimelineMergeResult(rows: rows)
    }

    public func merge(
        application: [PopopxMeshTimelineMessage],
        offline: [PopopxMeshTimelineMessage],
        awaitingRelayMessageIDs: Set<String> = [],
        flushedAppChatItemIDs: [String: Int64]? = nil
    ) -> PopopxMeshTimelineMergeResult {
        Self.merge(
            application: application,
            offline: offline,
            awaitingRelayMessageIDs: awaitingRelayMessageIDs,
            flushedAppChatItemIDs: flushedAppChatItemIDs ?? self.flushedAppChatItemIDs
        )
    }

    private static func isSuppressed(_ message: PopopxMeshTimelineMessage) -> Bool {
        message.isControlSignal || Self.isControlText(message.text)
    }

    /// The grey clock overrides whatever channel the row arrived with: an id that is still owed a
    /// relay has not been delivered, whatever the transport said when it handed the frame over.
    private static func row(
        for message: PopopxMeshTimelineMessage,
        presentInApplicationStream: Bool,
        awaitingRelayMessageIDs: Set<String>
    ) -> PopopxMeshTimelineRow {
        PopopxMeshTimelineRow(
            messageID: message.messageID,
            timestamp: message.timestamp,
            text: message.text,
            direction: message.direction,
            channel: awaitingRelayMessageIDs.contains(message.messageID)
                ? .awaitingRelay
                : message.channel,
            senderNickname: message.senderNickname,
            presentInApplicationStream: presentInApplicationStream
        )
    }
}

// MARK: - Badge

/// The badge a row gets, described without SwiftUI so the classification is unit-testable.
public struct PopopxMeshBadgeDescriptor: Hashable, Sendable {
    public enum Tone: String, Hashable, Sendable {
        case blue
        case orange
        case grey
    }

    public let symbolName: String
    public let tone: Tone
    /// The hop count suffix, e.g. `· 3`.
    public let accessory: String?
    public let accessibilityLabel: String

    public init(channel: PopopxMeshTimelineChannel) {
        switch channel {
        case .smpPublicNetwork:
            symbolName = "shield.lefthalf.filled"
            tone = .blue
            accessory = nil
            accessibilityLabel = "POPOPX public network (SMP)"
        case let .offlineMesh(hopCount):
            symbolName = "antenna.radiowaves.left.and.right"
            tone = .orange
            accessory = "· \(hopCount)"
            accessibilityLabel = hopCount == 0
                ? "Offline mesh, direct link"
                : "Offline mesh, \(hopCount) hops"
        case .awaitingRelay:
            symbolName = "clock"
            tone = .grey
            accessory = nil
            accessibilityLabel = "Awaiting relay"
        }
    }
}

/// The bubble's channel badge. Blue shield / orange ripple + hop count / grey clock, exactly as module 7 specifies.
@MainActor
public struct PopopxMeshChannelBadge: View {
    private let descriptor: PopopxMeshBadgeDescriptor

    public init(channel: PopopxMeshTimelineChannel) {
        self.descriptor = PopopxMeshBadgeDescriptor(channel: channel)
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: descriptor.symbolName)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(PopopxMeshChannelBadge.color(of: descriptor.tone))
            if let accessory = descriptor.accessory {
                Text(accessory)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PopopxMeshChannelBadge.color(of: descriptor.tone))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: descriptor.accessibilityLabel))
    }

    static func color(of tone: PopopxMeshBadgeDescriptor.Tone) -> Color {
        switch tone {
        case .blue: .blue
        case .orange: .orange
        case .grey: .gray
        }
    }
}

// MARK: - Model

/// Drives the merge with Combine and publishes its result. Nothing in here knows about views, so a
/// test can feed it two streams and assert on rows.
@MainActor
public final class PopopxMeshTimelineModel: ObservableObject {
    /// The full merged timeline, in order.
    @Published public private(set) var result = PopopxMeshTimelineMergeResult(rows: [])

    /// The same rows the overlay is allowed to draw, kept as a published value so a view can read it
    /// without recomputing in `body`.
    @Published public private(set) var offlineOnlyRows: [PopopxMeshTimelineRow] = []

    private let source: PopopxMeshStateSource
    private let routing: any PopopxMeshRoutingObserving
    /// The timeline entry of a host that does not name a chat — see `replaceApplicationStream(_:)`.
    static let unscopedChatID = ""
    /// The app's own rows, one entry per mounted chat. The dictionary, rather than one array, is what
    /// keeps two `ChatView`s that are both alive from overwriting each other's dedup input.
    private var applicationStreams: [String: [PopopxMeshTimelineMessage]] = [:]
    private let applicationStream = CurrentValueSubject<[PopopxMeshTimelineMessage], Never>([])
    private let offlineStream = CurrentValueSubject<[PopopxMeshTimelineMessage], Never>([])
    private let relayStream = CurrentValueSubject<Set<String>, Never>([])
    private let flushedAppItemsStream = CurrentValueSubject<[String: Int64], Never>([:])
    private var cancellables: Set<AnyCancellable> = []
    private var pumpTask: Task<Void, Never>?
    private var routingRelayIDs: Set<String> = []
    private var sourceRelayIDs: Set<String> = []

    public init(
        source: PopopxMeshStateSource = .shared,
        routing: any PopopxMeshRoutingObserving = PopopxMeshNoRoutingObserver()
    ) {
        self.source = source
        self.routing = routing
        // One pipeline, four inputs: the app's own stream, the mesh's stream, the ids either the mesh
        // or module 5 still owes a relay for, and the mesh-id → stored-row-id pairs a flush left behind.
        // `assign(to: &$…)` keeps the whole data flow in Combine with no closure that outlives the main
        // actor.
        Publishers.CombineLatest4(applicationStream, offlineStream, relayStream, flushedAppItemsStream)
            .map { application, offline, relay, flushedAppItems in
                PopopxMeshTimelineMerger.merge(
                    application: application,
                    offline: offline,
                    awaitingRelayMessageIDs: relay,
                    flushedAppChatItemIDs: flushedAppItems
                )
            }
            .assign(to: &$result)
        $result
            .map { $0.offlineOnlyRows }
            .assign(to: &$offlineOnlyRows)
    }

    /// Feed the stream the app already renders. Call it again whenever that list changes.
    ///
    /// The unscoped form writes the entry named `PopopxMeshTimelineModel.unscopedChatID`, which is the
    /// single-stream host: a view that owns the timeline for one chat at a time, and every test of the
    /// merge rule.
    public func replaceApplicationStream(_ messages: [PopopxMeshTimelineMessage]) {
        replaceApplicationStream(messages, forChatID: Self.unscopedChatID)
    }

    /// Feed only the rows of one chat.
    ///
    /// One `PopopxMeshTimelineModel` is mounted by every `ChatView`, and in this app's navigation a
    /// pushed chat does not make the chat underneath it disappear — so a stream a view *replaces* would
    /// let whichever view wrote last decide what every other chat deduplicates against, and a flushed
    /// message could be hidden from the strip while its own bubble was offscreen, or drawn twice in the
    /// chat that did not write last. Each chat owns its entry: appearing adds or replaces it, going away
    /// removes only it, and the merged stream is the union of the chats that are actually mounted.
    public func replaceApplicationStream(
        _ messages: [PopopxMeshTimelineMessage],
        forChatID chatID: String
    ) {
        applicationStreams[chatID] = messages
        publishApplicationStreams()
    }

    /// Drop one chat's rows, so the timeline stops treating messages the app no longer renders as
    /// already shown. Removing a chat that never fed anything is a no-op, which matters because
    /// `onDisappear` fires for views whose task never got to run.
    public func removeApplicationStream(forChatID chatID: String) {
        guard applicationStreams[chatID] != nil else { return }
        applicationStreams[chatID] = nil
        publishApplicationStreams()
    }

    /// The union, ordered by id rather than by dictionary iteration order: an unstable array would make
    /// every publish look like a changed timeline. The merger's own sort does not depend on this — its
    /// tie-break is the id — so the rows come out identical either way.
    private func publishApplicationStreams() {
        var merged: [PopopxMeshTimelineMessage] = []
        for messages in applicationStreams.values { merged.append(contentsOf: messages) }
        merged.sort { $0.messageID < $1.messageID }
        applicationStream.send(merged)
    }

    /// Same, from plain values, for a host that has ids and dates rather than mapped messages. The
    /// mapping is written out instead of as a `map` closure so the two overloads cannot confuse
    /// inference at the call site.
    public func replaceApplicationStream(
        with items: [(messageID: String, timestamp: Date, text: String)]
    ) {
        var mapped: [PopopxMeshTimelineMessage] = []
        mapped.reserveCapacity(items.count)
        for item in items {
            mapped.append(
                PopopxMeshTimelineMessage.application(
                    messageID: item.messageID,
                    timestamp: item.timestamp,
                    text: item.text,
                    direction: .outgoing
                )
            )
        }
        replaceApplicationStream(mapped)
    }

    /// Starts mirroring the mesh. Idempotent; safe while the fuse is off, in which case nothing ever
    /// arrives and the timeline stays empty.
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
        Task { [weak self] in
            await self?.refreshRoutingState()
        }
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        applicationStreams.removeAll()
        applicationStream.send([])
        offlineStream.send([])
        relayStream.send([])
    }

    /// Module 5's pending-relay queue, pulled once per change. A host without a router gets the empty
    /// set and still sees the engine's own `sendFailed` clocks, because the two sources are unioned.
    ///
    /// All three halves are pulled *here*: the router's queue, the pairs its flushes left, and the
    /// mirror's current id set. Reading the
    /// mirror only from `apply(state:)` would make the union depend on the pump having been started,
    /// and a host that feeds its own application stream and asks once for a refresh is not a host that
    /// mounted a pump — its grey clocks would silently be the router's only.
    public func refreshRoutingState() async {
        routingRelayIDs = await routing.pendingRelayMessageIDs()
        flushedAppItemsStream.send(await routing.flushedAppChatItemIDs())
        sourceRelayIDs = source.state.awaitingRelayMessageIDs
        publishRelayIDs()
    }

    /// A host that prefers to push (a router that already knows when its queue changed) may call
    /// this instead of letting the model poll.
    public func setAwaitingRelayMessageIDs(_ ids: Set<String>) {
        routingRelayIDs = ids
        publishRelayIDs()
    }

    private func apply(state: PopopxMeshStreamState) {
        offlineStream.send(state.privateMessages)
        sourceRelayIDs = state.awaitingRelayMessageIDs
        publishRelayIDs()
    }

    private func publishRelayIDs() {
        relayStream.send(routingRelayIDs.union(sourceRelayIDs))
    }
}

// MARK: - Modifier

/// Merges the mesh's offline stream into an existing chat view without touching that view's code.
///
/// Mounted with `View.popopxMergedTimeline(_:messages:)`, which puts the rows the app does not have
/// in a strip at the top of the safe area — the same place `ChatView` puts its own status strips —
/// and leaves everything the app already renders exactly as it was.
@MainActor
public struct MergedTimelineModifier: ViewModifier {
    @ObservedObject private var model: PopopxMeshTimelineModel
    private let chatID: String?
    private let messages: [PopopxMeshTimelineMessage]
    private let visibleRows: Int

    /// - Parameters:
    ///   - model: the merge, already wired to the mesh.
    ///   - chatID: which chat `messages` belongs to, so a second mounted chat view cannot overwrite the
    ///     first one's dedup input. `nil` keeps the single-stream behaviour.
    ///   - messages: the app's current stream, mapped in by the host.
    ///   - visibleRows: how many mesh-only rows the strip shows; the full timeline stays on `model`.
    public init(
        model: PopopxMeshTimelineModel,
        chatID: String? = nil,
        messages: [PopopxMeshTimelineMessage] = [],
        visibleRows: Int = 3
    ) {
        self.model = model
        self.chatID = chatID
        self.messages = messages
        self.visibleRows = max(1, visibleRows)
    }

    public func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                PopopxMeshOfflineTimelineStrip(
                    rows: Array(model.offlineOnlyRows.suffix(visibleRows)),
                    emptyIsInvisible: true
                )
            }
            // `.task(id:)` rather than `.onChange(of:)`: the two-parameter `onChange` this would
            // prefer is iOS 16, and the package still builds for iOS 15. The id carries the chat as
            // well as the rows, so a view that comes back with the same rows it fed before still
            // re-registers its own entry.
            .task(id: FeedKey(chatID: chatID, messages: messages)) {
                if let chatID {
                    model.replaceApplicationStream(messages, forChatID: chatID)
                } else {
                    model.replaceApplicationStream(messages)
                }
            }
            // Attached whether or not a chat id was given, so the modifier's view structure never
            // depends on the fuse or on the host's wiring. `removeApplicationStream` is a no-op for
            // the unscoped entry's host, which never named one.
            .onDisappear {
                if let chatID {
                    model.removeApplicationStream(forChatID: chatID)
                }
            }
    }

    /// The task's identity: the chat and its rows together, because either half changing has to
    /// re-feed.
    private struct FeedKey: Hashable {
        let chatID: String?
        let messages: [PopopxMeshTimelineMessage]
    }
}

/// The rows the app does not render, drawn as bubbles. Empty input draws nothing at all, so a chat
/// with no offline traffic looks pixel-identical to the stock build.
@MainActor
public struct PopopxMeshOfflineTimelineStrip: View {
    private let rows: [PopopxMeshTimelineRow]
    private let emptyIsInvisible: Bool

    public init(rows: [PopopxMeshTimelineRow], emptyIsInvisible: Bool = true) {
        self.rows = rows
        self.emptyIsInvisible = emptyIsInvisible
    }

    public var body: some View {
        if rows.isEmpty && emptyIsInvisible {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        PopopxMeshChannelBadge(channel: row.channel)
                        VStack(alignment: .leading, spacing: 2) {
                            if let nickname = row.senderNickname, !nickname.isEmpty {
                                Text(nickname)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(row.text)
                                .font(.callout)
                                .lineLimit(3)
                        }
                        Spacer(minLength: 8)
                        Text(PopopxMeshOfflineTimelineStrip.clock(row.timestamp))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// HH:mm in the device's locale: a strip this small has no room for a date, and a mesh message
    /// older than a day is in the app's own list by then.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: date)
    }
}

public extension View {
    /// Zero-breakage mount point: merge the mesh timeline into `self`. The wrapped view is not modified — no
    /// environment object, no initializer change, no rewrite of its body.
    ///
    /// Pass `chatID` whenever the wrapped view is one chat of several that can be alive at the same
    /// time: the rows then belong to that chat's entry, and leaving the view takes them back out.
    func popopxMergedTimeline(
        _ model: PopopxMeshTimelineModel,
        chatID: String? = nil,
        messages: [PopopxMeshTimelineMessage] = []
    ) -> some View {
        modifier(MergedTimelineModifier(model: model, chatID: chatID, messages: messages))
    }
}
