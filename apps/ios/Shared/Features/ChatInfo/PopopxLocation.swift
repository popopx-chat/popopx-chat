//
//  PopopxLocation.swift
//  POPOPX (iOS)
//
//  Payload layer of "send location": on the network a location message is just the one line of text produced by `wireString` below.
//
//  This layer deliberately touches neither MapKit nor CoreLocation:
//
//  1. It has to speak the same bytes at both the sending (ComposeView) and rendering (PopopxMessageBubble) ends, and neither of those ends
//     needs any map capability, only the two Doubles and their outward text form.
//  2. `Map` / `CLLocationManager` appear in one file only, PopopxLocationPickerSheet.swift,
//     so one fewer import is one fewer entry point that can be misused.
//  3. Encoding and decoding are pure string arithmetic and can be verified apart from the UI and the system frameworks. The cases are committed:
//     `PopopxLocationPayloadTests` in POPOPX Snapshots/SnapshotTests.swift - 24 test methods, 56 assertion macros on 49 lines, the round-trip case running over 19 field-value pairs.
//     That file is the project's only unit-test bundle (`com.apple.product-type.bundle.unit-test`, `TEST_HOST = POPOPX.app`), and
//     `@testable import POPOPX` at its top reaches this type; `Tests iOS` is a UI-test bundle and cannot see it. Run them with:
//     `xcodebuild test -project POPOPX.xcodeproj -scheme "POPOPX (iOS)" -destination 'platform=iOS Simulator,id=<udid>' -only-testing:'POPOPX Snapshots/PopopxLocationPayloadTests' CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` -- the flags of spec/client/testing.md section 4.
//     Chinese text, `&`, `#`, `=`, quotes, spaces, emoji, newlines and place names that look like payloads all come back unchanged; invite links,
//     out-of-range/`nan`/`inf` coordinates, missing coordinates, illegal UTF-8 escapes and stray hosts are all rejected.
//  4. This file lives in `Shared/Features/ChatInfo/` and was dragged into the `POPOPX (iOS)` target by hand (`.pbxproj`
//     with zero script changes). Drag one file fewer in and it is the whole project that reports the error, not just "a file is missing".
//  5. Namespace: `popopx:/` and `popopx://` are the prefixes of invite links (PopopxOfflineBridge.swift:94,
//     ChatUtils.swift:106, APITypes.swift:195), so `popopx://loc?...` therefore **must stay forever mutually exclusive with invite
//     links**: the host accepts only `loc`, the coordinates must be finite and inside range, and if any single condition fails the whole string is rejected.
//     This is a hard constraint, not a style question: if a `loc` string were judged an invite link by `hasPopopxLink`, it would take the connection-building path
//     and turn one location message into one add-a-contact.
//  6. The payload is input the receiver parses on its own initiative, so only `URLComponents` is used, never hand-cut strings.
//  7. The display copy and the map rendering are in `PopopxLocationCardBubble` of PopopxMessageBubble.swift,
//     and the picker is in PopopxLocationPickerSheet.swift.
//

import Foundation

/// The payload of one location message.
///
/// The on-wire form is two lines of text, and `messageContent` sends the latter:
///
/// ```text
/// 📍 [location] Shenzhen North Railway Station (22.543096, 114.057865)
/// popopx://loc?lat=22.543096&lon=114.057865&name=%E6%B7%B1%E5%9C%B3%E5%8C%97%E7%AB%99
/// ```
///
/// The first line is for people: if the receiver is not POPOPX (or this card has not rendered yet), what it sees is one readable line of Chinese
/// plus a run of coordinates, not a bare scheme.
struct PopopxLocationPayload: Hashable, Sendable {
    /// Latitude, -90...90.
    var latitude: Double
    /// Longitude, -180...180.
    var longitude: Double
    /// Place name; when absent the UI uses the coordinates themselves as the name (`displayName`).
    var name: String?
    /// Detailed address, for display only - it plays no part in any decision.
    var address: String?

