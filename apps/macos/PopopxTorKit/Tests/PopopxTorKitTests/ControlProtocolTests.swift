//
//  ControlProtocolTests.swift
//  PopopxTorKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
@testable import PopopxTorKit
import XCTest

/// The framing layer, tested without a daemon: every case here is reachable by handing the parser
/// the exact bytes `tor` writes.
final class ControlProtocolTests: XCTestCase {
    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    /// Joins lines the way the daemon sends them — CRLF terminates every line, the last one
    /// included, and a reply is not complete until that terminator arrives.
    private func frame(_ lines: String...) -> String {
        lines.map { $0 + "\r\n" }.joined()
    }

    private func consume(_ text: String) -> [ControlMessage] {
        var parser = ControlProtocolParser()
        return parser.consume(bytes(text))
    }

    func testClosingLineCompletesASingleLineReply() {
        let messages = consume("250 OK\r\n")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].code, 250)
        XCTAssertEqual(messages[0].message, "OK")
        XCTAssertEqual(messages[0].status, .positive)
        XCTAssertFalse(messages[0].isEvent)
    }

    func testInterimLinesDoNotCompleteAReplyOnTheirOwn() {
        var parser = ControlProtocolParser()
        XCTAssertEqual(parser.consume(bytes("250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=45 TAG=done\r\n")).count, 0)
        let messages = parser.consume(bytes("250 OK\r\n"))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].lines.count, 1)
        XCTAssertTrue(messages[0].lines[0].hasPrefix("status/bootstrap-phase="))
    }

    func testTwoRepliesInOneChunkAreBothReturned() {
        let messages = consume("250 OK\r\n250 SIGNAL NEWNYM signaled to 127.0.0.1\r\n")
        XCTAssertEqual(messages.count, 2)
    }

    func testAReplySplitAcrossChunksIsReassembled() {
        var parser = ControlProtocolParser()
        XCTAssertEqual(parser.consume(bytes("250-status/boo")).count, 0)
        XCTAssertEqual(parser.consume(bytes("tstrap-phase=NOTICE BOOTSTRAP PROGRESS=100\r\n250 OK\r\n")).count, 1)
    }

    func testBareLineFeedIsAccepted() {
        XCTAssertEqual(consume("250 OK\n").count, 1)
    }

    func testPlusSectionCarriesInterimBodyWithoutItsPrefix() {
        let messages = consume(frame(
            "250+circuit-status=",
            "250-1 BUILT $7A1F~first,$8B2E~second,$9C3D~exit",
            "250-2 BUILT $1D4E~one,$2E5F~two,$3F60~three",
            "250 OK"
        ))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].lines, ["circuit-status="])
        XCTAssertEqual(messages[0].data.count, 2)
        XCTAssertFalse(messages[0].data[0].hasPrefix("250"), "the interim prefix is framing, not value")
        XCTAssertTrue(messages[0].data[0].hasPrefix("1 BUILT "))
    }

    func testPlusSectionTerminatedByASinglePeriod() {
        let messages = consume(frame(
            "650+status/client/orconn=1",
            "r TorButton AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "sAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 24000",
            ".",
            "650 OK"
        ))
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].isEvent)
        XCTAssertEqual(messages[0].data.count, 2)
    }

    func testErrorRepliesAreNotPositive() {
        let messages = consume("550 Invalid command\r\n")
        XCTAssertEqual(messages[0].status, .error)
        XCTAssertEqual(messages[0].code, 550)
    }

    func testGetInfoBodyIsJoinedPerKey() async throws {
        let script = [
            "250+circuit-status=\r\n250-1 BUILT $7A1F~a,$8B2E~b,$9C3D~c\r\n250 OK\r\n",
            "250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY=\"Done\"\r\n250 OK\r\n"
        ].map(bytes)
        let controller = TorController(transport: ScriptedTransport(replies: script))
        controller.startReading()
        defer { controller.shutdown() }

        let circuits = try await controller.getInfo(["circuit-status"])
        XCTAssertEqual(Array(circuits.keys), ["circuit-status"])
        XCTAssertTrue(circuits["circuit-status"]?.contains("1 BUILT ") == true)

        let phases = try await controller.getInfo(["status/bootstrap-phase"])
        XCTAssertEqual(BootstrapProgress.parse(phases["status/bootstrap-phase"] ?? "")?.percent, 100)
    }

    func testCommandSerialisationQuotesAndTerminates() {
        XCTAssertEqual(ControlCommand.protocolInfo, "PROTOCOLINFO 1\r\n")
        XCTAssertEqual(ControlCommand.newCircuit, "SIGNAL NEWNYM\r\n")
        XCTAssertEqual(ControlCommand.getInfo(["version", "circuit-status"]), "GETINFO version circuit-status\r\n")
        XCTAssertEqual(ControlCommand.setEvents(["BOOTSTRAP", "CIRC"]), "SETEVENTS BOOTSTRAP CIRC\r\n")
    }

    func testQuotingDefeatsArgumentInjection() {
        // A control-port argument that can close its own quoted string can also open a new command
        // on the same connection.
        let escaped = ControlCommand.quoted("a\"b\r\nc\\d")
        XCTAssertEqual(escaped, "\"a\\\"b\\r\\nc\\\\d\"")
        // `"\r\n"` is a single `Character`, so a character-wise escape pass leaves the pair intact and
        // hands back the argument with its second command still attached.
        XCTAssertFalse(escaped.contains("\r"), escaped)
        XCTAssertFalse(escaped.contains("\n"), escaped)
        XCTAssertEqual(ControlCommand.quoted("x\0y"), "\"x\\000y\"")
        XCTAssertFalse(ControlCommand.quoted("x\r\nSETCONF ControlPort=9051").contains("\r\n"))
    }

    func testTheAuthenticationSecretCannotAddALineToItsCommand() {
        let line = ControlCommand.authenticate(secret: "p\r\nSETCONF ControlPort=9051\r\n")
        XCTAssertTrue(line.hasPrefix("AUTHENTICATE \""), line)
        XCTAssertTrue(line.hasSuffix("\r\n"), line)
        XCTAssertEqual(line.unicodeScalars.filter { $0 == "\n" }.count, 1, "only the command terminator may be a newline: \(line)")
    }
}

