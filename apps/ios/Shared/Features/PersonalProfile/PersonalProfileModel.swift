//
//  PersonalProfileModel.swift
//  POPOPX (iOS)
//
//  [Encrypted personal profile - module one, part one] The data shape of a profile, and the codec for its two lines of bytes on the wire.
//
//  This file is the single contract shared by four people: the maker only writes `PopopxProfileManifest`, the sender only reads
//  `PopopxProfilePayload.messageContent`, and the card and the reader only eat the payload `parse` hands back.
//  Nobody may assemble the `popopx://profile` string somewhere else - every extra assembly is one more place that can disagree with the others.
//
//  The wire form is two lines of text, and what is actually sent is the second one (exactly the same shape as `popopx://sec` and `popopx://loc`):
//
//  ```text
//  👤 [Encrypted personal profile] Zhang San - backend / photography (view-once)
//  popopx://profile?mode=ephemeral&ttl=300&delivery=full&credits=20&data=<base64url(JSON)>
//  ```
//
//  ### Not encrypting `data=` a second time is deliberate
//  SMP messages and the Mesh Noise channel are already end-to-end encrypted, so this slot's job is self-description, not secrecy; the profile's media
//  originals never leave the device except as ordinary encrypted XFTP attachments, and `data=` holds only the assembly skeleton plus the text blocks.
//
//  ### Mutually exclusive with invite links (same as `PopopxLocation.swift:18`-`:22`, `PopopxSecurePayload.swift:37`-`:41`)
//  `popopx:/` and `popopx://` are the invite-link prefixes, and `hasPopopxLink` recognises precisely this scheme. So the host
//  accepts only `profile`, and all four slots `mode`/`ttl`/`delivery`/`data` are pinned dead before the string is judged alive; any one unmet kills the whole string and
//  falls back to plain-text rendering. The fifth slot `credits=` (the paid gate) is the only one that may be absent: old profiles do not have it, and absent means free to read.
//  One profile message read as an invite link = one accidental contact add, and the shape of that incident is exactly the location version's.
//
//  ### The two directions are deliberately strict to different degrees
//  `parse`'s input is text the other side sent over, so it **never throws**: an out-of-range block count, an over-long title, a `data=` outside the alphabet,
//  an illegal UTF-8 escape, an envelope that disagrees with the body - all return nil, and callers treat nil as "this is not a profile message".
//  `make`'s input is a manifest this end assembled itself, and a failure must say which rule broke, so it throws `PopopxProfileError`.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.
//

import Foundation

// MARK: - Send mode

/// Under which privacy semantics this profile is delivered. `ephemeral` = the countdown to destruction starts on the recipient's **first open**; `standard` = permanent.
enum PopopxProfileSendMode: String, Codable, Hashable, Sendable, CaseIterable {
    case ephemeral
    case standard

    /// How that slot is written on the wire. It happens to equal `rawValue`, but the two are different things: `rawValue` is owned by the Codable local archive
    /// format (changing it makes profiles the user already saved unreadable), `wireValue` is owned by the protocol (changing it changes the protocol).
    /// So each case is written dead here instead of writing `rawValue`.
    var wireValue: String {
        switch self {
        case .ephemeral: return "ephemeral"
        case .standard: return "standard"
        }
    }

    /// Wire bytes -> mode. Only the exact spelling of `wireValue` is accepted: no `rawValue`, no case variants, no aliases -
    /// one more bit of leniency on the peer's side is one less bit of room for us to change the protocol.
    static func fromWire(_ raw: String) -> PopopxProfileSendMode? {
        allCases.first { $0.wireValue == raw }
    }

    /// The phrase on the card badge.
    var cardLabel: String {
        switch self {
        case .ephemeral: return NSLocalizedString("Burn after reading", comment: "")
        case .standard: return NSLocalizedString("Persistent card", comment: "")
        }
    }

    /// The segmented control gets a single line, and long labels get truncated with an ellipsis on small iPhones, so the short label reuses the card badge wording itself.
    var sheetLabel: String {
        switch self {
        case .ephemeral, .standard:
            return cardLabel
        }
    }
}

// MARK: - Delivery mode

/// Public-network SMP (with images, text and video) or Bluetooth Mesh (text only). **Orthogonal** to the send mode:
/// a permanent card gets downgraded by Mesh too, and view-once can go over the public network.
enum PopopxProfileDelivery: String, Codable, Hashable, Sendable, CaseIterable {
    case fullMedia
    case meshTextOnly

