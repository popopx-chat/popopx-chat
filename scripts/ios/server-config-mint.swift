// POPOPX signed server-cluster frame generator — operator tooling, never shipped.
//
// Why this exists outside the app target
// --------------------------------------
// The app can only ever *verify*. Its trust anchor is a public key, and a build that could also mint
// frames would carry the private key on the device, which is not a trust anchor at all. So the positive
// leg of the signature — "a genuine frame is accepted" — cannot be proved by anything that ships, and
// the unit tests in `POPOPX Snapshots/SnapshotTests.swift` deliberately assert only the negative half.
//
// This tool closes that gap offline. It writes the same bytes the service writes, so its output can be
// fed through the real app codec: `PopopxServerConfigWire.decodeConfigFrame` must accept it, and
// `PopopxServerConfigTrust.verify` must accept it over the received compressed segment.
//
// The encoding lives here and nowhere else in this repository. That is not tidiness: the signed form is
// "the transmitted bytes, in the order the generator emitted them", and a second encoder in the app —
// particularly one using `JSONEncoder`, which does not preserve key order — would eventually be used to
// "check" a signature by re-serialising a decoded payload. Re-serialising produces different bytes and so
// rejects the frame; the app therefore decodes and never encodes, and this file is the only encoder.
//
// Key order below is copied from the service's `ConfigBody.to_wire`, which is the definition of the signed
// form: v, seq, kid, enc, iat, exp, smp, xftp, ntf, relay, ice, pol. `kid` precedes `enc`. A frame signed
// with any other order verifies here and fails on every device, which is the worst possible failure mode
// for a mechanism whose entire purpose is to be invisible.
//
// Compression is Apple's `COMPRESSION_ZLIB`, which is the RFC 1951 *payload* in both directions: measured
// against the system SDK it neither writes nor reads the `0x78 0xDA` header or the Adler-32 trailer that
// the service's `zlib.compressobj(9, DEFLATED, 15, 9)` puts around the same deflate bytes. This file
// therefore writes the RFC 1950 framing itself — header, Apple's payload, big-endian checksum — which is
// what makes its output interchangeable with a frame the service signs, and what the device's inflater
// expects to find.
// The two encoders are still not required to emit identical *bytes* for one body: level and memLevel
// differ, so a segment minted here can be a few characters longer or shorter than the service's. They must
// be interchangeable as streams, and that is what this file proves.
//
// Usage
// -----
//     swift scripts/ios/server-config-mint.swift \
//         --key ~/popopx-server-config/server-config-signing-key.pem \
//         --seq 7 \
//         --expires-epoch "$(date -v+7d +%s)" \
//         --smp '<43-char-fingerprint>@smp7.popopx.im' \
//         --smp '<43-char-fingerprint>@smp8.popopx.im,<32-char-onion>.onion \
//         --xftp '<fingerprint>@xftp1.popopx.im' \
//         --ntf  '<fingerprint>@ntf3.popopx.im' \
//         --relay 'relay1.popopx.im@<43-char-key>' \
//         --ice  'turns@turn.example.net:443,tcp,<expiryEpoch>:<user>,<base64 credential>,<credentialExpiry>' \
//              // an ICE host is not domain-checked: the generator applies no admission rule to `ice`, and its
//              // own cluster publishes a TURN host outside the domains this device dials servers in
//         --ack
//
// The frame text is printed alone on the last line of stdout, so it can be piped or pasted into a direct
// chat with a device. The private key is never printed and never written; the public key is printed,
// because that is how the pairing with the device's trust anchor is checked.
//
// The key may be a PEM `PrivateKeyInfo`, a 32-byte seed, or a 64-byte NaCl secret key. There is
// deliberately no option to pass key material on the command line: argv is visible to other processes and
// kept in shell history.
//
// Nothing here is compiled into the app, and adding it to an Xcode target would be a mistake.

import Compression
import CryptoKit
import Foundation

// MARK: - Limits, restated

