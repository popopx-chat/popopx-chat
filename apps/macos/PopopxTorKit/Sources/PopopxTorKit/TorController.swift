//
//  TorController.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// One connection to the control port: commands in, replies and asynchronous events out.
///
/// Commands and `650` events share a single socket, so a design where each caller reads its own
/// reply loses events to whichever caller happened to be waiting, and loses a reply to the event
/// loop. There is therefore exactly one reader, and synchronous replies are dispatched to waiters in
/// the order their commands were written — which the daemon guarantees, since it processes control
/// commands serially on the connection.
public final class TorController: @unchecked Sendable {
    public struct Event: Sendable {
        /// `BOOTSTRAP`, `CIRC`, `BW`, `NOTICE`, …
        public let name: String
        public let payload: [String]
    }

    private let transport: ControlTransport
    private let state = NSLock()
    private var parser = ControlProtocolParser()
    private var waiters: [CheckedContinuationHandle] = []
    private var reader: Thread?
    private var stopped = false
    private let onEvent: @Sendable (Event) -> Void
    private let onError: @Sendable (Error) -> Void

    /// Replies arrive on an `async` call, so the waiter has to be a box around a continuation.
    private final class CheckedContinuationHandle {
        let resume: (Result<ControlMessage, Error>) -> Void
        init(_ resume: @escaping (Result<ControlMessage, Error>) -> Void) { self.resume = resume }
    }

