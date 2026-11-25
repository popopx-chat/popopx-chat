//
//  PopopxMeshIdentityTests.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  `Data(popopxHex:)` is the only way a hex key becomes bytes again, and it sits on every hot path:
//  the engine decodes a peer's announced key, a `SYS_POPOPX_ACK:` key and a mapping-table key with
//  it, and each call site reads nil as "peer not found" rather than as a failure. Nothing in this
//  package exercised it with a real key, so a decoder that returned nil for essentially every
//  64-character input stayed green. These cases pin the number of characters read per byte, because
//  that width is the whole contract.
//

import Foundation
import Testing

import PopopxMeshKit

// MARK: - Fixtures

/// A seed with no high bits, so `meshPublicKeyHex` is a real X25519 public key rather than a
/// fabricated one. Fixed bytes keep the expected hex reproducible across runs.
private let testSeed = Data((0..<PopopxMeshIdentity.keyByteCount).map { UInt8($0) })

/// Every byte here has a zero high nibble, so two-character windows like "00" and "08" sit next to
/// each other and a three-character read asks for a value that does not fit in `UInt8`.
private let lowNibbles = Data((0..<PopopxMeshIdentity.keyByteCount).map { UInt8($0 * 8) })

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Tests

@Test("decodes exactly two characters per byte")
func decodesKnownVectors() {
    #expect(Data(popopxHex: "1b2c3d") == Data([0x1B, 0x2C, 0x3D]))
    #expect(Data(popopxHex: "00ff0a") == Data([0x00, 0xFF, 0x0A]))
    #expect(Data(popopxHex: "0a0b") == Data([0x0A, 0x0B]))
    #expect(Data(popopxHex: "ffff") == Data([0xFF, 0xFF]))
}

@Test("decodes the hex form of every byte value")
func decodesAllByteValues() {
    let allBytes = Data(0...255)
    #expect(Data(popopxHex: hex(allBytes)) == allBytes)
}

@Test("a real mesh public key survives the hex round trip")
func roundTripsGeneratedIdentity() throws {
    let identity = try #require(PopopxMeshIdentity(privateSeed: testSeed))
    let hexKey = identity.meshPublicKeyHex
    #expect(hexKey.count == PopopxMeshIdentity.keyByteCount * 2)
    // The failure this line exists for: the package formats a key the package cannot read back.
    let decoded = try #require(Data(popopxHex: hexKey))
    #expect(decoded == identity.publicKey)
    #expect(hex(decoded) == hexKey)
}

@Test("decodes a low-nibble key, the shape that used to return nil")
func decodesLowNibbleKey() {
    #expect(Data(popopxHex: hex(lowNibbles)) == lowNibbles)
}

@Test("round trips arbitrary key material")
func roundTripsArbitraryBytes() {
    for trial in 0..<64 {
        let bytes = Data((0..<PopopxMeshIdentity.keyByteCount).map { UInt8(truncatingIfNeeded: trial &* 7 &+ $0 &* 31) })
        #expect(Data(popopxHex: hex(bytes)) == bytes)
    }
}

@Test("refuses input that cannot be bytes", arguments: [
    "1",
    "1b2",
    "1b2c3",
    "zz",
    "1b2g",
    " 1b2c",
    "1b 2c",
    "0x1b2c",
    "1b2c3d4e5f6g8h",
])
func rejectsMalformedInput(_ malformed: String) {
    #expect(Data(popopxHex: malformed) == nil)
}

@Test("empty input decodes to empty data, not nil")
func handlesEmptyInput() {
    #expect(Data(popopxHex: "")?.isEmpty == true)
}