// The device's own ceilings (`PopopxServerConfigLimits`), restated here because this file must run without
// the app module. The device is the authority: anything it would refuse is refused here first, so an
// operator learns about it at signing time rather than after delivery.
let maximumSegmentCharacters = 1_024
let signatureSegmentCharacters = 86
let tokenPrefix = "POPOPXCFG1-"
let controlPrefix = "::popopx_sys::SERVER_CFG_V1::"
/// The exact bytes the signature covers, ahead of the compressed segment: `wire.py` builds
/// `CFG_DOMAIN + compressed_b64u.encode("ascii")`, and neither the token prefix, the dot, nor the
/// signature is inside the signed region.
let signatureDomain = "popopx|popx_srv_cfg_v1|"
let formatVersion = 1
let encodingTag = "z9"
let maximumInflatedBytes = 65_536
let maximumValiditySeconds = 30 * 24 * 60 * 60
let maximumCounterValue = 9_007_199_254_740_992
let admittedSuffixes = [".popopx.chat", ".popopx.im"]
let base64URLAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
let hexAlphabet = "0123456789abcdef"
let iceSchemes = ["stun", "stuns", "turn", "turns"]
let credentialRequiringSchemes = ["turn", "turns"]
let iceTransports = ["udp", "tcp"]
// Mirrors PopopxServerConfigLimits in PopopxServerClusterConfig.swift; keep the two in step.
let rosterCeilings: [String: Int] = ["smp": 10, "xftp": 4, "ntf": 4, "relay": 2, "ice": 3]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("mint: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Arguments

struct Entry {
    let key: String
    let host: String
    let onion: String?
}

struct Ice {
    let scheme: String
    let host: String
    let port: Int
    let transport: String?
    let username: String?
    let credential: String?
    let expiresAt: Int?
}

struct Options {
    /// The retired development key is not a default any more: minting against a key the shipped app no
    /// longer trusts is the one mistake this tool could make silently, so the expected anchor is the
    /// production key and `--key` must be pointed at its counterpart.
    var keyPath = "\(NSHomeDirectory())/popopx-server-config/server-config-signing-key.pem"
    var expectPublicKeyHex = "d3941ecfa89f4e6d916cebc103a79fe3b6dd37ca8bbbc2087f70d7dece5aab6e"
    var seq = 0
    var expiresAt = 0
    var smp: [Entry] = []
    var xftp: [Entry] = []
    var ntf: [Entry] = []
    var relay: [(host: String, key: String)] = []
    var ice: [Ice] = []
    var ack = false
    var minSeq = 1
    var installWindow = 3600
    var rollout = 100
    var ttl = 7 * 24 * 60 * 60
}

var options = Options()
let arguments = Array(CommandLine.arguments.dropFirst())
var cursor = 0

func takeValue(for flag: String) -> String {
    guard cursor + 1 < arguments.count else { fail("\(flag) requires a value") }
    cursor += 1
    return arguments[cursor]
}

func takeInteger(for flag: String) -> Int {
    guard let number = Int(takeValue(for: flag)) else { fail("\(flag) wants an integer") }
    return number
}

while cursor < arguments.count {
    let flag = arguments[cursor]
    switch flag {
    case "--key": options.keyPath = takeValue(for: flag)
    case "--expect-pubkey": options.expectPublicKeyHex = takeValue(for: flag).lowercased()
    case "--seq": options.seq = takeInteger(for: flag)
    case "--expires-epoch": options.expiresAt = takeInteger(for: flag)
    case "--smp": options.smp.append(serverEntry(takeValue(for: flag), roster: "smp"))
    case "--xftp": options.xftp.append(serverEntry(takeValue(for: flag), roster: "xftp"))
    case "--ntf": options.ntf.append(serverEntry(takeValue(for: flag), roster: "ntf"))
    case "--relay":
        let parts = splitFields(takeValue(for: flag), roster: "relay")
        // `<host>@<key>`: the relay pair is the only roster that leads with the name, matching the wire
        // order `[host, key]` rather than `[key, host]`.
        guard parts.count == 2 else { fail("relay wants '<host>@<key>'") }
        options.relay.append((host: hostname(parts[0], roster: "relay"), key: relayKey(parts[1])))
    case "--ice": options.ice.append(iceEntry(takeValue(for: flag)))
    case "--ack": options.ack = true
    case "--min-seq": options.minSeq = takeInteger(for: flag)
    case "--install-window": options.installWindow = takeInteger(for: flag)
    case "--rollout": options.rollout = takeInteger(for: flag)
    case "--ttl": options.ttl = takeInteger(for: flag)
    default: fail("unknown argument \(flag)")
    }
    cursor += 1
}

// MARK: - Field grammars

/// Splits `a@b,c,d` into its fields. None of the grammars below can contain a comma or an at-sign, so a
/// plain split is exact rather than a heuristic.
func splitFields(_ text: String, roster: String) -> [String] {
    text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
}

func containsUnsafeCharacters(_ text: String) -> Bool {
    // The envelope travels as one chat message line, and the generator refuses these outright: a stray
    // newline in the signed body breaks framing on the wire, not just the signature.
    text.contains("\n") || text.contains("\r") || text.contains("\0")
}

/// A v3 onion service id: 56 characters of the lowercase base32 alphabet, no padding.
func isOnionServiceId(_ text: String) -> Bool {
    let allowed = Set("abcdefghijklmnopqrstuvwxyz234567")
    return text.count == 56 && text.allSatisfy { allowed.contains($0) }
}

/// Checks the spelling of a host, and — for the rosters a device dials — that it is one of the domains the
/// device admits. `admission: false` is the ICE roster: the generator applies no domain rule to it, so a
/// cluster naming a TURN host outside this organization still has to be mintable byte-for-byte.
func hostname(_ text: String, roster: String, admission: Bool = true) -> String {
    let lowered = text.lowercased()
    let allowed = "abcdefghijklmnopqrstuvwxyz0123456789.-"
    guard !lowered.isEmpty else { fail("\(roster): empty host") }
    guard lowered.count <= 253 else { fail("\(roster): host longer than 253 characters") }
    guard lowered.allSatisfy({ allowed.contains($0) }) else {
        fail("\(roster): host carries characters outside a-z, 0-9, '.' and '-': \(lowered)")
    }
    let labels = lowered.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2 else { fail("\(roster): host needs at least two labels: \(lowered)") }
    guard !labels.contains(where: { $0.isEmpty }) else { fail("\(roster): host has an empty label: \(lowered)") }
    for label in labels {
        guard !label.hasPrefix("-"), !label.hasSuffix("-") else { fail("\(roster): label starts or ends with '-': \(lowered)") }
    }
    if lowered.hasSuffix(".onion") {
        let name = String(lowered.dropLast(".onion".count))
        guard isOnionServiceId(name) else {
            fail("\(roster): onion service id is not 56 characters of a-z2-7")
        }
        return lowered
    }
    guard !admission || admittedSuffixes.contains(where: { lowered.hasSuffix($0) }) else {
        fail("\(roster): host is outside the addresses the device admits (\(admittedSuffixes.joined(separator: ", "))): \(lowered)")
    }
    return lowered
}

func serverKey(_ text: String, roster: String) -> String {
    // The generator accepts one trailing '=' on the way in and signs the unpadded spelling: its encoder
    // strips it, so `wire.decode` re-encoding a padded body produces different bytes and refuses the frame
    // ("decoded body does not re-encode to the signed bytes", wire.py:318-320). Padded input from the
    // shipped presets is therefore normalized here rather than preserved.
    let core = text.hasSuffix("=") ? String(text.dropLast()) : text
    guard core.count == 43, core.allSatisfy({ base64URLAlphabet.contains($0) }) else {
        fail("\(roster): fingerprint must be 43 base64url characters, optionally with one '='")
    }
    return core
}

/// A relay key is the one place padding is not accepted, because the generator compares it at exactly 43.
func relayKey(_ text: String) -> String {
    guard text.count == 43, text.allSatisfy({ base64URLAlphabet.contains($0) }) else {
        fail("relay: key must be exactly 43 base64url characters with no padding")
    }
    return text
}

func onion(_ text: String, roster: String) -> String {
    let lowered = text.lowercased()
    guard lowered.hasSuffix(".onion"), lowered.count == 57 else { fail("\(roster): onion alternate is not a v3 address") }
    let name = String(lowered.dropLast(".onion".count))
    guard isOnionServiceId(name) else {
        fail("\(roster): onion service id is not base32 lowercase")
    }
    return lowered
}

func serverEntry(_ text: String, roster: String) -> Entry {
    let parts = splitFields(text, roster: roster)
    guard parts.count == 1 || parts.count == 2 else {
        fail("\(roster): want '<key>@<host>' or '<key>@<host>,<onion>'")
    }
    let head = parts[0].split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard head.count == 2 else { fail("\(roster): '<key>@<host>' is missing its '@'") }
    return Entry(
        key: serverKey(head[0], roster: roster),
        host: hostname(head[1], roster: roster),
        onion: parts.count == 2 ? onion(parts[1], roster: roster) : nil
    )
}

func restUsername(_ text: String) -> Bool {
    // `<digits>:<token>`, the shape TURN REST credentials always take: the first field is a lifetime, so
    // an operator can see how long a leaked line stays useful.
    let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2 else { return false }
    guard !parts[0].isEmpty, parts[0].count <= 12, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
    guard !parts[1].isEmpty, parts[1].count <= 64 else { return false }
    return parts[1].allSatisfy({ base64URLAlphabet.contains($0) })
}

func restCredential(_ text: String) -> Bool {
    // Standard base64 (padding included, `+` and `/` allowed) decoding to exactly the 20 bytes RFC 5766
    // defines — not the URL-safe alphabet, which is what the server fingerprints use.
    let standard = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    guard text.unicodeScalars.allSatisfy({ standard.contains($0) }) else { return false }
    guard let data = Data(base64Encoded: text), data.count == 20 else { return false }
    return true
}

func iceEntry(_ text: String) -> Ice {
    let parts = splitFields(text, roster: "ice")
    guard parts.count >= 1, parts.count <= 5 else {
        fail("ice: want '<scheme>@<host>:<port>' plus optional ',<transport>,<username>,<credential>,<expiry>'")
    }
    let head = parts[0].split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard head.count == 2 else { fail("ice: '<scheme>@<host>:<port>' is missing its '@'") }
    let scheme = head[0].lowercased()
    guard iceSchemes.contains(scheme) else { fail("ice: scheme is not one of \(iceSchemes.joined(separator: ", "))") }
    let location = head[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard location.count == 2, let port = Int(location[1]) else { fail("ice: host:port is malformed") }
    guard port >= 1, port <= 65_535 else { fail("ice: port outside 1...65535") }
    let transport = parts.count >= 2 ? parts[1].lowercased() : nil
    if let transport {
        guard iceTransports.contains(transport) else { fail("ice: transport is not udp or tcp") }
    }
    let username = parts.count >= 3 ? parts[2] : nil
    let credential = parts.count >= 4 ? parts[3] : nil
    // `x` is the lifetime of the credential, and the generator validates it for every scheme, so a stun
    // entry can carry one too.
    var expires: Int?
    if parts.count == 5 {
        guard let parsed = Int(parts[4]), parsed >= 1, parsed <= maximumCounterValue else {
            fail("ice: expiry must be a positive integer within the JSON ceiling")
        }
        expires = parsed
    }
    if credentialRequiringSchemes.contains(scheme) {
        guard let username, restUsername(username) else {
            fail("ice: \(scheme) requires a REST username of the form '<digits>:<token>'")
        }
        guard let credential, restCredential(credential) else {
            fail("ice: \(scheme) requires a base64 credential decoding to 20 bytes")
        }
    } else {
        guard username == nil, credential == nil else {
            fail("ice: \(scheme) carries credentials, which the device refuses")
        }
    }
    return Ice(
        scheme: scheme,
        host: hostname(location[0], roster: "ice", admission: false),
        port: port,
        transport: transport,
        username: username,
        credential: credential,
        expiresAt: expires
    )
}

// MARK: - Validation

if options.seq < 1 { fail("--seq is required and must be at least 1") }
if options.seq > maximumCounterValue { fail("--seq exceeds the JSON integer ceiling") }
if options.expiresAt <= 0 { fail("--expires-epoch is required: a frame without an expiry is a permanent instruction") }
let now = Int(Date().timeIntervalSince1970)
if options.expiresAt > maximumCounterValue { fail("--expires-epoch exceeds the JSON integer ceiling") }
if options.expiresAt <= now { fail("the frame would already be expired on delivery") }
if options.expiresAt - now > maximumValiditySeconds {
    fail("the device refuses a validity span over \(maximumValiditySeconds) seconds (30 days)")
}
for (roster, count) in [("smp", options.smp.count), ("xftp", options.xftp.count), ("ntf", options.ntf.count),
                        ("relay", options.relay.count), ("ice", options.ice.count)] {
    guard count <= rosterCeilings[roster]! else {
        fail("\(roster): the device accepts at most \(rosterCeilings[roster]!) entries")
    }
}
if options.smp.isEmpty { fail("at least one --smp is required: a cluster with no messaging server is not a cluster") }
if options.minSeq < 1 { fail("--min-seq must be at least 1") }
if options.installWindow < 1 { fail("--install-window must be at least 1") }
if options.rollout < 1 || options.rollout > 100 { fail("--rollout must be within 1...100") }
if options.ttl < 1 { fail("--ttl must be at least 1") }
if options.minSeq > options.seq {
    fail("--min-seq above --seq would revoke the very generation carrying it, so every device refuses the frame")
}
var textsToScan = [options.expectPublicKeyHex]
for entry in options.smp + options.xftp + options.ntf {
    textsToScan.append(contentsOf: [entry.key, entry.host, entry.onion ?? ""])
}
for entry in options.relay { textsToScan.append(contentsOf: [entry.host, entry.key]) }
for entry in options.ice { textsToScan.append(contentsOf: [entry.host, entry.username ?? "", entry.credential ?? ""]) }
for text in textsToScan {
    if containsUnsafeCharacters(text) { fail("an input carries a newline or a NUL") }
}
if !options.expectPublicKeyHex.allSatisfy({ hexAlphabet.contains($0) }) || options.expectPublicKeyHex.count != 64 {
    fail("--expect-pubkey must be 64 hexadecimal characters")
}

// MARK: - Signing key

func readKeyData() -> Data {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: options.keyPath)) else {
        fail("cannot read \(options.keyPath)")
    }
    return data
}