    var wireValue: String {
        switch self {
        case .fullMedia: return "full"
        case .meshTextOnly: return "mesh"
        }
    }

    static func fromWire(_ raw: String) -> PopopxProfileDelivery? {
        allCases.first { $0.wireValue == raw }
    }

    /// Card badge. The `mesh` tier is paired with Cabin's teal-green in the interface and `full` with the brand purple - colour belongs to `PopopxTheme`,
    /// this layer only supplies the words.
    var badgeLabel: String {
        switch self {
        case .fullMedia: return NSLocalizedString("Online, full media", comment: "")
        case .meshTextOnly: return NSLocalizedString("Cabin · offline text only", comment: "")
        }
    }
}

// MARK: - Media block

/// The **description** of one media block inside the manifest, without bytes: the originals live in `ProfileStorageManager`'s sandbox directory,
/// and over the network only this little piece of metadata plus ordinary XFTP attachments travel.
struct PopopxProfileMedia: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case image
        case video
    }

    /// `UUID().uuidString.lowercased()`. It is used directly as a file name in the sandbox, so whatever value the recipient supplies
    /// has to pass the character whitelist first (see `ProfileStorageManager`).
    let mediaId: String
    let kind: Kind
    /// Byte count after landing on disk (the actual size after compression/transcoding, not the album original's size).
    let bytes: Int
    /// Video only; images are nil. The duration after truncation to the 30 second cap.
    let durationSeconds: Int?
    /// Caption for the image/video. Kept all `let` (once a media description has been over the network it should not be edited in place),
    /// so a caller that needs a caption just rebuilds a value with the memberwise initialiser and reuses the old `mediaId`.
    let caption: String?

    init(
        mediaId: String,
        kind: Kind,
        bytes: Int,
        durationSeconds: Int? = nil,
        caption: String? = nil
    ) {
        self.mediaId = mediaId
        self.kind = kind
        self.bytes = bytes
        self.durationSeconds = durationSeconds
        self.caption = caption
    }
}

/// One block of the profile body. An enum with associated values rather than "one type field + three optional fields",
/// so combinations like "a text block carrying a mediaId" or "a video block with no duration" cannot be assembled at the type level.
enum PopopxProfileBlock: Codable, Hashable, Sendable {
    case text(String)
    case image(PopopxProfileMedia)
    case video(PopopxProfileMedia)

    var media: PopopxProfileMedia? {
        switch self {
        case .text: return nil
        case let .image(media): return media
        case let .video(media): return media
        }
    }

    /// The counting rule that feeds `omittedMediaCount`: one media block = 1.
    var mediaCount: Int {
        switch self {
        case .text: return 0
        case .image, .video: return 1
        }
    }
}

// MARK: - Profile manifest

/// Everything one profile contains. The `Codable` shape is the JSON inside `data=`, and it is also the shape of the local
/// `manifest.json` - the two share one codec (`encodedJSON()` / `decoded(json:)`)
/// so that "it stores but cannot be sent", or the reverse, cannot happen.
struct PopopxProfileManifest: Codable, Hashable, Sendable {
    /// Protocol version. Changing what a field means requires replacing this string; adding an optional field does not.
    static let version = "popopx_profile_v1"

    var profileVersion: String
    /// `UUID().uuidString.lowercased()`. The recipient's media directory is partitioned by it.
    var profileId: String
    var title: String
    var subtitle: String?
    var sendMode: PopopxProfileSendMode
    /// Seconds. Always 0 when `sendMode == .standard` (guaranteed by `normalized()`).
    var ttlSeconds: Int
    var deliveryMode: PopopxProfileDelivery
    /// How many images/videos were dropped by the Mesh downgrade. Always 0 when `deliveryMode == .fullMedia`.
    var omittedMediaCount: Int
    /// Whether reading starts the front-camera peek/hidden-recording check. Only meaningful on the `.ephemeral` tier, but the field itself is permanent.
    var enableAntiSpyCamera: Bool
    /// The credit points this profile costs to view. `nil` = free to read, which is also what every old profile decodes to (no `credits=` in the envelope,
    /// no such key in the JSON, both judged nil), so `version` needs no bump: that comment says "adding an optional field needs no version change".
    ///
    /// It sits both in the envelope (`credits=`) and in the body, the same treatment as `mode`/`ttl`/`delivery`: the envelope slot lets the decision
    /// of "charge first or not" happen without decoding a piece of base64 JSON, while the body copy is the single source of truth - unequal in the two places kills the whole string (see `parseToken`).
    /// The upper bound is not clamped here: `PopopxCreditsManager.unlockProfile` judges `1...maximumCreditsThreshold` itself,
    /// the debit side is where the money's boundary is, and there should not be a second source of truth between display and debit.
    ///
    /// The `= nil` is written for the compiler: the rule that an optional property "is already nil" does not hand the memberwise initialiser a default argument,
    /// and without those two characters every call site outside `blank()` that builds a manifest by hand would have to pass one more parameter.
    var unlockCredits: Int? = nil
    var updatedAt: TimeInterval
    var blocks: [PopopxProfileBlock]

