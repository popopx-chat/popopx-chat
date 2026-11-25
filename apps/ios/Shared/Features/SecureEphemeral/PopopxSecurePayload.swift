//
//  PopopxSecurePayload.swift
//  POPOPX (iOS)
//
//  Payload layer for [top-secret view-once] plus the full alert vocabulary. This file is the only contract of the feature:
//  the detection engine only **produces** `PopopxSecurityAlert`, the window only **consumes** it, the bubble only **reads** `PopopxSecurePayload`
//  for its three display fields. Nobody may bypass this layer and assemble strings by hand.
//
//  The wire form is two lines of text, and what is sent out is the second line (exactly the same shape as `PopopxLocationPayload`):
//
//  ```text
//  🔒 [Top secret, view once] view after biometric authentication
//  popopx://sec?ttl=60&data=<base64url ciphertext>&k=<base64url session key>
//  ```
//
//  ### About the `k=` field (one honest deviation from the prompt; read this before changing it)
//  The format written in the prompt has only `ttl` and `data`. A message with only those two fields **can never be opened by the recipient**: for the ciphertext to be openable
//  the key must land on the device that reads it, and POPOPX has no session key obtainable from the Swift side: SMP's double ratchet
//  lives on the Haskell side (above `chatSendCmd` there is only plaintext `MsgContent`), and on the Bluetooth Mesh path the Noise
//  key sits inside the `PopopxMeshKit` actor; neither exposes an app-layer interface that derives a message key on request.
//  So the key can only travel with the message, carried by `k=`. That is not laziness in the design, it is the only workable solution at this layer,
//  and precisely for that reason the threat model below must be written into the file in black and white rather than vaguely called encryption.
//
//  ### What this actually defends against, and what it does not (only sentences that can prove themselves)
//  Defends (from the fact that `data=` is AES-256-GCM ciphertext):
//  - plaintext into SQLite: of the two lines stored as `msgContent.text` in the local database there is no message body;
//  - plaintext into notifications, conversation list previews, reply quote bars and forwarded quotes: all of those read `text` directly and see only the degraded line;
//  - plaintext into the Mesh relay queue: `PopopxMeshRuntime`'s offline fallback record is written to disk verbatim (POPOPXAPI.swift:3634),
//    so the relay node stores ciphertext; that is also the precondition that lets a top-secret message take dual-mode routing.
//  - the GCM tag also covers a payload that was rewritten in transit: if `open()` cannot decode it, it was altered, and the UI treats it as destroyed without drawing half a character.
//  Does not defend against:
//  - **the recipient themselves**. They hold `data` and `k` at the same time, so anyone who can read their own device's files can open it offline.
//    This layer was never secret from the recipient; the constraints on the recipient are exactly two: pass biometrics before viewing, physically delete after viewing.
//  - nor does it defend against forensics on the sender's device, because what the sender keeps is the very plaintext they just sent out.
//  Writing this plainly is more useful than leaving a line about bank-grade encryption: the real control point is module five's destruction, not this layer's encoding.
//
//  ### Mutual exclusion with `popopx://loc` (hard constraint, same as `PopopxLocation.swift:17`-`:21`)
//  `popopx:/` and `popopx://` are the prefixes of invite links, and `hasPopopxLink` recognises this scheme, so the only accepted host is
//  `sec`, and the string is judged alive only after `ttl`/`data`/`k` have all been measured; any single failure judges the whole string dead and falls back to plain text rendering.
//  A top-secret message recognised as an invite link equals an added friend, and the shape of that incident is identical to the location one.
//
//  ### Lifecycle
//  The plaintext handed out by `open()` is a `Data`, not an internal copy of a `String`: once the caller is done it must
//  overwrite it with `popopxSecureErase(_:)` (end of this file), and `PopopxSecureWindowManager` calls it on all three paths: closing, reaching zero,
//  and circuit-breaking. Swift's `String` has no overwritable buffer, so **plaintext always exists internally as `Data`**,
//  and becomes a `String` only at the instant it is handed to SwiftUI for display; that copy belongs to ARC, this layer cannot promise to overwrite it and does not claim to.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.
//

import CryptoKit
import Foundation

// MARK: - Payload

/// The payload of one top-secret message. Immutable: it must be `Hashable` to enter `PopopxBubbleBody`, and once the ciphertext is minted it should never move again.
struct PopopxSecurePayload: Hashable, Sendable {
    /// View-once duration, in seconds. The recipient starts counting from the **first open**, not from receipt (see `PopopxSecureWindowManager`).
    let ttlSeconds: Int
    /// AES-256-GCM sealed box: `nonce(12) || ciphertext || tag(16)`, with no custom header of any kind.
    let sealed: Data
    /// The 256-bit session key that travels with the payload. Reason given in the file header.
    let key: Data