/// The 32-byte Ed25519 seed inside a PKCS#8 `PrivateKeyInfo`.
///
/// Located by finding the one `OCTET STRING` of length 32, then confirmed by the only check that proves the
/// read: the public key derived from it must match the anchor this tool expects. A parser that silently
/// returned the wrong 32 bytes fails there rather than signing something no device accepts.
func extractSeed(from data: Data) -> Data? {
    let bytes = [UInt8](data)
    if bytes.count == 32 { return data }
    if bytes.count == 64 { return Data(bytes[0..<32]) }
    var position = 0
    while position + 34 <= bytes.count {
        if bytes[position] == 0x04, bytes[position + 1] == 0x20 {
            return Data(bytes[(position + 2)...(position + 33)])
        }
        position += 1
    }
    return nil
}

let rawKey = readKeyData()
guard let seed = extractSeed(from: rawKey) else {
    fail("no Ed25519 key found in \(options.keyPath) (expected PEM, a 32-byte seed or a 64-byte secret key)")
}
guard let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    fail("the seed is not a usable Ed25519 key")
}
let publicKeyHex = signingKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
print("public key: \(publicKeyHex)")
guard publicKeyHex == options.expectPublicKeyHex else {
    fail("this key does not match the trust anchor the shipped app carries (\(options.expectPublicKeyHex)); pass --expect-pubkey only when minting for a development build")
}
print("public key matches the expected anchor")