    /// The maker's starting point. The default lands on `.standard` (permanent) rather than `.ephemeral`: a skeleton with no content written yet
    /// should not come with "destroyed 60 seconds after opening", a property that changes the recipient's behaviour; the privacy tier has to be chosen by the user explicitly once.
    static func blank() -> PopopxProfileManifest {
        PopopxProfileManifest(
            profileVersion: version,
            profileId: UUID().uuidString.lowercased(),
            title: "",
            subtitle: nil,
            sendMode: .standard,
            ttlSeconds: 0,
            deliveryMode: .fullMedia,
            omittedMediaCount: 0,
            enableAntiSpyCamera: false,
            updatedAt: Date().timeIntervalSince1970,
            blocks: []
        )
    }

    var mediaCount: Int {
        blocks.reduce(0) { $0 + $1.mediaCount }
    }

    /// The projection for the Mesh path: drop every image/video block, record how many were dropped, and switch the delivery mode to `.meshTextOnly`.
    /// Send mode, duration and `profileId` are all kept exactly as they were - the downgrade changes the **amount of content**, not the privacy semantics.
    var textOnly: PopopxProfileManifest {
        var copy = self
        var texts: [PopopxProfileBlock] = []
        texts.reserveCapacity(blocks.count)
        for block in blocks {
            switch block {
            case let .text(body): texts.append(.text(body))
            case .image, .video: break
            }
        }
        copy.blocks = texts
        // Idempotent: a manifest already downgraded once must not be computed again (by then `mediaCount` is 0, which would wipe the real omitted count).
        copy.omittedMediaCount = deliveryMode == .meshTextOnly ? omittedMediaCount : mediaCount
        copy.deliveryMode = .meshTextOnly
        return copy
    }

    /// Brings the manifest back to its invariants. The only entry point before sending is `PopopxProfilePayload.make`, which validates first and normalises after,
    /// so every clause here corresponds to a shape the peer would certainly reject.
    ///
    /// Note that `.standard` only wipes `ttlSeconds` and does **not** wipe `omittedMediaCount`: a permanent card over Mesh still
    /// has to drop its media, and zeroing that number would make the reader report "0 items auto-omitted" - a lie told to a pair of users face to face.
    /// The cross-mode invariant is `fullMedia => omitted == 0`, not `standard => omitted == 0`.
    func normalized() -> PopopxProfileManifest {
        var copy = self
        switch copy.sendMode {
        case .standard:
            copy.ttlSeconds = 0
        case .ephemeral:
            copy.ttlSeconds = min(max(copy.ttlSeconds, PopopxProfilePayload.minimumTTLSeconds), PopopxProfilePayload.maximumTTLSeconds)
        }
        switch copy.deliveryMode {
        case .fullMedia:
            copy.omittedMediaCount = 0
        case .meshTextOnly:
            var texts: [PopopxProfileBlock] = []
            texts.reserveCapacity(copy.blocks.count)
            for block in copy.blocks {
                switch block {
                case let .text(body): texts.append(.text(body))
                case .image, .video: break
                }
            }
            copy.blocks = texts
            copy.omittedMediaCount = min(max(copy.omittedMediaCount, 0), PopopxProfilePayload.maximumBlocks)
        }
        return copy
    }

    // MARK: JSON

