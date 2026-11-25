//
//  ControlProtocol.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// A completed reply from the control port.
public struct ControlMessage: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case positive
        case error
        case other(Int)

        init(code: Int) {
            switch code {
            case 200..<300: self = .positive
            case 400..<600: self = .error
            default: self = .other(code)
            }
        }
    }

    /// 250 for a command reply, 650 for an asynchronous event.
    public let code: Int
    public let status: Status
    /// The text of the closing line, e.g. `OK` or `Async`.
    public let message: String
    /// The interim lines, in order. `GETINFO` answers put one `key=value` here per key.
    public let lines: [String]
    /// The body of any `+`-terminated data section.
    public let data: [String]

    public var isEvent: Bool { code == 650 }

    init(code: Int, message: String, lines: [String], data: [String]) {
        self.code = code
        self.status = Status(code: code)
        self.message = message
        self.lines = lines
        self.data = data
    }
}

/// Turns control-port bytes into whole replies.
///
/// The framing is the awkward part of this protocol and the part worth testing on its own: a reply
/// is not "a line", it is a run of lines ending in one whose fourth character is a space, and a
/// `GETINFO` answer nests a dot-terminated data block inside that. Reading until a newline and
/// calling it done truncates every multi-line answer, which for `status/bootstrap-phase` means the
/// progress the UI is waiting for is the one thing that never arrives.
///
/// This parser holds no socket and knows no concurrency, so every framing case below is reachable
/// from a unit test without a running Tor.
public struct ControlProtocolParser: Sendable {
    private enum Section {
        case awaitingTerminator
        case inData
    }

    private var buffer = Data()
    private var interimLines: [String] = []
    private var dataLines: [String] = []
    private var expectedCode: Int?
    private var section: Section = .awaitingTerminator

    public init() {}

    /// Feed received bytes; returns every reply that became complete.
    public mutating func consume(_ incoming: Data) -> [ControlMessage] {
        buffer.append(incoming)
        var completed: [ControlMessage] = []
        // A chunk can carry several replies and the start of another, so this loop is the whole
        // point: one message per iteration, and any leftover bytes stay buffered.
        while let line = takeLine() {
            if case .inData = section {
                // `tor` writes a long value in one of two shapes: as interim `250-…` lines that end
                // with the reply's own `250 OK`, or as a dot-terminated raw block. Both must close
                // the section, and neither may be read as data text verbatim — the `250-` form would
                // otherwise leak the framing into the value and leave the reply permanently open.
                if line == "." {
                    section = .awaitingTerminator
                    continue
                }
                if let parsed = Self.classify(line) {
                    switch parsed {
                    case let .interim(_, text):
                        dataLines.append(text)
                        continue
                    case let .final(code, text):
                        complete(code: code, message: text, into: &completed)
                        continue
                    case .dataStart:
                        // A data section opening inside a data section is not something this
                        // protocol produces; ignoring it keeps a framing error from hanging us.
                        continue
                    }
                }
                dataLines.append(line)
                continue
            }
            guard let parsed = Self.classify(line) else {
                // Unclassifiable text inside a control reply means our framing is already wrong;
                // keeping it would make the eventual message silently incomplete.
                continue
            }
            switch parsed {
            case let .interim(code, text):
                expectedCode = code
                interimLines.append(text)
            case let .dataStart(code, keyword):
                expectedCode = code
                interimLines.append(keyword)
                section = .inData
            case let .final(code, text):
                complete(code: code, message: text, into: &completed)
            }
        }
        return completed
    }

    private mutating func complete(
        code: Int,
        message text: String,
        into completed: inout [ControlMessage]
    ) {
        completed.append(
            ControlMessage(code: code, message: text, lines: interimLines, data: dataLines)
        )
        interimLines = []
        dataLines = []
        expectedCode = code
        section = .awaitingTerminator
    }

    /// The code of the most recent line, kept so a caller can tell whether an in-flight reply was an
    /// error before its closing line arrives.
    public var pendingCode: Int? { expectedCode }

    private enum Classified {
        case interim(Int, String)
        case dataStart(Int, String)
        case final(Int, String)
    }

    private static func classify(_ line: String) -> Classified? {
        guard line.count >= 4, let code = Int(line.prefix(3)) else { return nil }
        let separator = line[line.index(line.startIndex, offsetBy: 3)]
        let text = String(line.dropFirst(4))
        switch separator {
        case "-": return .interim(code, text)
        case "+": return .dataStart(code, text)
        case " ": return .final(code, text)
        default: return nil
        }
    }

    /// Pulls one CRLF-terminated line out of the buffer, or nil when the line is still in flight.
    private mutating func takeLine() -> String? {
        // Tor's spec says CRLF. Accepting a bare LF as well costs nothing and avoids a hang if a
        // future version or a proxy in front of it normalises line endings.
        var index = buffer.startIndex
        while index < buffer.endIndex {
            if buffer[index] == 0x0A {
                let end = (index > buffer.startIndex && buffer[buffer.index(before: index)] == 0x0D)
                    ? buffer.index(before: index)
                    : index
                let slice = buffer[buffer.startIndex..<end]
                let line = String(decoding: slice, as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<buffer.index(after: index))
                return line
            }
            index = buffer.index(after: index)
        }
        return nil
    }
}

/// Serialising commands, kept separate from the parser so the CRLF rule is asserted in one place.
public enum ControlCommand {
    /// `PROTOCOLINFO 1` — asks the daemon which authentication methods it will accept, without
    /// needing to be authenticated first.
    public static let protocolInfo = "PROTOCOLINFO 1\r\n"
    public static func authenticate(secret: String) -> String { "AUTHENTICATE \(quoted(secret))\r\n" }
    public static func getInfo(_ keys: [String]) -> String { "GETINFO \(keys.joined(separator: " "))\r\n" }
    public static func setEvents(_ events: [String]) -> String { "SETEVENTS \(events.joined(separator: " "))\r\n" }
    public static let newCircuit = "SIGNAL NEWNYM\r\n"
    /// Truncates a reply that arrives longer than expected rather than trusting the sender.
    public static let close = "QUIT\r\n"

    /// Quotes a control-port argument the same way the daemon expects: a quoted string with
    /// backslash and double-quote escapes. Unescaped input here is an injection into the control
    /// protocol, and an authenticated control port can load a `SETCONF` that redirects traffic.
    ///
    /// The loop walks unicode scalars, not `Character`s, because `"\r\n"` is a single grapheme
    /// cluster: a character-wise switch would fall through to the default branch on the very CRLF an
    /// injection needs, and hand back the argument with its second command still attached.
    public static func quoted(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\r": escaped += "\\r"
            case "\n": escaped += "\\n"
            default:
                // Tor also accepts `\NNN` for any other byte. Control characters below the printable
                // range have no business in a bridge line or a password, and leaving them raw is a
                // second chance to confuse a parser.
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += "\\\(String(format: "%03d", scalar.value))"
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }

    public static func setConf(_ entries: [(String, String)]) -> String {
        let body = entries.map { "\($0.0)=\(quoted($0.1))" }.joined(separator: " ")
        return "SETCONF \(body)\r\n"
    }
}