    init(
        latitude: Double,
        longitude: Double,
        name: String? = nil,
        address: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name?.popopxTrimmedOrNil
        self.address = address?.popopxTrimmedOrNil
    }

    /// Decimal degrees with 6 fractional digits - about 0.11 m, finer than consumer-grade GPS accuracy, so writing more only wastes bytes.
    /// Latitude first, longitude second, the same order as Apple Maps and CoreLocation.
    var coordinateString: String {
        "(\(Self.degree(latitude)), \(Self.degree(longitude)))"
    }

    /// When there is no place name the coordinates stand in, so the card always has a first line to show.
    var displayName: String {
        name ?? coordinateString
    }

    /// The stable coordinate form used for the cache key (`PopopxLocationCardBubble` dedupes its snapshots by it).
    var coordinateKey: String {
        "\(Self.degree(latitude)),\(Self.degree(longitude))"
    }

    /// The machine-read line: `popopx://loc?lat=...&lon=...&name=...&addr=...`.
    ///
    /// The query string is assembled by hand rather than with `URLComponents.queryItems`: when encoding, the latter writes a space as `+` or `%20`
    /// depending on the construction path, and that difference would reach the wire bytes; every value here must explicitly go through the `.alphanumerics`
    /// allowlist (it escapes spaces, `&`, `#` and newlines - the measured output is in the session log), so only then can the parsing side safely
    /// split tokens on whitespace, split fields on `&`, and split key/value on the first `=`.
    var wireString: String {
        var query = "lat=\(Self.degree(latitude))&lon=\(Self.degree(longitude))"
        if let name {
            query += "&name=\(name.popopxLocationEncoded)"
        }
        if let address {
            query += "&addr=\(address.popopxLocationEncoded)"
        }
        return "popopx://loc?\(query)"
    }

    /// The text actually sent out: the readable degrade line + newline + the machine line.
    ///
    /// It is plain text, so it naturally satisfies the mesh preconditions of `PopopxComposerRouting` (`hasAttachments
    /// == false`, no `quotedItem`, TTL off, 1:1 direct chat) - in front of dual-mode routing a location message and an ordinary
    /// text message are **completely isomorphic**, and no special-casing is needed.
    var messageContent: String {
        degradeLine + "\n" + wireString
    }

    /// That degrade line of text on its own.
    ///
    /// It must be exactly one line - `name` / `address` already collapse whitespace into a single space inside `init`, so
    /// newlines from `CLPlacemark` (very common in postal addresses) cannot stretch this message into three lines, and the receiver's
    /// plain-text degrade view and `PopopxLocationCardBubble`'s title line always get one and the same complete sentence.
    var degradeLine: String {
        "📍 " + NSLocalizedString("[Location]", comment: "POPOPX location message") + " \(displayName) \(coordinateString)"
    }