    /// The encoding shared by the local archive and `data=`: sorted keys, no indentation. Sorting is so that the same content yields the same bytes every time
    /// (tests can compare strings directly, and two `data=` blocks in a log can be compared by eye); no indentation because the whole manifest has to squeeze into
    /// the `maximumJSONBytes` budget.
    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data: Data
        do {
            data = try encoder.encode(self)
        } catch {
            throw PopopxProfileError.damagedJSON
        }
        guard data.count <= PopopxProfilePayload.maximumJSONBytes else {
            throw PopopxProfileError.oversizedJSON(bytes: data.count)
        }
        return data
    }

    /// Decodes a piece of JSON from any source. Anything unqualified returns nil instead of throwing: callers already have a "kill the whole token" path,
    /// and at this point it is not even settled whether this is a profile at all.
    ///
    /// Every cap is judged **before construction**, because `JSONDecoder` will go and really allocate memory according to the array lengths in the JSON.
    static func decoded(json data: Data) -> PopopxProfileManifest? {
        guard !data.isEmpty, data.count <= PopopxProfilePayload.maximumJSONBytes else { return nil }
        guard let manifest = try? JSONDecoder().decode(PopopxProfileManifest.self, from: data) else { return nil }
        guard manifest.profileVersion == version else { return nil }
        guard manifest.blocks.count <= PopopxProfilePayload.maximumBlocks else { return nil }
        guard manifest.title.count <= PopopxProfilePayload.maximumTitleCharacters else { return nil }
        guard manifest.ttlSeconds >= 0 else { return nil }
        return manifest
    }
}

// MARK: - Errors

/// All the reasons that can be voiced while minting a payload. The interface shows the sentences below, not the enum cases themselves, so there is no
/// `LocalizedError`。
///
/// need to localise the case names. `invalidMode` / `invalidDelivery` / `damagedBase64`, those three, **are never thrown** in this file: they describe
/// failures on the receiving direction, while `parse`'s contract is to return nil. They are kept for callers that "first take the string field, then decide how to report the error"
/// (the scan-a-code path, for instance, owes the user a plain sentence); deleting them would leave those call sites inventing their own strings.
enum PopopxProfileError: Error, Hashable, Sendable {
    /// The manifest version is not recognised.
    case unknownVersion(String)
    /// The `mode=` slot is not one of `ephemeral`/`standard`.
    case invalidMode(String)
    /// The `delivery=` slot is not one of `full`/`mesh`.
    case invalidDelivery(String)
    /// The duration is out of range, or the permanent tier carries a non-0 duration.
    case invalidTTL(Int)
    /// `data=` is not valid base64url.
    case damagedBase64
    /// The JSON could not be encoded or could not be read.
    case damagedJSON
    /// The encoded manifest exceeds `PopopxProfilePayload.maximumJSONBytes`.
    case oversizedJSON(bytes: Int)
    /// The title exceeds `PopopxProfilePayload.maximumTitleCharacters`.
    case oversizedTitle(characters: Int)
    /// The content blocks exceed `PopopxProfilePayload.maximumBlocks`.
    case tooManyBlocks(count: Int)

    /// The user-facing line of Chinese: it says clearly "what is wrong" and promises no remedial action.
    var reasonText: String {
        switch self {
        case let .unknownVersion(version):
            return String(format: NSLocalizedString("This profile's data version is not recognised (%@); POPOPX has to be updated before it can open", comment: ""), version)
        case let .invalidMode(mode):
            return String(format: NSLocalizedString("This profile's send mode is not recognised (%@)", comment: ""), mode)
        case let .invalidDelivery(delivery):
            return String(format: NSLocalizedString("This profile's delivery mode is not recognised (%@)", comment: ""), delivery)
        case let .invalidTTL(ttl):
            return String(format: NSLocalizedString("This profile's burn-after-reading time is not valid (%lld seconds)", comment: ""), ttl)
        case .damagedBase64:
            return NSLocalizedString("This profile's content encoding is damaged and cannot be read", comment: "")
        case .damagedJSON:
            return NSLocalizedString("This profile's content structure is damaged and cannot be read", comment: "")
        case let .oversizedJSON(bytes):
            return String(format: NSLocalizedString("This profile holds too much (%1$lld bytes, limit %2$lld): cut some text or media", comment: ""), bytes, PopopxProfilePayload.maximumJSONBytes)
        case let .oversizedTitle(characters):
            return String(format: NSLocalizedString("The title is too long (%1$lld characters, limit %2$lld)", comment: ""), characters, PopopxProfilePayload.maximumTitleCharacters)
        case let .tooManyBlocks(count):
            return String(format: NSLocalizedString("Too many content blocks (%1$lld, limit %2$lld)", comment: ""), count, PopopxProfilePayload.maximumBlocks)
        }
    }
}

