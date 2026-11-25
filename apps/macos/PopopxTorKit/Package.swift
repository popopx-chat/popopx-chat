// swift-tools-version: 6.0
//
//  Package.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  An embedded Tor routing engine for the POPOPX macOS client. It is deliberately kept out of
//  `apps/ios/`: nothing here is compiled for, linked by, or referenced from the iOS target, and the
//  iOS-side scripts that sweep that directory (`POPOPX Snapshots/check-previews.py`, the pbxproj
//  updaters) never see it.
//
//  Swift 5 language mode, not 6. `Foundation.Process` is not `Sendable` and the control socket is a
//  blocking POSIX descriptor; both are confined to a serial queue by construction, which the
//  compiler in v6 mode cannot see and would demand be rewritten with a different transport.
//
import PackageDescription

let package = Package(
    name: "PopopxTorKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PopopxTorKit", targets: ["PopopxTorKit"]),
        .library(name: "PopopxTorUI", targets: ["PopopxTorUI"])
    ],
    targets: [
        .target(
            name: "PopopxTorKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PopopxTorUI",
            dependencies: ["PopopxTorKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PopopxTorKitTests",
            dependencies: ["PopopxTorKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