final class BootstrapProgressTests: XCTestCase {
    func testGetInfoSpelling() {
        let progress = BootstrapProgress.parse(
            "NOTICE BOOTSTRAP PROGRESS=45 TAG=loading_descriptors SUMMARY=\"Loading relay descriptors\""
        )
        XCTAssertEqual(progress?.percent, 45)
        XCTAssertEqual(progress?.tag, "loading_descriptors")
        XCTAssertEqual(progress?.summary, "Loading relay descriptors")
        XCTAssertNil(progress?.warning)
        XCTAssertEqual(progress?.isComplete, false)
    }

    func testEventSpelling() {
        let progress = BootstrapProgress.parse("BOOTSTRAP 100 done")
        XCTAssertEqual(progress?.percent, 100)
        XCTAssertEqual(progress?.tag, "done")
        XCTAssertEqual(progress?.isComplete, true)
    }

    func testWarningLevelIsKept() {
        let progress = BootstrapProgress.parse("WARN BOOTSTRAP PROGRESS=95 TAG=done SUMMARY=\"Bootstrap error\"")
        XCTAssertEqual(progress?.warning, "WARN")
    }

    func testMalformedTextIsRejectedRatherThanGuessed() {
        XCTAssertNil(BootstrapProgress.parse("NOTICE BOOTSTRAP PROGRESS=done"))
        XCTAssertNil(BootstrapProgress.parse(""))
        XCTAssertNil(BootstrapProgress.parse("650 BW 1024 2048"))
    }
}

final class ProtocolInfoTests: XCTestCase {
    private typealias Method = ProtocolInfo.Method

    private func message(_ lines: [String], _ closing: String = "OK") -> ControlMessage {
        ControlMessage(code: 250, message: closing, lines: lines, data: [])
    }

    func testMethodsCookieFileAndVersionAreParsed() {
        let info = ProtocolInfo.parse(message([
            "AUTH METHODS=COOKIE,SAFECOOKIE COOKIEFILE=\"/tmp/tor/control_auth_cookie\""
        ], "OK"))
        XCTAssertEqual(info?.version, nil)
        XCTAssertEqual(info?.methods, [.cookie, .safeCookie])
        XCTAssertEqual(info?.cookieFile?.path, "/tmp/tor/control_auth_cookie")
    }