// MARK: - Payload

/// The payload of one profile message. It is a pure projection of `manifest`: no encoding result is cached, so the state
/// of "the manifest changed but the wire bytes are still the old ones" cannot exist, and `Hashable` therefore only has to compare one field.
struct PopopxProfilePayload: Hashable, Sendable {
    static let scheme = "popopx"
    /// Only this one host is accepted; `sec` and `loc` are already taken by the other two features.
    static let host = "profile"

    /// The three choices offered in the maker. Range validation goes through `minimum/maximumTTLSeconds`; these three are just the UI's set of values.
    static let ttlOptions = [60, 300, 3600]
    /// Lower bound 1 second: shorter and there is no "open" action left to speak of - the recipient would reach zero before the content is drawn.
    static let minimumTTLSeconds = 1
    /// Upper bound 3600 seconds: an hour of image-and-text card parked on the screen is not a product, it is an incident.
    static let maximumTTLSeconds = 3600
    /// The byte budget for the manifest JSON. Where `6 KiB` comes from: Mesh's per-message fragmentation budget is counted in KB, and a card's text volume
    /// never needs that much; pinning the cap is cheaper than letting the sender hit truncation somewhere in the link.
    static let maximumJSONBytes = 6_144
    /// Content-block cap. It stops a peer from feeding the recipient's main thread dead with 10⁵ empty blocks - parsing happens on the other person's device,
    /// so the cost has to be the recipient's call.
    static let maximumBlocks = 24
    /// Title cap (in grapheme counts, not bytes). The degradation line, the card and the notification preview all carry this one title line only.
    static let maximumTitleCharacters = 40

    var manifest: PopopxProfileManifest

    init(manifest: PopopxProfileManifest) {
        self.manifest = manifest
    }

    // MARK: Minting

    /// The sending side's only construction entry point: validate first (throws), then normalise (guarantees the invariants), finally encode (judges the byte budget).
    ///
    /// Validation sitting **before** normalisation is deliberate: `normalized()` would clamp 3000 seconds to 3600, and silently clamping means
    /// the user picked 50 minutes and the peer receives 1 hour; that has to be refused on the spot.
    static func make(_ manifest: PopopxProfileManifest) throws -> PopopxProfilePayload {
        guard manifest.profileVersion == PopopxProfileManifest.version else {
            throw PopopxProfileError.unknownVersion(manifest.profileVersion)
        }
        guard manifest.title.count <= maximumTitleCharacters else {
            throw PopopxProfileError.oversizedTitle(characters: manifest.title.count)
        }
        guard manifest.blocks.count <= maximumBlocks else {
            throw PopopxProfileError.tooManyBlocks(count: manifest.blocks.count)
        }
        switch manifest.sendMode {
        case .standard:
            guard manifest.ttlSeconds == 0 else { throw PopopxProfileError.invalidTTL(manifest.ttlSeconds) }
        case .ephemeral:
            guard (minimumTTLSeconds...maximumTTLSeconds).contains(manifest.ttlSeconds) else {
                throw PopopxProfileError.invalidTTL(manifest.ttlSeconds)
            }
        }
        let normalized = manifest.normalized()
        // If it cannot be encoded, the manifest itself is faulty (`encodedJSON` throws `damagedJSON` / `oversizedJSON`).
        _ = try normalized.encodedJSON()
        return PopopxProfilePayload(manifest: normalized)
    }

    // MARK: Wire bytes

    /// The line meant for humans. It never contains any block body - the chat list, the notification banner and the quote preview all take this message's
    /// `text`; anything beyond the title can only be decoded out of `data=`, and those views get this line, not the JSON.
    ///
    /// **Always one line**: `title` comes from the peer and may perfectly well contain newlines, so whitespace is collapsed into a single space here
    /// (the same technique as `PopopxLocation.swift:105`-`:112`, except that it collapses inside `init`,
    /// while here it has to collapse at the display point, because the payload does not accept a "cleaned copy").
    var degradeLine: String {
        "👤 " + NSLocalizedString("[Encrypted profile]", comment: "POPOPX encrypted profile") + " \(Self.oneLine(manifest.title)) (\(manifest.sendMode.cardLabel))"
    }