    /// Duration bounds. Lower bound 5 seconds: shorter than that the message burns before the user has finished biometrics plus the authentication sheet,
    /// which is equivalent to never being readable. Upper bound 3600 seconds: an hour of top-secret plaintext resting on screen is not a product, it is an incident.
    static let minimumTTLSeconds = 5
    static let maximumTTLSeconds = 3600

    /// Ciphertext length range. Lower bound = 12(nonce) + 0(empty body) + 16(tag) = 28 bytes;
    /// the upper bound of 32 KiB is a generous estimate for a top-secret message that fits on a screen, while also blocking someone from feeding CryptoKit a 10 MB
    /// `data=`: decryption happens on the recipient's device, so the cost must be the recipient's call.
    static let minimumSealedBytes = 28
    static let maximumSealedBytes = 32 * 1024

    /// The only construction entry point. In production code only `make` (sending side) and `parse` (receiving side) call it,
    /// and both have already finished judging ttl / length / alphabet; tests use the same init to build a payload that was tampered with in transit.
    init(ttlSeconds: Int, sealed: Data, key: Data) {
        self.ttlSeconds = ttlSeconds
        self.sealed = sealed
        self.key = key
    }

    // MARK: Minting / unsealing

    /// Upper bound on plaintext length, in UTF-8 bytes. Two ends of the same thing as `maximumSealedBytes` (the sealed box is only 28 bytes longer than the plaintext),
    /// listed separately so the sending side can give a human-readable error **before minting** instead of minting a payload the peer must judge dead.
    static let maximumPlainBytes = 32 * 1024

    /// Mint a payload: random 256-bit key + one-time random nonce, sealed with AES-256-GCM.
    ///
    /// The nonce is drawn fresh from `CryptoKit` at every `seal` and never reused: a repeated nonce under the same key
    /// would break GCM's authentication outright, and here the key itself is newly generated for each message, so no reuse window exists,
    /// which means all that is required is never to manufacture a nonce ourselves.
    static func make(plaintext: String, ttlSeconds: Int) throws -> PopopxSecurePayload {
        let utf8 = Data(plaintext.utf8)
        guard !utf8.isEmpty else { throw PopopxSecureError.emptyPlaintext }
        guard utf8.count <= maximumPlainBytes else {
            throw PopopxSecureError.plaintextTooLong(bytes: utf8.count)
        }
        let clamped = min(max(ttlSeconds, minimumTTLSeconds), maximumTTLSeconds)
        let sessionKey = SymmetricKey(size: .bits256)
        let box = try AES.GCM.seal(utf8, using: sessionKey)
        // `box.combined` is a `Data?`: it is nil only when the underlying combination fails. No `try!` here,
        // because the correct behaviour for a failed top-secret mint is "not sent + one human sentence", not a crash.
        guard let combined = box.combined else { throw PopopxSecureError.sealingFailed }
        return PopopxSecurePayload(
            ttlSeconds: clamped,
            sealed: combined,
            key: sessionKey.withUnsafeBytes { Data($0) }
        )
    }

    /// Unseal into plaintext bytes. **The caller is responsible for erasing**: hand it to `popopxSecureErase(_:)` when done.
    func open() throws -> Data {
        guard key.count == 32 else { throw PopopxSecureError.wrongKeyLength(key.count) }
        guard sealed.count >= Self.minimumSealedBytes, sealed.count <= Self.maximumSealedBytes else {
            throw PopopxSecureError.wrongSealedLength(sealed.count)
        }
        let symmetricKey = SymmetricKey(data: key)
        let box = try AES.GCM.SealedBox(combined: sealed)
        do {
            return try AES.GCM.open(box, using: symmetricKey)
        } catch {
            throw PopopxSecureError.decryptionFailed
        }
    }

    // MARK: Wire bytes

    /// The line the machine reads. All three values are base64url and decimal digits, containing no `&`/`=`/`+`/`/`/whitespace,
    /// so nothing like the `.alphanumerics` escaping of `PopopxLocation.swift` is needed here, and it is exactly for that reason
    /// that the parsing side can split tokens on whitespace, split fields on `&` and split key from value at the first `=` without losing data.
    var wireString: String {
        "popopx://sec?ttl=\(ttlSeconds)&data=\(sealed.popopxBase64URL)&k=\(key.popopxBase64URL)"
    }

