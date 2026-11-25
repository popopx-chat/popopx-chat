//
//  PopopxH5Launcher.swift
//  POPOPX (iOS)
//
//  The signed H5 leg of module 3. A service-account card or menu button that says "open this web page"
//  hands a URL and a local contact id to this file; the file reads that contact's pairwise identity
//  from the Keychain (`PopopxEcoSessionStore`), signs the request with HMAC-SHA256, and presents the
//  signed page in an out-of-process `SFSafariViewController` sheet.
//
//  Why this file exists as its own type, not as another method on the router:
//
//  1. The signed URL is the one artefact that, if it survives in memory, can be replayed. Keeping it in
//     `PopopxH5Request` (one value, owned by the launcher, dropped on close) means a single place to
//     reason about lifetime. A router method that handed a URL to a sheet would have no such owner.
//  2. The sheet is a UIKit representable — `SFSafariViewController` is the only Apple API that is both
//     out-of-process (the app's own `WKWebView` cookies never leak in) and swipe-down-dismissible
//     natively. Nothing else in `Shared/` uses it yet; this file is the first, and that is expected.
//  3. Signing is pure arithmetic — the same input always produces the same output — so it lives in one
//     `enum` with no state, which a unit test can drive without a UI.
//
//  Three premises in the brief did not match the checkout, and the code follows the checkout:
//
//  - The brief's `PopopxEcoSessionStore.session(contactId:)` is actually spelled `session(for:)`
//    (PopopxEcoRouterAndDeepLink.swift:290); the launcher calls the real name.
//  - `PopopxEcoActionRunner` already calls a different entry point, `PopopxH5Launcher.present(url:session:)`
//    (PopopxEcoRouterAndDeepLink.swift:795), with the session already in hand. The launcher provides both
//    forms: the `open(urlString:contactId:)` one does the store lookup, the `present` one does not.
//  - `PopopxEcoNotice` has no H5-specific case; a refusal is returned synchronously to the caller, who
//    already owns the wording. Raising `.actionFailed` from here would clobber a key-rotation notice the
//    view has not yet drained, so the launcher does not raise.
//

import CryptoKit
import Foundation
import Observation
import os
import SafariServices
import SwiftUI

// MARK: - Outcome

/// Why an H5 open was refused, or what it produced. The enum carries no copy of its own: the one sentence
/// a caller might want to show is a `PopopxEcoCopy` member, and the enum points at it rather than at a literal.
enum PopopxH5OpenOutcome: Hashable, Sendable {
    /// A signed page was built and is now offered. The sheet is up; nothing further to say.
    case signed
    /// The service account has not yet sent its `session_handshake` to this device. Opening without the
    /// pairwise signature would identify the user by IP alone, which is the whole reason this file exists.
    case noSession
    /// The session is present but its secret is missing or unsane. The handshake was corrupted or wiped.
    case sessionUnusable
    /// The URL string could not be parsed, or its scheme is not `http`/`https`. A card that ships a
    /// `javascript:` or a custom scheme is not allowed to reach the browser.
    case invalidURL
    /// A signed page is already on screen. A second tap would produce two sheets over the same URL.
    case alreadyPresenting

    /// `true` only for the outcome the caller can treat as "the page opened".
    var opened: Bool { self == .signed }

    /// What a caller may show about this refusal, from the module's copy table. `nil` for the outcomes
    /// that are not worth saying: a successful open is self-evident, and a double-tap is the launcher's
    /// own defence against a gesture that fired twice.
    var displayCopy: String? {
        switch self {
        case .signed, .alreadyPresenting:
            return nil
        case .noSession:
            return PopopxEcoCopy.deepLinkNeedsContact
        case .sessionUnusable:
            return PopopxEcoCopy.cardFailed
        case .invalidURL:
            return PopopxEcoCopy.deepLinkInvalid
        }
    }
}

// MARK: - Request