    /// The line meant for machines. Every value in the envelope contains only `[A-Za-z0-9-_]`: `mode`/`delivery` are whitelisted words, `ttl` and
    /// `credits` are decimal digits, and `data` is unpadded base64url (the three characters `+` `/` `=` are not in that alphabet at all).
    /// So this needs neither the `.alphanumerics` escaping of `PopopxLocation.swift:81`-`:84`, nor can it produce
    /// the "field value containing whitespace/`&`/`=" that `PopopxSecurePayload.swift:131`-`:133` warns about, which is what makes it safe for the parser to split tokens on whitespace,
    /// fields on `&`, and key/value on the first `=`.
    ///
    /// `credits=` is the single **optional** slot: old profiles went out before the concept existed, and its absence means free,
    /// not "this payload is incomplete". Any of the other four slots missing kills the whole string.
    var wireString: String {
        let mode = manifest.sendMode.wireValue
        let ttl = manifest.ttlSeconds
        let delivery = manifest.deliveryMode.wireValue
        // `make` has already encoded once and guarantees it encodes; the `try?` here only covers "a malformed manifest was stuffed in by hand",
        // and the price is one empty payload - see the note on `init(manifest:)`.
        let data = (try? manifest.encodedJSON()).map { $0.popopxBase64URL } ?? ""
        var wire = "\(Self.scheme)://\(Self.host)?mode=\(mode)&ttl=\(ttl)&delivery=\(delivery)"
        // Order: `credits` comes before `data`, the same reading order as the `fieldNames` whitelist, and it also puts the gate in plain sight.
        if let credits = manifest.unlockCredits, credits > 0 {
            wire += "&credits=\(credits)"
        }
        return wire + "&data=\(data)"
    }

    /// The text actually sent. It is plain text, so like location and secure messages it naturally satisfies the mesh preconditions of `PopopxComposerRouting`
    /// (no attachment, no quote, 1:1 direct chat), so no extra test slot is needed for it.
    var messageContent: String {
        degradeLine + "\n" + wireString
    }

    /// Whether this card is the "destroyed on a timer after opening" tier. The reading clock should only be asked when that is true (see
    /// `ProfileStorageManager.readState`）。
    var isEphemeral: Bool {
        manifest.sendMode == .ephemeral
    }

    /// Putting the timing semantics into one plain sentence (card subtitle, VoiceOver). The duration itself is left to `PopopxSecureCopy.duration`:
    /// the whole app has only two duration formatters, and no third one needs to appear.
    var ttlText: String {
        switch manifest.sendMode {
        case .standard:
            return NSLocalizedString("No destruction timer", comment: "")
        case .ephemeral:
            return String(format: NSLocalizedString("%@ · counted from the first open", comment: ""), PopopxSecureCopy.duration(manifest.ttlSeconds))
        }
    }

    // MARK: Parsing