/// `kid = "k-" + first ten hex of SHA-256 over the raw 32-byte public key` — the generator's recipe, so a
/// frame names the key that signed it and the device can refuse a frame presented under another key.
func keyID(for publicKey: Curve25519.Signing.PublicKey) -> String {
    let digest = SHA256.hash(data: publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
    return "k-" + String(digest.prefix(10))
}
let keyId = keyID(for: signingKey.publicKey)
print("key id: \(keyId)")

// MARK: - Canonical body

/// JSON in the generator's house form: insertion order, no whitespace, no ASCII escaping.
///
/// Written by hand rather than with `JSONEncoder` because `JSONEncoder` does not preserve key order, and
/// the order is the signed form. Escaping matches `json.dumps(..., ensure_ascii=False,
/// separators=(",", ":"))` for every value this tool can produce: quotation mark, reverse solidus, and the
/// control characters that are not newlines or tabs (those two are refused as inputs above, and the
/// generator refuses them too).
func jsonString(_ text: String) -> String {
    var result = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        default:
            if scalar.value < 0x20 { result += String(format: "\\u%04x", scalar.value) }
            else { result.unicodeScalars.append(scalar) }
        }
    }
    return result + "\""
}

func serverArray(_ entries: [Entry]) -> String {
    "[" + entries.map { entry in
        let fields = [jsonString(entry.key), jsonString(entry.host)] + (entry.onion.map { [jsonString($0)] } ?? [])
        return "[" + fields.joined(separator: ",") + "]"
    }.joined(separator: ",") + "]"
}