    /// The line meant for humans. It never contains a single body character, and this is where the hard constraint against exposing plaintext in lists lands:
    /// the conversation list, the notification banner and the quote preview all read `text`, which is this `degradeLine` + newline + machine line.
    var degradeLine: String {
        "🔒 " + NSLocalizedString("[Top-secret view-once] Open after biometrics", comment: "POPOPX secure payload") + " · \(PopopxSecureCopy.duration(ttlSeconds))"
    }

    /// The text actually sent out. It is plain text, so like the location message it naturally satisfies
    /// the mesh preconditions of `PopopxComposerRouting` (no attachment, no quote, 1:1 direct chat); it needs no criterion field of its own.
    var messageContent: String {
        degradeLine + "\n" + wireString
    }

    /// For display: puts the payload into one human sentence (card subtitle, VoiceOver). Contains no body text, and never will.
    var summaryText: String {
        PopopxSecureCopy.duration(ttlSeconds)
    }

    // MARK: Parsing

    /// Reads one top-secret payload out of arbitrary text; if there is none it returns nil, and the caller (`PopopxBubbleMount`)
    /// treats nil as this is not a top-secret message and hands back to the original plain-text rendering.
    ///
    /// The input is something the receiving side deliberately pushed into the parser, so every step treats it as probing the boundaries: first split tokens on whitespace,
    /// then judge field by field: scheme / host / key-name whitelist / digits / length / base64url alphabet.
    ///
    /// When several candidates match, the **last one** wins, which lines up with the producer appending the machine line after the human-readable line
    /// (`PopopxLocation.swift:123`-`:126` gives the same reason, measured there: taking the first would leave the payload unable to find itself again).
    static func parse(from text: String) -> PopopxSecurePayload? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            if let payload = parseToken(String(token)) {
                return payload
            }
        }
        return nil
    }

    private static func parseToken(_ token: String) -> PopopxSecurePayload? {
        guard let components = URLComponents(string: token),
              components.scheme == "popopx",
              components.host == "sec"
        else { return nil }

        var fields: [String: String] = [:]
        // `percentEncodedQuery` is mandatory: `query` hands back an **already decoded** string, so in its hands `data=a%26b`
        // first becomes `data=a&b`, and splitting on `&` then truncates the ciphertext into one field. Same as `PopopxLocation.swift:143`-`:145`.
        for pair in components.percentEncodedQuery?.split(separator: "&") ?? [] {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<separator])
            // The whitelist comparison uses the **raw encoded bytes**: a key written as `d%61ta` does not get in (`PopopxLocation.swift:150`, same criterion).
            guard fieldNames.contains(key) else { continue }
            guard let value = String(pair[pair.index(after: separator)...]).removingPercentEncoding
            else { return nil }
            fields[key] = value
        }

        guard let rawTTL = fields["ttl"],
              let ttl = Int(rawTTL),
              // `Int("+60")` also decodes successfully, so the length ceiling must be held by "the whole string is digits only", not by the value range.
              rawTTL.allSatisfy(\.isNumber),
              rawTTL.count <= 4,
              (minimumTTLSeconds...maximumTTLSeconds).contains(ttl),
              let encodedSealed = fields["data"],
              let encodedKey = fields["k"],
              let sealed = Data(popopxBase64URL: encodedSealed),
              let key = Data(popopxBase64URL: encodedKey),
              sealed.count >= minimumSealedBytes,
              sealed.count <= maximumSealedBytes,
              key.count == 32
        else { return nil }

        return PopopxSecurePayload(ttlSeconds: ttl, sealed: sealed, key: key)
    }

    private static let fieldNames: Set<String> = ["ttl", "data", "k"]
}

// MARK: - Errors

