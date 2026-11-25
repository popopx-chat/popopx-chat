// swift-tools-version: 6.0
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
import PackageDescription

// No external dependencies: the Noise_XX layer is CryptoKit only, so nothing here can
// collide with the symbols already exported by libpopopx.a.
let package = Package(
    name: "PopopxMeshKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PopopxMeshKit", targets: ["PopopxMeshKit"]),
        .library(name: "PopopxMeshUI", targets: ["PopopxMeshUI"])
    ],
    targets: [
        .target(name: "PopopxMeshKit"),
        .testTarget(name: "PopopxMeshKitTests", dependencies: ["PopopxMeshKit"]),

        // Module 7: the SwiftUI surface. A separate target, so a host that wants the protocol stack
        // without a view layer still links only `PopopxMeshKit`, and so `PopopxMeshKit`'s own
        // warning count cannot be paid for by UI code.
        .target(
            name: "PopopxMeshUI",
            dependencies: ["PopopxMeshKit"]
        ),
        .testTarget(
            name: "PopopxMeshUITests",
            dependencies: ["PopopxMeshUI"]
        )
    ]
)
