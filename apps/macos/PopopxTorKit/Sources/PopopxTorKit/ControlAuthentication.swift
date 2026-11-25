//
//  ControlAuthentication.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import Foundation

/// How the app proves it owns the daemon it just launched.
///
/// Cookie authentication is the default and the reason is a leak that is easy to miss: a password has
/// to be generated, stored, written into `torrc` and finally passed over the socket, and every one of
/// those steps is a place it can be read — the config file by a backup agent, the argument vector by
/// `ps`, the Keychain by a synchronised keychain chain. A cookie is written by Tor itself, into a
/// `0600` file inside a `0700` directory we created, and never appears in anything we generate.
public enum ControlAuthentication: Sendable, Equatable {
    /// Read Tor's own `control_auth_cookie` and present it.
    case cookie(file: URL)
    /// Present a password, which must already be registered with the daemon as a hashed control
    /// password.
    case password(String)

    public static func cookie(at dataDirectory: URL) -> ControlAuthentication {
        .cookie(file: dataDirectory.appendingPathComponent("control_auth_cookie"))
    }

    /// The `AUTHENTICATE` payload, which is the secret hex-encoded and quoted.
    ///
    /// Throws rather than returning nil: an authentication step that quietly produces nothing is a
    /// connection that then looks like a protocol error, and "the cookie file was not there yet" is a
    /// diagnosis worth keeping.
    public func credential() throws -> String {
        switch self {
        case let .cookie(file):
            // A 32-byte file read on the connect path; no mapping or copying option is load-bearing
            // here, and the size check below is what rejects a truncated or partial write.
            let data = try Data(contentsOf: file)
            guard data.count == 32 else {
                throw TorError.authenticationRejected
            }
            return data.map { String(format: "%02x", $0) }.joined()
        case let .password(secret):
            return secret
        }
    }
}

public extension ControlAuthentication {
    /// The `AUTHENTICATE` line for this credential.
    func commandLine() throws -> String {
        ControlCommand.authenticate(secret: try credential())
    }
}

/// The daemon's answer to `PROTOCOLINFO 1`.
public struct ProtocolInfo: Sendable, Equatable {
    public enum Method: String, Sendable {
        /// Tor spells its "no credential" answer `NONE`, and the raw value has to match or the method
        /// list silently loses it.
        case none = "NONE"
        case cookie = "COOKIE"
        case hashedPassword = "HASHEDPASSWORD"
        case safeCookie = "SAFECOOKIE"
    }

    public let methods: [Method]
    public let cookieFile: URL?
    public let version: String?

    /// Parses the interim lines:
    ///
    ///     250-AUTH METHODS=COOKIE,HASHEDPASSWORD COOKIEFILE="/tmp/x/control_auth_cookie"
    ///     250-INFO Version=Tor 0.4.8.10
    ///
    /// Returns nil rather than a guess when the shape is unfamiliar, because an empty method list
    /// would be read as "no authentication needed" by any caller that trusted it.
    public static func parse(_ message: ControlMessage) -> ProtocolInfo? {
        var methods: [Method] = []
        var cookieFile: URL?
        var version: String?
        for line in message.lines {
            if line.hasPrefix("AUTH ") || line == "AUTH" {
                for piece in Self.tokens(line.dropFirst(4)) {
                    guard let equals = piece.firstIndex(of: "=") else { continue }
                    let key = String(piece[piece.startIndex..<equals])
                    let value = Self.unquote(String(piece[piece.index(after: equals)...]))
                    switch key {
                    case "METHODS":
                        // A name Tor offers that this enum does not know is dropped rather than
                        // guessed at, and an answer that yields no known method is rejected by the
                        // guard below instead of being reported as `METHODS=NONE`.
                        methods = value.split(separator: ",").compactMap { Method(rawValue: String($0)) }
                    case "COOKIEFILE":
                        cookieFile = URL(fileURLWithPath: value)
                    default:
                        continue
                    }
                }
            } else if line.hasPrefix("INFO ") {
                // `INFO Version=Tor 0.4.8.10` carries a space inside the value and spells the key
                // `Version`, so this line is split on its first `=` rather than tokenised.
                guard let equals = line.firstIndex(of: "=") else { continue }
                let key = String(line.dropFirst(5).prefix(upTo: equals)).trimmingCharacters(in: .whitespaces)
                guard key.caseInsensitiveCompare("version") == .orderedSame else { continue }
                version = Self.unquote(String(line[line.index(after: equals)...]))
            }
        }
        guard !methods.isEmpty else { return nil }
        return ProtocolInfo(methods: methods, cookieFile: cookieFile, version: version)
    }

    /// Picks a method the daemon offers that this package can actually complete.
    ///
    /// `COOKIE` is preferred over `SAFECOOKIE` not because it is stronger — it is not — but because
    /// the SAFECOOKIE nonce handshake is not implemented here (see ``SafeCookieKey``), and offering a
    /// method we cannot finish would turn a working connection into an authentication failure.
    public func preferredMethod() -> Method? {
        if methods.contains(.cookie) { return .cookie }
        if methods.contains(.safeCookie) { return .safeCookie }
        if methods.contains(.hashedPassword) { return .hashedPassword }
        // Spelled out twice on purpose: as `return .none` this would be `Optional.none`, i.e. "no
        // method at all", and a daemon that asks for no credential would be reported as one we
        // cannot authenticate to.
        if methods.contains(Method.none) { return Method.none }
        return nil
    }

    private static func tokens(_ text: Substring) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            switch character {
            case "\"":
                quoted.toggle()
            case " " where !quoted:
                if !current.isEmpty { result.append(current) }
                current = ""
            default:
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func unquote(_ text: String) -> String {
        text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2
            ? String(text.dropFirst().dropLast())
            : text
    }
}

/// The SAFECOOKIE key derivation, kept here so it is one reviewed implementation.
///
/// Not wired into the default path: the raw `COOKIE` method over a loopback socket to a descriptor we
/// only ever reach at 127.0.0.1 is the same trust boundary, and `ControlTransport` refuses any other
/// host. This exists because a daemon configured with *only* `SAFECOOKIE` would otherwise leave us
/// with no way to authenticate, and silently falling back to `.none` on an authenticated port is not
/// an acceptable response to that.
public enum SafeCookieKey {
    static let serverKey = "Tor safe cookie authentication server-to-controller hash"
    static let clientKey = "Tor safe cookie authentication controller-to-server hash"

    public static func authenticate(clientFirstNonce: Data, serverFirstNonce: Data, cookie: Data) -> Data {
        var toHash = cookie
        toHash.append(clientFirstNonce)
        toHash.append(serverFirstNonce)
        toHash.append(Data(clientKey.utf8))
        return Data(SHA256.hash(data: toHash))
    }
}