/// Every reason the payload layer is willing to say out loud. The UI never shows the enum itself, only the sentences below, so there is no `LocalizedError`.
enum PopopxSecureError: Error, Hashable {
    case emptyPlaintext
    case plaintextTooLong(bytes: Int)
    case sealingFailed
    case wrongKeyLength(Int)
    case wrongSealedLength(Int)
    /// GCM authentication failed: either this is not the message's key, or the payload was tampered with in transit. Both are handled as destruction.
    case decryptionFailed
    /// The key matches, the tag verifies, the bytes were handed over, but they cannot be assembled into readable UTF-8 (or they are empty).
    ///
    /// Must stay separate from `decryptionFailed`: that sentence implies something was touched in transit, whereas here **nothing at all
    /// was touched**, GCM has just proven it intact. The only real cause is the sender minting an empty body (this side's `make`
    /// explicitly rejects an empty string, so that would be another implementation or a later code path). It is still handled as destruction (cannot open is cannot open),
    /// but the cause is named correctly: sending the user to suspect the transport link would be a thoroughgoing misdirection.
    case unusablePlaintext
    /// Biometric authentication did not pass, or the user cancelled it. That is a different matter from "cannot be decoded" and cannot be merged into one case: on screen one means try again,
    /// the other means this one is already destroyed.
    case authenticationFailed
    /// The current device has no usable biometrics (no Face ID / Touch ID enrolled). A top-secret message does **not** degrade to looking at it directly,
    /// nor does it borrow the app-wide `privacyLocalAuthMode = .passcode` mode: the passphrase on that path is the app passphrase,
    /// which is not the same thing as the view-after-biometric the prompt asks for.
    case biometricsUnavailable
    /// The pre-flight check before opening finds the screen being captured (screen recording / AirPlay / capture card).
    case screenIsCaptured
}

// MARK: - Alerts

/// Every security event the detection engine can report. One case = one reason the user can see, and the same sentence that goes on the receipt.
enum PopopxSecurityAlert: Hashable, Sendable {
    // capture class (module four)
    /// The user pressed the screenshot key combination. `UIApplication.userDidTakeScreenshotNotification` is the only public entry point that yields this signal.
    case screenshotTaken
    /// `UIScreen.isCaptured` turned true: one of screen recording, AirPlay, or a wired capture card.
    case screenCaptured
    /// The app went to the background / was switched away while the top-secret window was still counting down: from that moment the snapshot cache and the app switcher thumbnails are no longer controlled.
    case leftForeground

    // visual class (modules two and three)
    /// A second face appears in the front camera, or someone leans in beside the primary user.
    case secondaryFaceDetected
    /// The primary user has been out of the viewing angle for more than 0.5 seconds: at this moment the screen is open to anyone.
    case primaryViewerLost
    /// The lens flare hotspot met its threshold (two consecutive frames with a high-circularity overexposed blob, or a jump in the whole-frame mean).
    case lensGlareDetected
    /// A high-risk object recognised by CoreML object detection.
    case recordingDevice(PopopxGuardObject)

    /// The sentence in the receipt: an ordinary text message sent from the **viewer's** device to the **sender**.
    ///
    /// Deliberately only one line of ordinary text, with no new `popopx://secalert` scheme: the receiving side would have to open another bubble case for it
    /// and another parsing surface, while all this message does is let the other side see what just happened. One fewer protocol is one fewer place that can rot.
    var receiptText: String {
        "⚠️ " + String(format: NSLocalizedString("[Top-secret security alert] %@; that top-secret message was destroyed in place.", comment: "POPOPX secure payload"), reasonText)
    }

    /// The short phrase on the UI/toast. One sentence naming which class of risk, without claiming who was caught and without predicting consequences.
    var reasonText: String {
        switch self {
        case .screenshotTaken: return NSLocalizedString("Screenshot detected", comment: "POPOPX top-secret alert")
        case .screenCaptured: return NSLocalizedString("The screen is being recorded or mirrored", comment: "POPOPX top-secret alert")
        case .leftForeground: return NSLocalizedString("The app left the foreground before the top-secret message was read", comment: "POPOPX top-secret alert")
        case .secondaryFaceDetected: return NSLocalizedString("A second person appeared on screen", comment: "POPOPX top-secret alert")
        case .primaryViewerLost: return NSLocalizedString("The device owner left the view", comment: "POPOPX top-secret alert")
        case .lensGlareDetected: return NSLocalizedString("Lens glare detected", comment: "POPOPX top-secret alert")
        case let .recordingDevice(object): return String(format: NSLocalizedString("Detected a %@", comment: "POPOPX top-secret alert"), object.displayName)
        }
    }

    /// Whether the message gets destroyed. Of the three tiers, `leftForeground` is the only negotiable one:
    /// it destroys by default (with `PopopxSecureSettings.destructiveOnBackground` on), and once switched off it only locks the screen instead of destroying.
    var destroysMessage: Bool {
        switch self {
        case .leftForeground: return false
        default: return true
        }
    }
}