/// The one signed page this app currently offers. The launcher owns it; nothing else in the process
/// keeps a copy, so `close()` is the only way to spend the signature and the only way to drop it.
struct PopopxH5Request: Identifiable, Hashable, Sendable {
    let id: UUID
    /// The signed page. Stored as a `URL`, not a `String`: the sheet's representable hands it to
    /// `SFSafariViewController(url:)`, which takes a `URL`, and a `String` here would be a round-trip
    /// through `URL(string:)` that can only fail on a value we already validated.
    let url: URL
    /// The Unix seconds that went into the HMAC preimage. Carried so a caller can log *when* the
    /// signature was built without re-parsing the URL.
    let timestamp: Int

    init(id: UUID = UUID(), url: URL, timestamp: Int) {
        self.id = id
        self.url = url
        self.timestamp = timestamp
    }

    /// The single place the three query parameters are written, so the timestamp the HMAC covered is
    /// the timestamp the server reads. Returns nil when any step of the signing fails.
    static func signed(
        urlString: String,
        session: PopopxEcoSession,
        timestamp: Int = Int(Date().timeIntervalSince1970)
    ) -> PopopxH5Request? {
        guard let url = PopopxH5Signature.signedURL(urlString: urlString, session: session, timestamp: timestamp) else {
            return nil
        }
        return PopopxH5Request(url: url, timestamp: timestamp)
    }
}

// MARK: - Signing

/// The arithmetic the server recomputes. Pure functions, no state, no I/O — a unit test can drive it
/// without a UI and without a Keychain.
private enum PopopxH5Signature {
    /// The three parameter names the launcher owns. A card that ships its own `sig=` or `ts=` is not
    /// allowed to be the one the server reads: the signed values are always the ones appended last, and
    /// any pre-existing pair with one of these names is dropped.
    static let uidParameter = "popopx_uid"
    static let timestampParameter = "ts"
    static let signatureParameter = "sig"

    /// The characters a query value is allowed to use without percent-escaping. RFC 3986 unreserved set:
    /// conservative on purpose, so an `&` or `=` inside a pseudonym cannot inject a fourth parameter.
    private static let queryValueAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    /// The exact byte string the HMAC covers: `uid=<pairwise_uid>&ts=<unix-seconds>`.
    /// Matches the brief's `sig = HMAC-SHA256(key: session_secret, data: "uid=...&ts=...")`.
    static func preimage(pairwiseUid: String, timestamp: Int) -> Data {
        Data("uid=\(pairwiseUid)&ts=\(timestamp)".utf8)
    }

    /// Lowercase hex, because that is what the server expects and what `PopopxEcoHex.encode` produces.
    static func signature(session: PopopxEcoSession, timestamp: Int) -> String? {
        guard let key = session.secretBytes else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(
            for: preimage(pairwiseUid: session.pairwiseUid, timestamp: timestamp),
            using: SymmetricKey(data: key)
        )
        return PopopxEcoHex.encode(Data(mac))
    }

    /// Percent-escape a single value. `addingPercentEncoding` returns nil only for a string that
    /// contains an unpaired surrogate; a Swift `String` built from UTF-8 cannot have one, so the
    /// fallback is defensive rather than expected.
    static func escape(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed)
    }

    /// Build the signed URL, dropping any pre-existing `popopx_uid` / `ts` / `sig` pair from the
    /// incoming query so a spoofed card cannot ship a signature the server would accept in our place.
    static func signedURL(urlString: String, session: PopopxEcoSession, timestamp: Int) -> URL? {
        guard PopopxEcoAction.isHttpURL(urlString) else { return nil }
        guard var components = URLComponents(string: urlString) else { return nil }
        guard let escapedUid = escape(session.pairwiseUid), !escapedUid.isEmpty else { return nil }
        guard let sig = signature(session: session, timestamp: timestamp) else { return nil }

        let owned: Set<String> = [uidParameter, timestampParameter, signatureParameter]
        var keptPairs: [String] = []
        if let existing = components.percentEncodedQuery {
            for pair in existing.split(separator: "&") where !pair.isEmpty {
                let name = String(pair.prefix(while: { $0 != "=" }))
                if owned.contains(name) { continue }
                keptPairs.append(String(pair))
            }
        }
        keptPairs.append("\(uidParameter)=\(escapedUid)")
        keptPairs.append("\(timestampParameter)=\(timestamp)")
        keptPairs.append("\(signatureParameter)=\(sig)")
        components.percentEncodedQuery = keptPairs.joined(separator: "&")
        return components.url
    }
}