    /// Reads one profile payload out of arbitrary text; when it reads nothing it returns nil, and the caller (`PopopxBubbleMount`)
    /// treats nil as "this is not a profile message" and hands it back to the original plain-text rendering.
    ///
    /// With several candidates hit, take **the last one**: the producer appends the machine line after the human line, and the title itself may contain
    /// a string that looks like a payload (`popopx://profile?mode=standard&ttl=0&delivery=full&data=` written as somebody's nickname,
    /// or forwarded text). Taking the first would render the card as the half line the user typed themselves.
    /// Same as `PopopxSecurePayload.swift:163`-`:164`, `PopopxLocation.swift:123`-`:126`.
    static func parse(from text: String) -> PopopxProfilePayload? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            if let payload = parseToken(String(token)) {
                return payload
            }
        }
        return nil
    }

    /// The verdict on a single token. Exposed so that callers that "already know they cut out a candidate string" (the scan-a-code path) can reuse it
    /// instead of copying the four-slot validation again.
    static func parseToken(_ token: String) -> PopopxProfilePayload? {
        guard let components = URLComponents(string: token),
              components.scheme == scheme,
              components.host == host
        else { return nil }

        var fields: [String: String] = [:]
        // It has to go through `percentEncodedQuery`: `query` hands back an **already decoded** string, so `data=eyJ%61` would first
        // change shape there, and splitting on `&` after that truncates the manifest down to one slot. Same as `PopopxSecurePayload.swift:181`-`:182`.
        for pair in components.percentEncodedQuery?.split(separator: "&") ?? [] {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<separator])
            // The whitelist comparison uses the **encoded raw bytes**: a key written as `d%61ta` does not get in (`PopopxLocation.swift:149`-`:151`
            // same test). Rogue keys are dropped without exception - a string must not reach the interface by borrowing our scheme.
            guard fieldNames.contains(key) else { continue }
            let rawValue = String(pair[pair.index(after: separator)...])
            // `URLComponents` repairs illegal escapes first, so what this guard blocks are sequences that are "syntactically legal but whose bytes are not UTF-8"
            // (`%C0%80`, `%FF`). Such a token is killed whole, with no fallback to the original string.
            // Same as `PopopxLocation.swift:154`-`:157`.
            guard let value = rawValue.removingPercentEncoding else { return nil }
            fields[key] = value
        }

        guard let rawMode = fields["mode"], let mode = PopopxProfileSendMode.fromWire(rawMode),
              let rawDelivery = fields["delivery"], let delivery = PopopxProfileDelivery.fromWire(rawDelivery),
              // `Int("+300")` decodes successfully too, so the length cap has to be enforced by "the whole string is digits only", not by the value range.
              let rawTTL = fields["ttl"],
              rawTTL.allSatisfy(\.isNumber),
              rawTTL.count <= Self.maximumTTLDigits,
              let ttl = Int(rawTTL),
              let encodedJSON = fields["data"],
              // Cap the allocation by character count first, then decode: an 8 MB `data=` is worth rejecting before it becomes `Data`.
              encodedJSON.count <= Self.maximumEncodedJSONCharacters,
              let jsonData = Data(popopxBase64URL: encodedJSON),
              let manifest = PopopxProfileManifest.decoded(json: jsonData)
        else { return nil }

        // Envelope and body must tell the same story. If any of the three slots disagrees with the field in the JSON, this path has been tampered with
        // (or it is some other implementation's encoding), and we cannot believe half of it.
        guard manifest.sendMode == mode, manifest.deliveryMode == delivery, manifest.ttlSeconds == ttl else {
            return nil
        }
        // `credits=` is the only slot that may be absent besides the four mandatory ones, so it does not enter the `guard let` chain above:
        // absent = free, which is the normal shape of the old profile page, not a defect; if it is written it must be pure digits and must not exceed the digit ceiling;
        // then compare the copy in the envelope against the copy in the JSON -- for money, two places each telling their own story is the least tolerable kind of divergence.
        let rawCredits = fields["credits"]
        if let rawCredits {
            guard rawCredits.allSatisfy(\.isNumber), rawCredits.count <= Self.maximumThresholdDigits else { return nil }
        }
        guard manifest.unlockCredits ?? 0 == (rawCredits.flatMap(Int.init) ?? 0) else { return nil }
        switch mode {
        case .standard:
            guard ttl == 0 else { return nil }
        case .ephemeral:
            guard (minimumTTLSeconds...maximumTTLSeconds).contains(ttl) else { return nil }
        }

        return PopopxProfilePayload(manifest: manifest.normalized())
    }

    private static let fieldNames: Set<String> = ["mode", "ttl", "delivery", "credits", "data"]

    /// digit ceiling for `ttl=`. `maximumTTLSeconds` is 3600, so four digits are enough; any extra digits are rejected outright,
    /// so that nobody probes the boundary of `Int` with `99999999999`.
    private static let maximumTTLDigits = 4

    /// digit ceiling for `credits=`, taken straight from that table in the commerce layer (`PopopxCommerceLimits.maximumThresholdDigits`,
    /// derived from `maximumCreditsThreshold = 100_000`). Copying a number here would be a second source of truth,
    /// and two sources of truth will part company sooner or later on the day the threshold is raised.
    private static let maximumThresholdDigits = PopopxCommerceLimits.maximumThresholdDigits

    /// maximum character count after base64url encoding (including the padding-carrying form). `((bytes + 2) / 3) * 4` is the standard base64
    /// length upper bound, and working back from it means we do not have to decode the whole blob into `Data` before learning it is over budget.
    private static let maximumEncodedJSONCharacters = ((maximumJSONBytes + 2) / 3) * 4

    /// whitespace collapses into a single space; an empty title gets a placeholder word so that a degraded row never shows two adjacent spaces.
    private static func oneLine(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? NSLocalizedString("Unnamed profile", comment: "POPOPX encrypted profile") : collapsed
    }
}