func iceArray(_ entries: [Ice]) -> String {
    // `IceEntry.to_wire` (models.py:239-247) emits t, h, p, then tr, u, c, x only when set, and every key is
    // a quoted JSON string. An unquoted key here is not a shorter spelling of the same body: it is invalid
    // JSON, which the device refuses and the service refuses to re-encode.
    "[" + entries.map { entry in
        var fields: [(String, String)] = [
            ("t", jsonString(entry.scheme)),
            ("h", jsonString(entry.host)),
            ("p", String(entry.port)),
        ]
        if let transport = entry.transport { fields.append(("tr", jsonString(transport))) }
        if let username = entry.username { fields.append(("u", jsonString(username))) }
        if let credential = entry.credential { fields.append(("c", jsonString(credential))) }
        if let expiresAt = entry.expiresAt { fields.append(("x", String(expiresAt))) }
        let inner = fields.map { "\(jsonString($0.0)):\($0.1)" }.joined(separator: ",")
        return "{" + inner + "}"
    }.joined(separator: ",") + "]"
}

/// The 12 keys, in the order `ConfigBody.to_wire` emits them. `iat` is the moment of minting: the device
/// checks `exp > iat` and the span, so a copied clock here is a copied refusal there.
func canonicalBody() -> Data {
    let iat = now
    let policy = "{"
        + "\"ack\":\(jsonString(options.ack ? "on" : "off")),"
        + "\"ms\":\(options.minSeq),"
        + "\"iw\":\(options.installWindow),"
        + "\"ro\":\(options.rollout),"
        + "\"ttl\":\(options.ttl)}"
    let relay = "[" + options.relay.map { "[" + jsonString($0.host) + "," + jsonString($0.key) + "]" }
        .joined(separator: ",") + "]"
    let json = "{"
        + "\"v\":\(formatVersion),"
        + "\"seq\":\(options.seq),"
        + "\"kid\":\(jsonString(keyId)),"
        + "\"enc\":\(jsonString(encodingTag)),"
        + "\"iat\":\(iat),"
        + "\"exp\":\(options.expiresAt),"
        + "\"smp\":\(serverArray(options.smp)),"
        + "\"xftp\":\(serverArray(options.xftp)),"
        + "\"ntf\":\(serverArray(options.ntf)),"
        + "\"relay\":\(relay),"
        + "\"ice\":\(iceArray(options.ice)),"
        + "\"pol\":\(policy)}"
    guard let data = json.data(using: .utf8) else { fail("the body is not UTF-8") }
    return data
}