/// Object classification on the CoreML path. The mapping from category names to this enum is written in `PopopxCameraGuardEngine`;
/// this layer only carries meaning and does not match strings: the engine may degrade to a state with no model, but this enum may not change.
enum PopopxGuardObject: String, Hashable, Sendable, CaseIterable {
    /// High-risk capture class: confidence ≥ 0.40 trips the circuit breaker immediately.
    case cellPhone
    case camera
    case mobilePhone
    case lens
    /// Possible close-range screen recording class: only confidence ≥ 0.55 trips the breaker.
    case laptop
    case television
    case remote

    /// High-risk tier: threshold 0.40. The rest (`laptop`/`television`/`remote`) are the 0.55 close-range screen-recording tier.
    var isHighRisk: Bool {
        switch self {
        case .cellPhone, .camera, .mobilePhone, .lens: return true
        case .laptop, .television, .remote: return false
        }
    }

    var threshold: Double { isHighRisk ? 0.40 : 0.55 }

    var displayName: String {
        switch self {
        case .cellPhone, .mobilePhone: return NSLocalizedString("phone", comment: "POPOPX top-secret alert: object")
        case .camera: return NSLocalizedString("camera", comment: "POPOPX top-secret alert: object")
        case .lens: return NSLocalizedString("lens", comment: "POPOPX top-secret alert: object")
        case .laptop: return NSLocalizedString("laptop", comment: "POPOPX top-secret alert: object")
        case .television: return NSLocalizedString("screen", comment: "POPOPX top-secret alert: object")
        case .remote: return NSLocalizedString("remote control", comment: "POPOPX top-secret alert: object")
        }
    }

    /// Model label to this enum. The key names align character for character with the `classes` exported by ultralytics COCO (in `coco_names`
    /// they are `cell phone` / `tvmonitor` / `laptop` / `remote`), with spaces and case both counting.
    ///
    /// `mobile phone` / `camera` / `lens` are not COCO class names; they are aliases brought in by the `--custom-weights` route
    /// (third-party phone-detection weights), kept so that swapping weights does not require changing Swift.
    ///
    /// Both spellings `tv` and `tvmonitor` are required: COCO's official class name is `tvmonitor`, while ultralytics'
    /// `names` dictionary has given `tv` in different versions. Recognising only one spelling would leave the whole close-range screen-recording tier
    /// failing silently (the judgement reports no error, it simply never triggers); `scripts/setup_pretrained_coreml.py`
    /// has a `COCO_SYNONYMS` WARN exactly for this, and this table is the side it demands be kept in sync.
    static func resolve(modelLabel: String) -> PopopxGuardObject? {
        switch modelLabel.trimmingCharacters(in: .whitespaces).lowercased() {
        case "cell phone": return .cellPhone
        case "mobile phone": return .mobilePhone
        case "camera": return .camera
        case "lens": return .lens
        case "laptop": return .laptop
        case "tv", "tvmonitor", "television", "monitor": return .television
        case "remote", "remote control": return .remote
        default: return nil
        }
    }
}

// MARK: - Wording

/// Short phrases shared by payload and window. Kept in one place so the card, the toast and the receipt do not each say their own version.
enum PopopxSecureCopy {
    static func duration(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { return String(format: NSLocalizedString("%lld days", comment: "secure duration"), seconds / 86_400) }
        if seconds % 3_600 == 0 { return String(format: NSLocalizedString("%lld hours", comment: "secure duration"), seconds / 3_600) }
        if seconds % 60 == 0 { return String(format: NSLocalizedString("%lld minutes", comment: "secure duration"), seconds / 60) }
        return String(format: NSLocalizedString("%lld seconds", comment: "secure duration"), seconds)
    }

    /// The selectable durations of the top-secret tier. Not reusing `PopopxComposerRouting.durationOptions` (30 seconds / 1 minute / 5 minutes):
    /// that tier is view-once, whose meaning is how long until a message disappears from the **server**; this tier is how long plaintext may rest **on screen**,
    /// and borrowing the same set of values would merge the two durations into one in the user's mind.
    static let ttlOptions: [PopopxSecureTTLOption] = [
        .init(seconds: 15, title: "15 seconds"),
        .init(seconds: 30, title: "30 seconds"),
        .init(seconds: 60, title: "1 minute"),
        .init(seconds: 300, title: "5 minutes")
    ]

    /// The default on-screen duration when the top-secret tier is first opened: 60 seconds.
    ///
    /// It is not the shortest tier: the recipient must first complete a biometric round, and 15 seconds often reaches zero before the first line is read;
    /// nor is it the longest tier: a screen of text does not take 5 minutes to read, and picking a larger tier should be an explicit user decision.
    /// The value must be anchored at this layer (the payload is the contracting party for this short duration), and both the input bar and the host read it from here,
    /// so that two places do not each write their own 60 and then drift apart.
    static let defaultTTLSeconds = 60