    func testVersionComesFromTheInfoLine() {
        // The daemon writes one key per `INFO` line, and the value of `Version` is the whole output
        // of `get_version()` — `"Tor 0.4.8.10"`, space included.
        let info = ProtocolInfo.parse(ControlMessage(
            code: 250,
            message: "OK",
            lines: [
                "AUTH METHODS=COOKIE COOKIEFILE=\"/tmp/tor/control_auth_cookie\"",
                "INFO Version=Tor 0.4.8.10",
                "INFO Tor=Yes",
                "INFO TorCookieAuthentication=1"
            ],
            data: []
        ))
        XCTAssertEqual(info?.version, "Tor 0.4.8.10")
    }

    func testAnInfoLineAboutSomethingElseIsNotReadAsAVersion() {
        let info = ProtocolInfo.parse(ControlMessage(
            code: 250,
            message: "OK",
            lines: ["AUTH METHODS=COOKIE", "INFO TorCookieAuthentication=1"],
            data: []
        ))
        XCTAssertNotNil(info)
        XCTAssertNil(info?.version)
    }

    func testNoneIsAMethodRatherThanTheAbsenceOfOne() throws {
        let info = try XCTUnwrap(ProtocolInfo.parse(message(["AUTH METHODS=NONE"], "OK")))
        XCTAssertEqual(info.methods, [.none])
        XCTAssertEqual(info.preferredMethod(), Method.none)
    }

    func testCookieIsPreferredOverTheUnimplementedHandshakes() throws {
        let info = try XCTUnwrap(ProtocolInfo.parse(message(["AUTH METHODS=SAFECOOKIE,HASHEDPASSWORD,COOKIE"], "OK")))
        XCTAssertEqual(info.preferredMethod(), Method.cookie)
    }

    func testAnEmptyMethodListIsNotParsedAsNoAuthenticationRequired() {
        XCTAssertNil(ProtocolInfo.parse(message(["AUTH"], "OK")))
    }

    func testCookieCredentialIsHexEncodedAndQuoted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("control_auth_cookie")
        let secret = Data((0..<32).map { UInt8($0 + 1) })
        try secret.write(to: file)
        let credential = try ControlAuthentication.cookie(file: file).credential()
        XCTAssertEqual(credential, "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
        let line = try ControlAuthentication.cookie(file: file).commandLine()
        XCTAssertTrue(line.hasPrefix("AUTHENTICATE \""))
        XCTAssertTrue(line.hasSuffix("\r\n"))
    }

    func testAShortCookieFileIsRejectedRatherThanPadded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("control_auth_cookie")
        try Data([1, 2, 3]).write(to: file)
        XCTAssertThrowsError(try ControlAuthentication.cookie(file: file).credential())
    }
}

final class TorExitNodeTests: XCTestCase {
    private let guardFingerprint = "7A1F" + String(repeating: "0", count: 36)
    private let middleFingerprint = "8B2E" + String(repeating: "0", count: 36)
    private let exitFingerprint = "9C3D" + String(repeating: "0", count: 36)

    func testBuiltGeneralCircuitReportsItsLastHop() {
        let line = """
        1 GENERAL BUILT 3:$\(guardFingerprint)~guard,5:$\(middleFingerprint)~mid,9:$\(exitFingerprint)~exitname 2026-11-23T09:00:00
        """
        let node = TorExitNode.parse(circuitStatus: line)
        XCTAssertEqual(node?.fingerprint, exitFingerprint)
        XCTAssertEqual(node?.nickname, "exitname")
        XCTAssertEqual(node?.terminatesInsideNetwork, false)
        XCTAssertEqual(node?.display, "exitname (\(exitFingerprint.prefix(8)))")
    }

    func testAShortChainIsReportedAsTerminatingInsideTheNetwork() {
        let line = "2 GENERAL BUILT 3:$\(guardFingerprint)~guard,5:$\(middleFingerprint)~rendezvous"
        let node = TorExitNode.parse(circuitStatus: line)
        XCTAssertEqual(node?.fingerprint, middleFingerprint)
        XCTAssertEqual(node?.terminatesInsideNetwork, true)
    }

    func testHalfBuiltCircuitReportsNothing() {
        let line = "1 GENERAL EXTENDED 3:$\(guardFingerprint)~guard,5:$\(middleFingerprint)~mid"
        XCTAssertNil(TorExitNode.parse(circuitStatus: line))
    }