let body = canonicalBody()

// MARK: - Compress, sign, assemble

/// zlib, as the generator writes it: a `wbits=15` stream — the two-byte header `0x78 0xDA`, the deflate
/// payload, then the Adler-32 of the *uncompressed* bytes big-endian.
///
/// Apple's `COMPRESSION_ZLIB` supplies the payload and nothing else: measured on the system SDK, it both
/// writes and reads RFC 1951 without the RFC 1950 framing, so the header and the trailer are added here.
/// A device that was handed raw deflate could not tell it from a real stream by looking at the header, and
/// the Python engine refuses the frame outright, so this is the one place the framing has to be produced.
func deflate(_ data: Data) -> Data {
    // Deflate expands incompressible input; two copies plus a page of margin is the usual worst case, and
    // a full buffer is reported rather than silently truncated.
    let capacity = max(64, data.count * 2 + 4096)
    var destination = [UInt8](repeating: 0, count: capacity)
    var payload = Data()
    data.withUnsafeBytes { sourceBytes in
        destination.withUnsafeMutableBytes { destinationBytes in
            guard let sourceStart = sourceBytes.bindMemory(to: UInt8.self).baseAddress,
                  let destinationStart = destinationBytes.bindMemory(to: UInt8.self).baseAddress else {
                fail("the body could not be read for compression")
            }
            var stream = compression_stream(
                dst_ptr: destinationStart,
                dst_size: 0,
                src_ptr: sourceStart,
                src_size: 0,
                state: nil
            )
            guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
                    == COMPRESSION_STATUS_OK else {
                fail("the zlib encoder could not be initialised")
            }
            defer { compression_stream_destroy(&stream) }
            // Attached after `compression_stream_init`, which zeroes every field except `state`
            // (compression.h:384); a stream built with the buffers in its initialiser reaches the first
            // process call with no input and no output room.
            stream.dst_ptr = destinationStart
            stream.dst_size = capacity
            stream.src_ptr = sourceStart
            stream.src_size = data.count
            let finalize = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            while true {
                let status = compression_stream_process(&stream, finalize)
                if status == COMPRESSION_STATUS_END {
                    payload = Data(bytes: destinationStart, count: capacity - stream.dst_size)
                    return
                }
                guard status == COMPRESSION_STATUS_OK else { fail("the body could not be compressed") }
                if stream.dst_size == 0 { fail("the compressed body exceeded its buffer") }
                if stream.src_size == 0 { fail("the compressor consumed the body without finishing it") }
            }
        }
    }
    var stream = Data([0x78, 0xDA])
    stream.append(payload)
    let checksum = adler32(data)
    stream.append(UInt8((checksum >> 24) & 0xFF))
    stream.append(UInt8((checksum >> 16) & 0xFF))
    stream.append(UInt8((checksum >> 8) & 0xFF))
    stream.append(UInt8(checksum & 0xFF))
    return stream
}