    static let cardTitle = NSLocalizedString("Top-secret burn after reading", comment: "POPOPX top-secret card")
    static let cardLockedHint = NSLocalizedString("Tap to view with biometric authentication", comment: "POPOPX top-secret card")
    static let cardDestroyed = NSLocalizedString("Destroyed", comment: "POPOPX top-secret card")
    static let cardDamaged = NSLocalizedString("The payload is damaged and cannot be opened", comment: "POPOPX top-secret card")
    static let biometricReason = NSLocalizedString("View the top-secret message", comment: "POPOPX top-secret card")
}

/// Top-secret duration tiers. A standalone type rather than reusing the composer's tiers; the reason is in the comment above.
struct PopopxSecureTTLOption: Hashable, Identifiable, Sendable {
    let seconds: Int
    let title: String
    var id: Int { seconds }
}

// MARK: - base64url

extension Data {
    /// Unpadded base64url. Chosen over standard base64 so that `+` `/` `=` **never appear** inside `data=`/`k=`:
    /// once those three characters enter a query string they must be escaped, and field values not needing escaping is exactly the precondition that lets the parser
    /// safely split on `&` and on the first `=` (`PopopxLocation.swift:81`-`:84` is the same thing,
    /// achieved there with a `.alphanumerics` whitelist and here with the alphabet).
    var popopxBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict decoding: any character outside the alphabet, or a length that is invalid once padding is restored, always yields nil.
    ///
    /// `Base64DecodingOptions.ignoreUnknownCharacters` is not used: that is the switch which makes even a 30%-length
    /// human sentence decode into a run of bytes, precisely the leniency a receiving side should least have.
    init?(popopxBase64URL string: String) {
        guard !string.isEmpty else { return nil }
        var alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        // Padded input is accepted as well, only so that a peer built by another implementation is not left unreadable; padding takes no part in the alphabet check above.
        alphabet.insert(charactersIn: "=")
        guard string.unicodeScalars.allSatisfy({ alphabet.contains($0) }) else { return nil }
        var canonical = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = canonical.count % 4
        if remainder == 2 { canonical += "==" }
        else if remainder == 3 { canonical += "=" }
        else if remainder != 0 { return nil }
        guard let decoded = Data(base64Encoded: canonical) else { return nil }
        self = decoded
    }
}

// MARK: - Memory overwrite

/// Forcibly overwrites a buffer.
///
/// Why `memset_s` and not `memset`: the latter is something the compiler can prove is never read after writing and delete entirely (DCE),
/// while the semantics of `memset_s` are that it must not be optimised away (C11 K.3.7.4.2 / Apple's `<string.h>`).
/// The Swift-side `Darwin` module already carries its import, so no C bridging header is needed; this was measured (same machine, same SDK,
/// `-typecheck` on a file containing only a `memset_s` call returned 0), not guessed.
///
/// Why it takes `inout`: `withUnsafeMutableBytes` takes exclusive ownership first when the buffer is shared (COW), so **what is erased is always
/// the copy in the caller's hands**. That is neither a defect nor a guarantee, it is the semantics of `Data`, so the rules of the destruction path are hardcoded in
/// `PopopxSecureWindowManager`: the `Data` handed out by `open()` must not be held a second time between creation and erasure,
/// and only a `String` travels out of it (for display), which belongs to ARC; this layer cannot promise to overwrite it, as the file header already states.
func popopxSecureErase(_ data: inout Data) {
    guard !data.isEmpty else { return }
    data.withUnsafeMutableBytes { raw in
        _ = memset_s(raw.baseAddress, raw.count, 0, raw.count)
    }
}

/// Overwrites and releases an optional buffer. Called on the destruction path, to avoid the ambiguous state of an all-zero reference still sitting where the data was.
///
/// Deliberately not written as `if var owned = data` here: a local `var` shares the buffer with the original value, so `withUnsafeMutableBytes`
/// takes it exclusively and what gets erased is the **copy**, with the original untouched by a single byte. The mutable bytes must be taken directly on the `data` l-value.
func popopxSecureErase(_ data: inout Data?) {
    guard data != nil else { return }
    data?.withUnsafeMutableBytes { raw in
        _ = memset_s(raw.baseAddress, raw.count, 0, raw.count)
    }
    data = nil
}