    func testCircuitsWithNoExitAreNotMistakenForGeneralCircuits() {
        let line = "1 HS-DIRCIRCLE BUILT 3:$\(guardFingerprint)~guard"
        XCTAssertNil(TorExitNode.parse(circuitStatus: line))
    }

    func testANonHexFingerprintIsRejectedRatherThanDisplayed() {
        let line = "1 GENERAL BUILT 3:$7A1F~guard,5:$8B2E~mid,9:$9C3D~exitname"
        XCTAssertNil(TorExitNode.parse(circuitStatus: line))
    }

    func testDisplayNeverInventsANickname() {
        let node = TorExitNode(fingerprint: "F" + String(repeating: "0", count: 39), nickname: nil, terminatesInsideNetwork: false)
        XCTAssertEqual(node.display, "F" + String(repeating: "0", count: 39))
    }
}

final class BridgeLineTests: XCTestCase {
    func testObfs4LineParsesIntoArguments() {
        let line = "obfs4 5.6.7.9:9001 6991B3A5E9A4003B9D4C000000000000000000AB cert=Y3R58B22 iat-mode=0"
        let bridge = BridgeLine(line)
        XCTAssertEqual(bridge?.transport, .obfs4)
        XCTAssertEqual(bridge?.address, "5.6.7.9:9001")
        XCTAssertEqual(bridge?.fingerprint?.count, 40)
        XCTAssertEqual(bridge?.arguments["cert"], "Y3R58B22")
        XCTAssertEqual(bridge?.arguments["iat-mode"], "0")
        XCTAssertEqual(bridge?.isValid, true)
        XCTAssertEqual(bridge?.line, line)
    }

    func testObfs4WithoutCertificateIsParsedButNotValid() {
        let bridge = BridgeLine("obfs4 5.6.7.9:9001 6991B3A5E9A4003B9D4C000000000000000000AB iat-mode=0")
        XCTAssertNotNil(bridge)
        XCTAssertEqual(bridge?.isValid, false)
    }

    func testTransportlessPasteIsRejected() {
        XCTAssertNil(BridgeLine("5.6.7.9:9001"))
    }

    func testUnknownTransportIsRejected() {
        XCTAssertNil(BridgeLine("wobfs4 5.6.7.9:9001 6991B3A5E9A4003B9D4C000000000000000000AB cert=x"))
    }

    func testSnowflakeNeedsNoArguments() {
        let bridge = BridgeLine("snowflake 192.0.2.1:443 fingerprint=FAKE")
        XCTAssertEqual(bridge?.transport, .snowflake)
        XCTAssertEqual(bridge?.address, "192.0.2.1:443")
        XCTAssertEqual(bridge?.isValid, true)
    }

    func testBlankAndWhitespaceLinesAreRejected() {
        XCTAssertNil(BridgeLine(""))
        XCTAssertNil(BridgeLine("   \n"))
    }

    func testArgumentWithoutValueRejectsTheLine() {
        XCTAssertNil(BridgeLine("obfs4 5.6.7.9:9001 6991B3A5E9A4003B9D4C000000000000000000AB cert= iat-mode=0"))
    }

    func testEveryTransportThisParserAcceptsNeedsAPluginBinary() throws {
        // `TorManager` refuses a bridge set rather than launching a daemon that cannot bootstrap, and
        // that refusal rests on every transport in the parser being external to `tor`. A new case
        // that is built into the daemon has to change this test, not silently widen the refusal.
        for transport in BridgeLine.Transport.allCases {
            XCTAssertEqual(transport.requiresClientPlugin, true, "\(transport)")
        }
        let obfs4 = try XCTUnwrap(
            BridgeLine("obfs4 5.6.7.9:9001 6991B3A5E9A4003B9D4C000000000000000000AB cert=Y3R58B22 iat-mode=0")
        )
        XCTAssertEqual([obfs4].requiringClientPlugin, [obfs4])
        // An incomplete line is rejected by the parser before the plugin question is ever asked.
        let withoutCert = try XCTUnwrap(
            BridgeLine("obfs4 5.6.7.9:9001 6991B3A5E9A4003B9D4C000000000000000000AB iat-mode=0")
        )
        XCTAssertEqual([withoutCert].requiringClientPlugin, [])
        XCTAssertEqual([BridgeLine]().requiringClientPlugin, [])
    }
}