    public init(
        transport: ControlTransport,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in },
        onError: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.transport = transport
        self.onEvent = onEvent
        self.onError = onError
    }

    public func startReading() {
        state.lock()
        guard reader == nil, !stopped else { state.unlock(); return }
        state.unlock()
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "com.popopxchat.popopx.tor.control"
        state.lock()
        reader = thread
        state.unlock()
        thread.start()
    }

    public func shutdown() {
        state.lock()
        stopped = true
        let pending = waiters
        waiters.removeAll()
        state.unlock()
        for waiter in pending {
            waiter.resume(.failure(TorError.controlPortUnreachable("controller shut down")))
        }
        // `QUIT` is best effort: whatever is wrong with this socket is the reason we are closing it,
        // and a throw here would skip the `close()` below.
        try? transport.write(Data(ControlCommand.close.utf8))
        transport.close()
    }

    private func currentlyStopped() -> Bool {
        state.lock()
        defer { state.unlock() }
        return stopped
    }

    // MARK: - Commands

    @discardableResult
    public func send(_ command: String) async throws -> ControlMessage {
        if currentlyStopped() {
            throw TorError.controlPortUnreachable("controller shut down")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ControlMessage, Error>) in
                let handle = CheckedContinuationHandle { result in continuation.resume(with: result) }
                state.lock()
                waiters.append(handle)
                state.unlock()
                do {
                    try transport.write(Data(command.utf8))
                } catch {
                    state.lock()
                    if let index = waiters.firstIndex(where: { $0 === handle }) {
                        waiters.remove(at: index)
                    }
                    state.unlock()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { [transport] in
            // Cancelling the awaiting task cannot un-send the command, so the socket is closed: a
            // reply that arrives for an abandoned waiter would otherwise be handed to the *next*
            // command's waiter and be reported as that command's answer.
            transport.close()
        }
    }

    public func authenticate(_ authentication: ControlAuthentication) async throws {
        let message = try await send(authentication.commandLine())
        guard message.status == .positive else {
            throw TorError.authenticationRejected
        }
    }

    public func protocolInfo() async throws -> ProtocolInfo {
        let message = try await send(ControlCommand.protocolInfo)
        guard let info = ProtocolInfo.parse(message) else {
            throw TorError.protocolFraming("PROTOCOLINFO carried no recognised AUTH line")
        }
        return info
    }

    /// `GETINFO` for several keys at once, keyed by name.
    public func getInfo(_ keys: [String]) async throws -> [String: String] {
        let message = try await send(ControlCommand.getInfo(keys))
        guard message.status == .positive else {
            throw TorError.protocolFraming("GETINFO \(keys) returned \(message.code)")
        }
        var values: [String: String] = [:]
        // Two shapes reach here. A short value arrives as one interim line, `250-key=value`, and the
        // closing `250 ` line carries no value of its own. A multi-line value opens with
        // `250+key=` and its body arrives in the data section, so the key is empty on the line that
        // named it and the answer is the joined body.
        for line in message.lines {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            let inline = String(line[line.index(after: equals)...])
            values[key] = inline.isEmpty ? message.data.joined(separator: "\n") : inline
        }
        return values
    }

    public func bootstrapPhase() async throws -> BootstrapProgress? {
        let values = try await getInfo(["status/bootstrap-phase"])
        guard let text = values["status/bootstrap-phase"] ?? values.values.first else { return nil }
        return BootstrapProgress.parse(text)
    }

    /// The fingerprint and host of the current exit, or nil while no general circuit exists.
    ///
    /// `circuit-status` lines are `id purpose state path …`; only `BUILDING`/`EXTENDED` chains that
    /// reach `established` and carry the `GENERAL` purpose have an exit at all, and a `GENERAL`
    /// circuit's last hop is that exit.
    public func exitNode() async throws -> TorExitNode? {
        let values = try await getInfo(["circuit-status"])
        guard let status = values["circuit-status"] else { return nil }
        return TorExitNode.parse(circuitStatus: status)
    }

    public func subscribe(to events: [String]) async throws {
        let message = try await send(ControlCommand.setEvents(events))
        guard message.status == .positive else {
            throw TorError.protocolFraming("SETEVENTS rejected with \(message.code)")
        }
    }

    /// Ask Tor for a fresh circuit. Does not guarantee a new exit, and the UI must not claim it does.
    public func signalNewCircuit() async throws {
        let message = try await send(ControlCommand.newCircuit)
        guard message.status == .positive else {
            throw TorError.protocolFraming("SIGNAL NEWNYM rejected with \(message.code)")
        }
    }

    // MARK: - Reader

    private func readLoop() {
        while true {
            do {
                let chunk = try transport.read(maximumBytes: 8192)
                if chunk.isEmpty {
                    finish(TorError.controlPortUnreachable("the control port closed the connection"))
                    return
                }
                for message in parser.consume(chunk) {
                    route(message)
                }
            } catch {
                finish(error)
                return
            }
        }
    }

    private func route(_ message: ControlMessage) {
        if message.isEvent {
            onEvent(Self.event(from: message))
            return
        }
        state.lock()
        guard !waiters.isEmpty else {
            state.unlock()
            return
        }
        let waiter = waiters.removeFirst()
        state.unlock()
        waiter.resume(.success(message))
    }

    private func finish(_ error: Error) {
        state.lock()
        let pending = waiters
        waiters.removeAll()
        stopped = true
        state.unlock()
        for waiter in pending {
            waiter.resume(.failure(error))
        }
        onError(error)
    }

    static func event(from message: ControlMessage) -> Event {
        let payload = message.lines + message.data + [message.message]
        // A plain event names itself on the closing line (`650 BOOTSTRAP 45 loading_descriptors`); a
        // `+`-section event names itself on the opening interim line before its `=`
        // (`650+status/client/orconn=1`). Reading only the closing line would name the first and
        // nothing at all the second.
        let head = (message.lines.first ?? message.message).split(separator: " ", maxSplits: 1)
        let name = head.first.map { String($0.prefix(while: { $0 != "=" })) } ?? ""
        return Event(name: name, payload: payload)
    }
}

extension TorController {
    /// The events this package needs, and why each one is on the list.
    public static let requiredEvents = [
        // Progress, so the gate can open without polling.
        "BOOTSTRAP",
        // Circuit teardown is the only reliable signal that a previously ready daemon has stopped
        // carrying traffic; `BOOTSTRAP` does not fire again.
        "CIRC",
        // Health reporting only.
        "BW"
    ]
}
