//
//  TorBinaryLocator.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Where the `tor` executable came from.
///
/// The order is a security decision, not a convenience one. A daemon found on `PATH` is chosen
/// **last** and only when development fallback is explicitly switched on, because a
/// system-installed Tor carries a different `DataDirectory`, a different user, and — decisively — a
/// `ControlPort` that our app does not own and cannot authenticate to. Silently driving someone's
/// brew service would also mean the "randomised private ports, cookie auth, isolated data
/// directory" properties this package exists to provide are all simply not true, while the UI still
/// says they are.
public enum TorBinaryLocator: Sendable {
    public struct Found: Sendable, Equatable {
        public let url: URL
        public let source: Source

        public enum Source: String, Sendable {
            /// `POPOPX.app/Contents/Helpers/tor` — the notarised, shipped binary.
            case bundled
            /// An explicit override, for a developer pointing at their own build.
            case override
            /// `/opt/homebrew/bin/tor` or `/usr/local/bin/tor`, development only.
            case system
        }
    }

    public struct Options: Sendable {
        /// Allow falling back to a Homebrew Tor. Off in release builds; the DMg script never sets it.
        public let allowSystemFallback: Bool
        public let overridePath: String?

        public init(allowSystemFallback: Bool = false, overridePath: String? = nil) {
            self.allowSystemFallback = allowSystemFallback
            self.overridePath = overridePath
        }
    }

    /// The relative location inside the bundle that `scripts/macos/build_macos_dmg.sh` populates.
    public static let bundleRelativePath = "Contents/Helpers/tor"

    public static func locate(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        options: Options = Options(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<Found, TorError> {
        var candidates: [(String, Found.Source)] = []
        if let override = options.overridePath ?? environment["POPOPX_TOR_PATH"], !override.isEmpty {
            candidates.append((override, .override))
        }
        if let resourcePath = bundle.resourcePath {
            // `Contents/Helpers` is not a resource directory, so the bundle path is rebuilt rather
            // than asked for: `url(forResource:withExtension:subdirectory:)` would look under
            // `Resources/` and never find it.
            let root = URL(fileURLWithPath: resourcePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers")
                .appendingPathComponent("tor")
            candidates.append((root.path, .bundled))
        }
        if let executable = Bundle.main.executableURL {
            let sibling = executable
                .deletingLastPathComponent()
                .appendingPathComponent("../\(bundleRelativePath)")
                .standardizedFileURL
            candidates.append((sibling.path, .bundled))
        }
        if options.allowSystemFallback {
            candidates.append(("/opt/homebrew/bin/tor", .system))
            candidates.append(("/usr/local/bin/tor", .system))
        }
        for (path, source) in candidates where fileManager.isExecutableFile(atPath: path) {
            return .success(Found(url: URL(fileURLWithPath: path), source: source))
        }
        return .failure(.binaryNotFound(candidates: candidates.map(\.0)))
    }

    /// A pre-flight check the UI runs before offering "Start", so that a missing helper is a message
    /// about a missing file rather than a spinner that never resolves.
    public static func isExecutableUsable(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }
}