/// RFC 1950's checksum over the uncompressed bytes, the same value `zlib.compressobj().flush()` appends.
func adler32(_ data: Data) -> UInt32 {
    var low: UInt32 = 1
    var high: UInt32 = 0
    for byte in data {
        low = (low + UInt32(byte)) % 65521
        high = (high + low) % 65521
    }
    return (high << 16) | low
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

guard body.count <= maximumInflatedBytes else {
    fail("the body inflates to \(body.count) bytes, over the device ceiling of \(maximumInflatedBytes)")
}
let compressed = deflate(body)
let compressedText = base64URL(compressed)

// The signature covers the domain prefix plus the compressed segment as ASCII — not the body, not the
// token, and not the frame. Signing anything else produces a frame this tool accepts and no device does.
guard let signature = try? signingKey.signature(
    for: Data((signatureDomain + compressedText).utf8)
) else { fail("signing failed") }
let signatureText = base64URL(signature)
let segment = tokenPrefix + compressedText + "." + signatureText
let frame = controlPrefix + segment

/// The receipt half the device sends once a configuration proves itself: sixteen hex characters of
/// SHA-256 over the *inflated* body. Printed so an operator can compare it against the log line.
func bodyHash(of data: Data) -> String {
    String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16))
}

print("body bytes: \(body.count)")
print("compressed bytes: \(compressed.count)")
print("segment characters: \(segment.count) (device ceiling \(maximumSegmentCharacters))")
print("signature segment: \(signatureText.count) characters")
print("frame characters: \(frame.count) (line includes the \(controlPrefix.count)-character control prefix)")
print("body hash: \(bodyHash(of: body))")
print("expires: \(Date(timeIntervalSince1970: TimeInterval(options.expiresAt)).formatted(.iso8601))")
guard signatureText.count == signatureSegmentCharacters else { fail("the signature is not 64 bytes") }
guard segment.unicodeScalars.count <= maximumSegmentCharacters else {
    fail("the device refuses a segment over \(maximumSegmentCharacters) characters")
}
print("send this text in a direct chat with the device:")
print(frame)