// MARK: - Launcher

/// The single owner of the signed page. `@MainActor` because it mutates `request` from view code, and
/// `@Observable` so the sheet mount re-renders on change without a `@Published` round-trip.
@MainActor
@Observable
final class PopopxH5Launcher {
    static let shared = PopopxH5Launcher()

    /// The one signed page currently offered. `nil` means no sheet.
    private(set) var request: PopopxH5Request?

    private let log = Logger(subsystem: "com.popopxchat.popopx", category: "h5")

    private init() {}

    /// The entry point the menu bar and the deep-link handler call. Reads the session from the store,
    /// signs the URL, and installs the request. Returns the outcome so the caller can show the copy.
    func open(urlString: String, contactId: Int64) -> PopopxH5OpenOutcome {
        guard request == nil else { return .alreadyPresenting }
        guard let session = PopopxEcoSessionStore.session(for: contactId) else {
            log.info("eco h5 refused: no session for contact")
            return .noSession
        }
        return offer(urlString: urlString, session: session)
    }

    /// Drop the current request. Idempotent: calling it when nothing is offered is a no-op.
    func close() {
        request = nil
    }

    /// The entry point `PopopxEcoActionRunner` already calls (PopopxEcoRouterAndDeepLink.swift:795): the
    /// runner has read the session itself, so this form skips the store lookup.
    @discardableResult
    static func present(url: String, session: PopopxEcoSession) -> Bool {
        shared.offer(urlString: url, session: session).opened
    }

    private func offer(urlString: String, session: PopopxEcoSession) -> PopopxH5OpenOutcome {
        guard request == nil else { return .alreadyPresenting }
        guard session.isSane else {
            log.info("eco h5 refused: session unsane")
            return .sessionUnusable
        }
        guard let built = PopopxH5Request.signed(urlString: urlString, session: session) else {
            log.info("eco h5 refused: could not build signed URL")
            return .invalidURL
        }
        request = built
        return .signed
    }
}

// MARK: - Sheet

/// The representable that hosts `SFSafariViewController`. Nothing else in `Shared/` uses `SFSafariViewController`
/// yet; this file is the first, and that is expected.
private struct PopopxSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }

    /// Nothing to push: the signed URL is fixed for the life of the sheet (see `PopopxH5Sheet`'s snapshot),
    /// and reloading a page the user may have navigated away from would be the real bug here.
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// The sheet body. The URL is copied out of the request on the first render so a dismissal that clears
/// `PopopxH5Launcher.request` mid-transition cannot swap the page out from under the closing animation.
private struct PopopxH5Sheet: View {
    @State private var url: URL

    init(request: PopopxH5Request) {
        _url = State(initialValue: request.url)
    }

    var body: some View {
        PopopxSafariView(url: url)
            .ignoresSafeArea()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }
}

/// The mount: attached once to a container view, it presents `PopopxH5Launcher.shared.request` as a sheet.
/// A local `@State` mirror exists only because `sheet(item:)` needs a Binding and `request` is `private(set)`
/// on purpose — nothing but the launcher may install a signature.
private struct PopopxH5LauncherMount: ViewModifier {
    @State private var presented: PopopxH5Request?
    @State private var launcher = PopopxH5Launcher.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: launcher.request, initial: true) { _, next in
                presented = next
            }
            .sheet(item: $presented, onDismiss: { launcher.close() }) { request in
                PopopxH5Sheet(request: request)
            }
    }
}

extension View {
    /// Attach once to a container view; it presents `PopopxH5Launcher.shared.request` as a sheet.
    func popopxH5Launcher() -> some View {
        modifier(PopopxH5LauncherMount())
    }
}