    /// Reads one `popopx://loc` payload out of arbitrary text; if it cannot be read it returns nil and the caller
    /// (`PopopxBubbleMount`) treats nil as "this is not a location message" and hands back to the original plain-text rendering.
    ///
    /// The input is what the receiver pushes into the parser on its own initiative, so every step assumes it is probing the boundaries: first split candidate
    /// tokens on whitespace (a payload never contains whitespace), then judge scheme / host / key names / numbers / range segment by segment.
    ///
    /// The unanchored whole-string match is deliberate: on a real device, once punctuation is added around the payload, the location card silently degrades
    /// into one line of plain text, far harder to trace than a thrown error. Better to recognise too much than to let one slip.
    ///
    /// When several candidates hit, the **last one** is taken, because the producer appends the machine line after the readable line - if the line
    /// people read carries a string that looks like a payload (a place name literally called `popopx://loc?lat=0&lon=0`, or forwarded text),
    /// taking the first would make the card's action coordinates and the coordinates it prints itself go their separate ways. Measured: with the first one
    /// `messageContent` would not even come back to itself.
    static func parse(from text: String) -> PopopxLocationPayload? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            if let payload = parseToken(String(token)) {
                return payload
            }
        }
        return nil
    }

    private static func parseToken(_ token: String) -> PopopxLocationPayload? {
        guard let components = URLComponents(string: token),
              components.scheme == "popopx",
              components.host == "loc"
        else { return nil }

        var fields: [String: String] = [:]
        // It must be `percentEncodedQuery`, not `query`: the latter returns the **already decoded** query string,
        // `name=a%26b` becomes `name=a&b` in its hands first, and splitting on `&` then cuts the place name down to `a` (measured).
        // Splitting on the encoded form and then decoding each value one by one is what lets `&` / `#` / `=` / newlines come back.
        for pair in components.percentEncodedQuery?.split(separator: "&") ?? [] {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<separator])
            // Only these four keys are recognised; everything else (including stray keys of unknown origin) is dropped, so that no string gets into the UI
            // by borrowing our scheme. Key names are compared here on their **raw encoded bytes**, so a bypass form like `na%6De`
            // never lands inside the whitelist either.
            guard fieldNames.contains(key) else { continue }
            let rawValue = String(pair[pair.index(after: separator)...])
            // `URLComponents` repairs illegal escapes beforehand (`name=%zz` is handed out as `%25zz`, reading back the literal
            // `%zz`), so this guard blocks not a truncated `%` but sequences that are **syntactically legal yet not valid UTF-8**
            // (`%C0%80`, `%FF` return nil in measurement): that kind of token kills the whole string, with no fallback to
            // the original string and no half field let in either.
            guard let value = rawValue.removingPercentEncoding else { return nil }
            fields[key] = value
        }

        guard let rawLatitude = fields["lat"],
              let rawLongitude = fields["lon"],
              let latitude = Double(rawLatitude),
              let longitude = Double(rawLongitude),
              // `Double("inf")`, `Double("nan")` and `Double("1e9")` all parse successfully, so "it becomes a
              // number" is still two steps from "it can be a coordinate": first test finiteness, then test the range.
              latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude)
        else { return nil }

        return PopopxLocationPayload(
            latitude: latitude,
            longitude: longitude,
            name: fields["name"],
            address: fields["addr"]
        )
    }

    private static let fieldNames: Set<String> = ["lat", "lon", "name", "addr"]

    /// Fixed-length coordinate component, with one shared way of writing it for `wireString`, `coordinateString` and `coordinateKey`,
    /// so the three stay forever consistent (`%.6f` rounds 89.9999999 up to `90.000000`, which is acceptable:
    /// the payload's semantic precision is 6 digits).
    private static func degree(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}

/// The one failure reason the locating chain spells out: no position could be obtained. The hint copy for a rendering failure is composed by
/// the picker itself (`PopopxLocationPickerSheet.swift`); no sentences are hidden here, and the enum itself is never shown in the UI,
/// so the cases carry semantics only and no `LocalizedError`.
enum PopopxLocationError: Error {
    /// Location services are not on (`CLLocationManager.locationServicesEnabled()`).
    case locationUnavailable
    /// The user refused or has not decided yet: only When In Use is requested, Always is never asked for (`location-prompt.md:35`).
    case permissionDenied
    /// The system returned `kCLErrorDenied` (geofencing permission denied).
    case regionDenied
}

extension String {
    /// The encoding used for payload fields: only alphanumerics are kept and everything else is escaped. Spaces, `&`, `#` and newlines therefore cannot appear
    /// inside field values, which is what makes `parse`'s "split tokens on whitespace, split fields on `&`" safe.
    fileprivate var popopxLocationEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }

    /// A whitespace-only string counts as nil: a place name made only of spaces is worse than none, since the UI shows it as a blank line.
    ///
    /// Runs of internal whitespace are collapsed to a single space along the way, so `name` / `address` cannot keep a newline and
    /// `degradeLine` is always exactly one line (see the passage above).
    fileprivate var popopxTrimmedOrNil: String? {
        let collapsed = self
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
