//
//  PopopxEcoModels.swift
//  POPOPX (iOS)
//
//  The wire layer of the service-account ecosystem: what one `::POPOPX_ECO::` frame looks like, what it decodes to, and where its
//  state lives on this device. It deliberately touches neither CryptoKit nor UIKit — the crypto is in `ChannelKeyRotationManager.swift`,
//  the presentation in the three view files, so this file can be reasoned about (and unit-tested) as pure string arithmetic.
//
//  1. One marker, two parsing boundaries — and the difference between them is a security property, not a style preference:
//     - a frame that **mutates this device** (session secret, menu, channel key) is parsed by whole-string equality, exactly like
//       `::popopx_sys::` (`PopopxSysMarker.parse`, PopopxBadgeCreditsModels.swift:1135). Quoting such a frame inside a sentence must
//       not be able to rotate a key or replace a menu, so the message may contain nothing but the frame.
//     - a frame that only **renders** (the visible card) is searched unanchored, exactly like `popopx://loc`
//       (PopopxLocation.swift:124) and `popopx://gift`. Pasteing a card into a conversation is harmless: it carries no secret and
//       performs no action by itself — every button on it is an explicit user tap.
//     `isControlFrame` below is the single copy of that split; the render-suppression gates consume it and never restate it.
//
//  2. The field names are the ones `service_office.md` dictates (`::CB::`, `::REF::`, `::SSO_SCAN::`, `pay_credits`, `send_cmd`,
//     `open_url`, `open_channel`, `standard`/`receipt`/`security`). Compact one-letter envelope keys follow the house style of the
//     `gift`/`redpacket`/`channel` payloads (PopopxBadgeCreditsModels.swift:612): short keys, values that need no escaping, and
//     unknown keys dropped rather than rejected, so a server that adds a field cannot break an installed build.
//
//  3. Every limit in `PopopxEcoLimits` is enforced *here*, before anything reaches a view: a card is data the receiver did not ask
//     for, and one unbounded string is a memory complaint in a chat list that renders twenty of them per screen.
//
//  4. Nothing in this file writes to the Keychain directly except `PopopxEcoKeychain`, whose accessibility attribute is
//     `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (the brief's module-1 requirement). That is *stricter* than the commerce
//     family's `…AfterFirstUnlockThisDeviceOnly` (PopopxBadgeCreditsModels.swift:1403) on purpose: a pairwise session secret must
//     not be readable while the device is locked, and nothing in this module needs to read it from a background task.
//
//  5. Two premises in the brief are not true of this checkout, and the code follows the checkout:
//     - `ChannelAccessToken` does not exist (zero hits repo-wide). The real channel credential is
//       `PopopxChannelSubscriptionTicket` (PopopxCreditsManager.swift:491/532), and "issue/update the access token" is implemented
//       as writing that ticket, not as a new type.
//     - the existing chat-stream URI `popopx://channel?p=…&t=…&e=…&s=…` (`PopopxChannelAccessPayload`, PopopxBadgeCreditsModels.swift:969)
//       already owns host `channel` in **query** form. The module-1 public channel URI is **path** form with a fragment, so the two
//       parsers reject each other by shape; see `PopopxChannelPublicURI`.
//

import Foundation
import Security

// MARK: - Limits

/// The caps of one eco frame. They are numbers, not prose: a frame that exceeds any of them is dropped in the parser, and the
/// sender sees nothing (silent drop is the same policy the commerce signalling uses — an error toast for a message the user
/// never sent would only teach them that signalling exists).
enum PopopxEcoLimits {
    /// Compact JSON of one frame, counted in Unicode scalars. A menu with three items and five sub-items is about 700 bytes;
    /// 8 192 leaves room for a receipt card with eight key/value rows and still costs less than one image attachment.
    static let maximumFrameCharacters = 8_192
    static let maximumCardIdCharacters = 64
    static let maximumTitleCharacters = 120
    static let maximumBodyCharacters = 2_000
    static let maximumLabelCharacters = 80
    static let maximumValueCharacters = 240
    static let maximumPayloadCharacters = 512
    static let maximumURLCharacters = 2_048
    /// How long a scanned deep link may keep its intent waiting for the session handshake (`PopopxEcoRouter.deliverPendingIntent`).
    /// Five minutes: long enough for a first connection over a slow relay or a server that has to wake up, short enough that a link
    /// scanned and then abandoned is never delivered to whichever service account happens to handshake next hour.
    static let pendingIntentLifetimeSeconds: TimeInterval = 300
    static let maximumFields = 8
    static let maximumActions = 4
    /// Three top-level buttons is the brief's module-3 requirement, and it is also WeChat's own limit for a custom menu.
    static let maximumMenuItems = 3
    static let maximumSubItems = 5
    static let maximumProgressPercent = 100
    /// The same ceiling as `PopopxCommerceLimits.maximumCreditsThreshold` (100 000): a card may not ask for more than the
    /// channel-threshold UI is allowed to ask for, otherwise one frame would be a bigger spend than any screen the app owns.
    static let maximumCreditAmount = 100_000
    /// The floor of one card payment. `0` is refused for the same reason `PopopxChannelAccessPayload.make` refuses a zero
    /// threshold (PopopxBadgeCreditsModels.swift:1015): it deducts nothing, leaves no ledger row, and so is only noise.
    static let minimumAmount = 1
    static let maximumSessionSecretHexCharacters = 64
}

// MARK: - Frame

/// One decoded `::POPOPX_ECO::` frame. The four cases are the four frames the server pushes; anything else does not decode.
enum PopopxEcoFrame: Hashable, Sendable {
    /// The pairwise identity + session secret a service account hands out when someone follows it.
    case sessionHandshake(PopopxEcoSession)
    /// The custom bottom menu of this service account.
    case menuConfig(PopopxEcoMenu)
    /// A card: `create` renders a bubble, `update` mutates the card that is already on screen.
    case serviceCard(PopopxServiceCard)
    /// A new channel epoch key (Module 1); the crypto is verified in `ChannelKeyRotationManager.swift`, not here.
    case channelKeyUpdate(PopopxChannelKeyUpdate)

    /// Whether this frame must never reach a bubble, a chat-list preview or a notification.
    ///
    /// Everything except a card in `create` mode is suppressed. A card update is suppressed because the card it belongs to is
    /// already rendered: the row is mutated in place and then deleted by the router, which is what "禁止重复刷出新气泡" means at
    /// the message layer — the stream is append-only, so an in-place update is "a control frame that erases itself".
    var isControlFrame: Bool {
        if case .serviceCard(let card) = self { return card.mode != .create }
        return true
    }
}

/// The codec for `::POPOPX_ECO::`.
enum PopopxEcoMarker {
    static let marker = "::POPOPX_ECO::"

    /// Whole-string parse: the only entry point for a frame that mutates this device.
    ///
    /// The same three-step discipline as `PopopxSysMarker.parse` (PopopxBadgeCreditsModels.swift:1144): trim, compare the prefix,
    /// then require that nothing else remains. A frame inside a longer text returns nil *by design* — see header item 1.
    static func parse(controlText text: String) -> PopopxEcoFrame? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(marker) else { return nil }
        let json = String(trimmed.dropFirst(marker.count))
        // Newlines are the other half of "nothing else remains": a frame with a trailing sentence would decode fine as JSON and
        // silently execute while the user sees their own text. `JSONDecoder` accepts a pretty-printed document, so this check pays.
        guard !json.contains("\n"), !json.contains("\r") else { return nil }
        return decode(json)
    }

    /// Unanchored parse of a **visible card** frame: split on whitespace, try each token from the end.
    ///
    /// Searching from the end matches `PopopxLocationPayload.parse`: the producer puts the machine line after the readable one, so
    /// the last candidate is the real payload, and a place name that happens to look like a payload cannot win.
    static func parseVisibleCard(in text: String) -> PopopxServiceCard? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            guard token.hasPrefix(marker) else { continue }
            let json = String(token.dropFirst(marker.count))
            guard let frame = decode(json), case .serviceCard(let card) = frame, card.mode == .create else { continue }
            return card
        }
        return nil
    }

    /// The render-suppression criterion. One copy, shared by the three gates (`ChatView.swift:2325`,
    /// `ChatPreviewView.swift:305`, `NtfManager.swift:258`) through `PopopxSysMarker.isSignalText`.
    static func isControlText(_ text: String) -> Bool {
        parse(controlText: text)?.isControlFrame ?? false
    }

    /// Wire form of a frame. Used by the tests and by nothing on the sending path except the card-update confirmation the
    /// router writes back — the app never invents a `session_handshake` or a `menu_config`.
    static func wireString(for frame: PopopxEcoFrame) -> String {
        "\(marker)\(String(decoding: PopopxEcoCodec.json(for: frame), as: UTF8.self))"
    }

    private static func decode(_ json: String) -> PopopxEcoFrame? {
        guard json.count <= PopopxEcoLimits.maximumFrameCharacters,
              let data = json.data(using: .utf8) else { return nil }
        // One shared `JSONDecoder` would be fine for correctness but not for `DecodingError` hygiene; the codec owns it, see
        // `PopopxEcoCodec`.
        guard let frame = PopopxEcoCodec.frame(from: data) else { return nil }
        return frame.isSane ? frame : nil
    }
}

// MARK: - Uplink lines

/// The three machine lines this device sends *up* to a service account.
///
/// One definition on purpose. The sender (`PopopxEcoRouter.sendCallback`/`sendReference`/`sendSSOScan`) and the render-suppression
/// gate (`PopopxSysMarker.isSignalText`) must agree character for character: a prefix added here but forgotten in the gate shows the
/// user a machine line as their own sent bubble, in the chat list preview and in a notification, and a prefix added to the gate but
/// not the sender hides a message the user meant to send. `PopopxEcoRouter` builds its wire text from these constants, so the two
/// ends cannot drift without the send itself changing.
///
/// These are plain text, not `::POPOPX_ECO::` frames: `service_office.md:91-92` dictates the wire names, and the service parses them
/// out of an ordinary message. That is also why they need their own gate — `PopopxEcoMarker.isControlText` only ever answers for a
/// whole-string frame with the `::POPOPX_ECO::` marker, and none of these carries one.
enum PopopxEcoUplink {
    static let callbackPrefix = "::CB::"
    static let referencePrefix = "::REF::"
    static let ssoScanPrefix = "::SSO_SCAN::"

    private static let prefixes = [callbackPrefix, referencePrefix, ssoScanPrefix]

    /// The whole line this device would have sent for that payload, or nil when the payload is not sendable. Refusing to build the line
    /// is the only safe answer for a payload with whitespace or a second `::`: both would reach the service as two commands.
    static func wireString(prefix: String, payload: String) -> String? {
        guard prefixes.contains(prefix), isSendablePayload(payload) else { return nil }
        return "\(prefix)\(payload)"
    }

    /// The suppression criterion. Mirrors the three-step discipline of `PopopxEcoMarker.parse` and `PopopxSysMarker.parse`:
    /// trim, match one prefix, then require that a single clean token is all that remains. A sentence that merely quotes one of these
    /// lines ("why did you send ::CB::abc ?") is a message the user wrote and must stay visible.
    static func isUplinkText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = prefixes.first(where: { trimmed.hasPrefix($0) }) else { return false }
        return isSendablePayload(String(trimmed.dropFirst(prefix.count)))
    }

    /// What a payload must look like to travel: one ASCII-clean token, no room for a second command.
    /// Internal rather than private so a caller can prove a payload before it commits the side effect that produces it.
    static func isSendablePayload(_ payload: String) -> Bool {
        !payload.isEmpty
            && payload.count <= PopopxEcoLimits.maximumPayloadCharacters
            && payload.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && !payload.contains("::")
    }
}

extension PopopxEcoFrame {
    /// Second-pass validation: the JSON decoded, but is every field inside the caps, and is no required field empty?
    ///
    /// Kept apart from the decoder because the decoder's job is shape and this job is size, and because a `PopopxServiceCard` that
    /// arrives as `update` must be judged by the same rules as one that arrives as `create` — otherwise an update could shrink a
    /// rendered card into an empty shell.
    var isSane: Bool {
        switch self {
        case .sessionHandshake(let session):
            return session.isSane
        case .menuConfig(let menu):
            return menu.isSane
        case .serviceCard(let card):
            return card.isSane
        case .channelKeyUpdate(let update):
            return update.isSane
        }
    }
}

// MARK: - Codec

/// JSON plumbing for the eco wire. A separate type so the encoders (and the `ISO8601`/millisecond decision) exist once.
///
/// Timestamps are **epoch milliseconds as integers**, not ISO-8601 strings: that is what the rest of this app's signed payloads use
/// (`PopopxGiftCardPayload.mintedAtMs`, `PopopxChannelAccessPayload.publishedAtMs`), and a string date would be a second format to
/// agree with the server about.
enum PopopxEcoCodec {
    static func frame(from data: Data) -> PopopxEcoFrame? {
        guard let wire = try? decoder().decode(PopopxEcoWire.self, from: data) else { return nil }
        return wire.frame
    }

    static func json(for frame: PopopxEcoFrame) -> Data {
        (try? wireEncoder().encode(PopopxEcoWire(wireFor: frame))) ?? Data()
    }

    /// Decode any eco value from JSON, `nil` on failure. Used for the Keychain and `UserDefaults` blobs as well as for wire bytes,
    /// so exactly one decoder's settings decide how a stored document is read.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data, let value = try? decoder().decode(type, from: data) else { return nil }
        return value
    }

    /// Encode any eco value to JSON. `sortedKeys` is on for the same reason `PopopxCommerceKeychain.encode` turns it on
    /// (PopopxBadgeCreditsModels.swift:1421): the stored bytes are compared and diffed by the tests, and a dictionary that
    /// reshuffles between launches reads as a change that never happened.
    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    /// Built per call rather than held in a `static let`: `JSONDecoder` is not `Sendable`, and a shared immutable-looking instance of
    /// a non-Sendable class is a strict-concurrency warning the build gate does not forgive. Frames are rare enough that the
    /// allocation is free, and this is how `PopopxCommerceKeychain` already does it.
    private static func decoder() -> JSONDecoder { JSONDecoder() }

    private static func wireEncoder() -> JSONEncoder {
        // No sorted keys, no pretty printing: a control frame is written into a message body, and every byte of it costs the peer
        // bandwidth. The default formatting is also stable enough to compare in a test without being padded.
        JSONEncoder()
    }
}

/// The wire shape of one frame: a discriminant plus exactly one payload section.
///
/// Declared `private` to the file it belongs in is impossible across types, so it is internal but never leaves this file's use —
/// every field is optional on purpose, so a frame that omits `menu` while claiming `t = "mc"` fails validation instead of throwing.
struct PopopxEcoWire: Decodable {
    enum Kind: String, Decodable {
        case sessionHandshake = "sh"
        case menuConfig = "mc"
        case serviceCard = "sc"
        case channelKeyUpdate = "ku"
    }

    let t: Kind
    var uid: String?
    var sec: String?
    var svc: String?
    var m: String?
    var card: PopopxServiceCard?
    var menu: PopopxEcoMenu?
    var update: PopopxChannelKeyUpdate?

    /// `nil` for a frame whose payload section is missing or whose type/mode pair does not fit: `sc` without `card`, `mc` without
    /// `menu`, or a `create` mode spelled anything other than `c`.
    var frame: PopopxEcoFrame? {
        switch t {
        case .sessionHandshake:
            guard let uid, let sec else { return nil }
            return .sessionHandshake(PopopxEcoSession(pairwiseUid: uid, secretHex: sec, serviceId: svc))
        case .menuConfig:
            guard let menu else { return nil }
            return .menuConfig(menu)
        case .serviceCard:
            guard var card, let m else { return nil }
            switch m {
            case "c": card.mode = .create
            case "u": card.mode = .update
            default: return nil
            }
            return .serviceCard(card)
        case .channelKeyUpdate:
            guard let update else { return nil }
            return .channelKeyUpdate(update)
        }
    }
}

extension PopopxEcoWire: Encodable {
    private enum CodingKeys: String, CodingKey {
        case t, uid, sec, svc, m, card, menu, update
    }

    init(wireFor frame: PopopxEcoFrame) {
        switch frame {
        case let .sessionHandshake(session):
            t = .sessionHandshake
            uid = session.pairwiseUid
            sec = session.secretHex
            svc = session.serviceId
        case let .menuConfig(menu):
            t = .menuConfig
            self.menu = menu
        case let .serviceCard(card):
            t = .serviceCard
            m = card.mode == .create ? "c" : "u"
            self.card = card
        case let .channelKeyUpdate(update):
            t = .channelKeyUpdate
            self.update = update
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(t.rawValue, forKey: .t)
        try container.encodeIfPresent(uid, forKey: .uid)
        try container.encodeIfPresent(sec, forKey: .sec)
        try container.encodeIfPresent(svc, forKey: .svc)
        try container.encodeIfPresent(m, forKey: .m)
        try container.encodeIfPresent(card, forKey: .card)
        try container.encodeIfPresent(menu, forKey: .menu)
        try container.encodeIfPresent(update, forKey: .update)
    }
}

// MARK: - Session handshake

/// The pairwise identity of one follower, as issued by one service account.
///
/// Indexed by the local **contact id** of that service account, never by `svc` (the server's own id): the local id is what the send
/// path has at hand, it is unique on this device, and it is the key the brief's "按服务号 contactId 索引" asks for. `serviceId` is
/// kept beside it for display and for the `open_url` signature prefix, and is never used as a lookup key.
struct PopopxEcoSession: Codable, Hashable, Sendable {
    /// `u_…` — the pairwise, per-service pseudonym the H5 launcher signs with.
    var pairwiseUid: String
    /// Hex, lower- or upper-case, decoded to 32 bytes before it is stored.
    var secretHex: String
    var serviceId: String?

    var isSane: Bool {
        !pairwiseUid.isEmpty
            && pairwiseUid.count <= PopopxEcoLimits.maximumPayloadCharacters
            && secretBytes != nil
            && (serviceId == nil || !serviceId!.isEmpty && serviceId!.count <= PopopxEcoLimits.maximumPayloadCharacters)
    }

    /// The session secret as key material, or nil when the hex is not 1..32 bytes of hex.
    ///
    /// The cap is 32 bytes because `HMAC<SHA256>` truncates anything longer rather than rejecting it — accepting a 1 KB "secret"
    /// would silently mean a key the server does not hold, and every signature would then fail at the far end with no local clue.
    var secretBytes: Data? {
        PopopxEcoHex.decode(secretHex, maximumByteCount: 32)
    }
}

// MARK: - Menu

/// The custom bottom menu of one service account (module 3).
struct PopopxEcoMenu: Codable, Hashable, Sendable {
    /// One button. `type` is the WeChat menu vocabulary (`click` fires, `view` opens a URL, `scancode` asks the user to scan,
    /// `location` sends a location, `click_text` fills the composer instead of sending); `action` says what it fires.
    struct Item: Codable, Hashable, Identifiable, Sendable {
        enum Kind: String, Codable {
            case click
            case view
            case scancode
            case location
            case clickText = "click_text"
        }

        var id: String { title }
        var title: String
        var kind: Kind
        /// Absent on a `view` button whose `url` is the whole action; required on every firing kind.
        var action: PopopxEcoAction.Kind?
        var payload: String?
        var url: String?
        /// Only read when `kind == .click`; a nested list under a `view` button would be a menu nobody can reach.
        var subItems: [Item]

        private enum CodingKeys: String, CodingKey {
            case title, kind, action, payload, url
            case subItems = "sub"
        }

        init(title: String, kind: Kind, action: PopopxEcoAction.Kind?, payload: String?, url: String?, subItems: [Item] = []) {
            self.title = title
            self.kind = kind
            self.action = action
            self.payload = payload
            self.url = url
            self.subItems = subItems
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .click
            action = try container.decodeIfPresent(PopopxEcoAction.Kind.self, forKey: .action)
            payload = try container.decodeIfPresent(String.self, forKey: .payload)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            subItems = try container.decodeIfPresent([Item].self, forKey: .subItems) ?? []
        }

        /// A submenu is only reachable under a `click` button, so a `view` button carrying one is not a menu — it is a button whose
        /// children silently never appear. Rejecting the whole menu is better than rendering half of it.
        var isSane: Bool {
            guard !title.isEmpty, title.count <= PopopxEcoLimits.maximumLabelCharacters else { return false }
            guard subItems.count <= PopopxEcoLimits.maximumSubItems else { return false }
            if kind == .view { return url != nil && subItems.isEmpty }
            if kind == .scancode || kind == .location { return action == nil }
            guard let action else { return false }
            switch action {
            case .openURL:
                return url != nil
            case .sendCommand, .openChannel, .callback:
                return payload != nil
            case .payCredits, .none:
                return false
            }
        }
    }

    var items: [Item]

    private enum CodingKeys: String, CodingKey {
        case items
        case revision = "rev"
    }

    /// A monotonic revision the server may send; a `menu_config` older than what is on screen is dropped by the store rather than
    /// blinking the menu back to a previous shape.
    var revision: Int?

    init(items: [Item], revision: Int? = nil) {
        self.items = items
        self.revision = revision
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        revision = try container.decodeIfPresent(Int.self, forKey: .revision)
    }

    var isSane: Bool {
        !items.isEmpty
            && items.count <= PopopxEcoLimits.maximumMenuItems
            && Set(items.map(\.id)).count == items.count
            && items.allSatisfy { $0.isSane }
    }
}

// MARK: - Card

/// One dynamic business card (module 4).
///
/// The card is *content*, not a message: `cardId` is stable across updates, so the bubble that renders it is looked up by
/// `PopopxEcoStore.card(cardId:)` first and falls back to the payload it was created from. That is what lets a vote's progress bar
/// move without a second bubble appearing, and what makes a re-launch after a kill show the latest state rather than the state at
/// creation time.
struct PopopxServiceCard: Codable, Hashable, Identifiable, Sendable {
    enum Style: String, Codable {
        /// Deep-indigo badge and a hairline stroke: announcements.
        case standard
        /// A key/value grid: orders, bills, appointment tickets.
        case receipt
        /// Warning red or radar teal shield: DevOps alerts and SSO authorisation requests.
        case security
    }

    enum Mode: String, Codable {
        case create
        case update
    }

    /// A stable id from the server. Not a UUID minted here: two devices looking at the same card must reach the same state.
    var cardId: String
    /// Set by the frame's `m` field after decoding, so it is never trusted from the nested object itself.
    var mode: Mode = .create
    var style: Style
    var title: String
    var body: String?
    var fields: [Field]
    var progress: Progress?
    var actions: [PopopxEcoAction]
    /// Milliseconds. Only the newest `updatedAtMs` wins in the store, which is how a replayed older update cannot roll a card back.
    var updatedAtMs: Int64
    /// Milliseconds; after this instant the card is read-only (the vote has closed, the alert has expired).
    var expiresAtMs: Int64?

    var id: String { cardId }

    private enum CodingKeys: String, CodingKey {
        case cardId = "id"
        case style = "v"
        case mode = "m"
        case title
        case body
        case fields
        case progress
        case actions
        case updatedAtMs = "ut"
        case expiresAtMs = "et"
    }

    init(
        cardId: String,
        mode: Mode = .create,
        style: Style,
        title: String,
        body: String? = nil,
        fields: [Field] = [],
        progress: Progress? = nil,
        actions: [PopopxEcoAction] = [],
        updatedAtMs: Int64,
        expiresAtMs: Int64? = nil
    ) {
        self.cardId = cardId
        self.mode = mode
        self.style = style
        self.title = title
        self.body = body
        self.fields = fields
        self.progress = progress
        self.actions = actions
        self.updatedAtMs = updatedAtMs
        self.expiresAtMs = expiresAtMs
    }

    /// Every section is optional except the identity, so a partial card (a vote update that carries only `progress`) decodes.
    ///
    /// `style` and `updatedAtMs` are the exception: without a style there is no design decision to make, and without a timestamp
    /// two frames cannot be ordered, which is the one thing an in-place update must be able to do.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cardId = try container.decode(String.self, forKey: .cardId)
        style = try container.decode(Style.self, forKey: .style)
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .create
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body)
        fields = try container.decodeIfPresent([Field].self, forKey: .fields) ?? []
        progress = try container.decodeIfPresent(Progress.self, forKey: .progress)
        actions = try container.decodeIfPresent([PopopxEcoAction].self, forKey: .actions) ?? []
        updatedAtMs = try container.decode(Int64.self, forKey: .updatedAtMs)
        expiresAtMs = try container.decodeIfPresent(Int64.self, forKey: .expiresAtMs)
    }

    var isSane: Bool {
        !cardId.isEmpty
            && cardId.count <= PopopxEcoLimits.maximumCardIdCharacters
            && !title.isEmpty
            && title.count <= PopopxEcoLimits.maximumTitleCharacters
            && (body == nil || body!.count <= PopopxEcoLimits.maximumBodyCharacters)
            && fields.count <= PopopxEcoLimits.maximumFields
            && fields.allSatisfy(\.isSane)
            && (progress == nil || progress!.isSane)
            && actions.count <= PopopxEcoLimits.maximumActions
            && actions.allSatisfy(\.isSane)
            && Set(actions.map(\.id)).count == actions.count
            && updatedAtMs > 0
            && (expiresAtMs == nil || expiresAtMs! > 0)
    }

    /// Whether the buttons still fire, judged on the caller's clock so the view and the router cannot disagree.
    func isLive(nowMs: Int64) -> Bool {
        expiresAtMs.map { nowMs < $0 } ?? true
    }

    /// A structured key/value row of the receipt style.
    struct Field: Codable, Hashable, Identifiable, Sendable {
        var id: String { label }
        var label: String
        var value: String
        /// `mono` renders the value in the numeric monospace face: order numbers, amounts, addresses.
        var mono: Bool?

        private enum CodingKeys: String, CodingKey {
            case label = "k"
            case value = "v"
            case mono
        }

        init(label: String, value: String, mono: Bool? = nil) {
            self.label = label
            self.value = value
            self.mono = mono
        }

        var isSane: Bool {
            !label.isEmpty && label.count <= PopopxEcoLimits.maximumLabelCharacters
                && !value.isEmpty && value.count <= PopopxEcoLimits.maximumValueCharacters
        }
    }

    /// The inline progress bar (anonymous-vote percentages, deploy completion).
    struct Progress: Codable, Hashable, Sendable {
        var label: String
        var percent: Int
        var detail: String?

        private enum CodingKeys: String, CodingKey {
            case label = "l"
            case percent = "p"
            case detail = "d"
        }

        init(label: String, percent: Int, detail: String? = nil) {
            self.label = label
            self.percent = percent
            self.detail = detail
        }

        var isSane: Bool {
            !label.isEmpty
                && label.count <= PopopxEcoLimits.maximumLabelCharacters
                && (0...PopopxEcoLimits.maximumProgressPercent).contains(percent)
                && (detail == nil || detail!.count <= PopopxEcoLimits.maximumValueCharacters)
        }
    }
}

/// One tappable action on a card (module 4).
struct PopopxEcoAction: Codable, Hashable, Identifiable, Sendable {
    /// The wire vocabulary, verbatim from the brief: `callback` and `pay_credits` on a card, `send_cmd`/`open_url`/`open_channel`
    /// on a menu button. Unknown raw values fail to decode, which is the only reason the server may add a kind later without an
    /// installed build calling it `callback`.
    enum Kind: String, Codable {
        /// Silent `::CB::<payload>` back to the sender, and the button locks until the card updates.
        case callback
        /// Spend `amount` compute credits on `target`, then send `::CB::<payload>:paid_<txHash>`.
        case payCredits = "pay_credits"
        /// Open a signed H5 through `PopopxH5Launcher`.
        case openURL = "open_url"
        /// Open (or join) a zero-knowledge channel through the module-1 URI parser.
        case openChannel = "open_channel"
        /// Send `payload` as an ordinary message (menu buttons only).
        case sendCommand = "send_cmd"
        /// Nothing to do: a disabled or purely decorative row.
        case none
    }

    enum Visual: String, Codable {
        case primary
        case secondary
        case destructive
    }

    var id: String
    var title: String
    var kind: Kind
    var visual: Visual
    var payload: String?
    var url: String?
    var target: String?
    /// Compute credits this button asks for. Only read when `kind == .payCredits`.
    var amount: Int?
    /// An authorisation card whose effect is irreversible (granting a login, spending credits) asks first.
    var requiresConfirmation: Bool

    var isLive: Bool { kind != .none }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind = "action"
        case visual = "style"
        case payload
        case url
        case target
        case amount
        case requiresConfirmation = "confirm"
    }

    init(
        id: String,
        title: String,
        kind: Kind,
        visual: Visual = .primary,
        payload: String? = nil,
        url: String? = nil,
        target: String? = nil,
        amount: Int? = nil,
        requiresConfirmation: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.visual = visual
        self.payload = payload
        self.url = url
        self.target = target
        self.amount = amount
        self.requiresConfirmation = requiresConfirmation
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .none
        visual = try container.decodeIfPresent(Visual.self, forKey: .visual) ?? .primary
        payload = try container.decodeIfPresent(String.self, forKey: .payload)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        amount = try container.decodeIfPresent(Int.self, forKey: .amount)
        requiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .requiresConfirmation) ?? false
    }

    var isSane: Bool {
        guard !title.isEmpty, title.count <= PopopxEcoLimits.maximumLabelCharacters else { return false }
        switch kind {
        case .none:
            return false
        case .callback, .sendCommand:
            return payload != nil && !payload!.isEmpty && payload!.count <= PopopxEcoLimits.maximumPayloadCharacters
        case .openURL:
            return url != nil && PopopxEcoAction.isHttpURL(url!)
        case .openChannel:
            return payload != nil && PopopxChannelPublicURI.parse(payload!) != nil
        case .payCredits:
            return amount != nil
                && amount! >= PopopxEcoLimits.minimumAmount
                && amount! <= PopopxEcoLimits.maximumCreditAmount
                && (target == nil || target!.count <= PopopxEcoLimits.maximumPayloadCharacters)
        }
    }

    /// Only `http` and `https`, with a host, and never a JavaScript/custom scheme: a card is untrusted input, and a button that can
    /// hand a URL to `SFSafariViewController` must not be able to hand it `javascript:` or one of this app's own schemes.
    static func isHttpURL(_ text: String) -> Bool {
        guard text.count <= PopopxEcoLimits.maximumURLCharacters,
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased()
        else { return false }
        return (scheme == "http" || scheme == "https") && components.host?.isEmpty == false
    }
}

// MARK: - Public channel URI

/// `popopx://channel/<Relay>/<ChannelID>#key=<Base64_K_master>&pub=<Base64_Ed25519公钥>`
///
/// ### Why the fragment is the whole design
/// Everything after `#` is never sent to a relay: it is the only reason a channel key can be handed out in a public post without
/// becoming public. `connectionURI` is the string that may leave this device — it is what the existing link handling receives — and
/// it is derived by dropping `fragment` *and* re-serialising, not by trimming characters off the end, so a URI that carries the key
/// in the query (a server bug, or a hand-edited link) cannot reach the network layer with it.
///
/// ### Why it cannot be confused with `PopopxChannelAccessPayload`
/// That payload (`PopopxBadgeCreditsModels.swift:969`) is `popopx://channel?p=…&t=…&e=…&s=…`: host `channel`, an empty path, a query.
/// This one requires a two-segment path and a fragment carrying both `key` and `pub`. Neither parser accepts the other's shape, and
/// the assertions in `PopopxEcoModelTests` pin that in both directions.
struct PopopxChannelPublicURI: Hashable, Sendable {
    /// The relay segment, kept for display and for the connection string. Never used to look up a key.
    var relay: String
    /// The channel id. **The keychain lookup key of module 1**, and the `channelId` an envelope's AAD must carry.
    var channelId: String
    /// 32 bytes, from `key=`.
    var masterKeyBase64URL: String
    /// Ed25519 public key, 32 bytes, from `pub=`. The trust root every later envelope signature is checked against.
    var issuerPublicKeyBase64URL: String

    private static let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))

    static func parse(_ text: String) -> PopopxChannelPublicURI? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= PopopxEcoLimits.maximumURLCharacters,
              let components = URLComponents(string: trimmed),
              components.scheme == "popopx",
              components.host == "channel",
              let fragment = components.fragment
        else { return nil }

        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 2 else { return nil }
        let relay = String(segments[0])
        let channelId = String(segments[1])
        guard isOpaqueSegment(relay), isOpaqueSegment(channelId) else { return nil }

        // The fragment is parsed with URLComponents too rather than by hand, for the same reason PopopxLocation.swift:27 gives:
        // this string is input someone else produced. Only these two keys are recognised, and a duplicated key is not "last wins".
        guard let fragmentComponents = URLComponents(string: "?" + fragment),
              let items = fragmentComponents.queryItems
        else { return nil }
        var values: [String: String] = [:]
        for item in items {
            guard let value = item.value, item.name == "key" || item.name == "pub" else { return nil }
            guard values[item.name] == nil else { return nil }
            values[item.name] = value
        }
        guard let key = values["key"], let pub = values["pub"] else { return nil }
        guard Data(popopxBase64URL: key)?.count == 32, Data(popopxBase64URL: pub)?.count == 32 else { return nil }

        return PopopxChannelPublicURI(
            relay: relay,
            channelId: channelId,
            masterKeyBase64URL: key,
            issuerPublicKeyBase64URL: pub
        )
    }

    /// The fragment-free form, and the only form of this URI that may be passed to a connection call.
    ///
    /// Rebuilt from the components instead of `absoluteString.dropLast(fragment.count + 1)`: a percent-encoding difference between
    /// the two would mean the string that leaves the device is not the string this function was read to produce.
    var connectionURI: String {
        var components = URLComponents()
        components.scheme = "popopx"
        components.host = "channel"
        components.path = "/\(relay)/\(channelId)"
        return components.string ?? "popopx://channel/\(relay)/\(channelId)"
    }

    /// Opaque segments only: a `..`, a space, a `%2F` or a colon would otherwise turn a path segment into either a second meaning or
    /// a keychain account name with a slash in it (which `PopopxCommerceKeychain` uses as an account, and a slash there is a real
    /// ambiguity with the dotted account scheme).
    private static func isOpaqueSegment(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 128, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        return text.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }
}

// MARK: - Keychain

/// The keychain of this module: service `popopx.eco`, account names mirroring the data shape,
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
///
/// Deliberately its own helper rather than another `PopopxCommerceKeychainSlot` case (PopopxBadgeCreditsModels.swift:1339): that
/// type's accessibility is `…AfterFirstUnlockThisDeviceOnly` and its lookup query omits the accessibility attribute, so an item
/// written by it and an item written here are not interchangeable. Sharing the slots would mean one of the two policies silently
/// applies to data it was never chosen for — and changing an existing item's accessibility is a delete-then-add, not an update.
enum PopopxEcoKeychain {
    static let service = "popopx.eco"

    /// `kSecAttrAccessGroup` is inherited from the commerce family's value so this device's App Group members see the same items.
    /// Empty when the build has no entitlement, exactly like `PopopxCommerceKeychain.accessGroup`.
    private static var accessGroup: String? { PopopxCommerceKeychain.accessGroup }

    /// A pairwise session secret, keyed by the local contact id of the service account.
    static func sessionAccount(contactId: Int64) -> String { "session.\(contactId)" }
    /// The channel's Ed25519 trust root, keyed by channel id.
    static func channelAccount(_ channelId: String) -> String { "channel.\(channelId).pub" }
    /// One epoch key. The epoch number is in the account name so an old epoch can be revoked without touching the current one.
    static func epochAccount(channelId: String, epoch: Int) -> String { "channel.\(channelId).epoch.\(epoch)" }
    /// Which epoch this channel is on, kept apart from the keys so a launch can find the active key without enumerating the item list.
    static func currentEpochAccount(channelId: String) -> String { "channel.\(channelId).epoch.current" }

    static func read(_ account: String) -> Data? {
        var query = lookupQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// Write, or replace. Returns false when the item could not be stored, which the caller must surface: a session handshake that
    /// failed to save is an H5 launcher that will later say "this service is not linked" with no way to say why.
    ///
    /// The two-branch shape is copied from `PopopxCommerceKeychain.write` (PopopxBadgeCreditsModels.swift:1397) and for the reasons
    /// recorded there: `SecItemUpdate` cannot change the accessibility of an existing item, so the attribute hangs only on the add
    /// branch, and an update that also had to carry the data would be a second dictionary to keep in step.
    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        if SecItemUpdate(lookupQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            return true
        }
        var add = lookupQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(_ account: String) -> Bool {
        let status = SecItemDelete(lookupQuery(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func contains(_ account: String) -> Bool {
        read(account) != nil
    }

    /// The account+service pair only — the same shape `PopopxCommerceKeychain.lookupQuery` (PopopxBadgeCreditsModels.swift:1434)
    /// uses, and for the same reason: including accessibility here would make an item written by an earlier build with a different
    /// attribute un-findable, which reads as "the secret is gone".
    ///
    /// The access group is attached on a real device only: on the simulator a `SecItemAdd` carrying a group fails outright, so this
    /// is the identical compile-time gate, not a style choice.
    private static func lookupQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        #if os(iOS) && !targetEnvironment(simulator)
        query[kSecAttrAccessGroup as String] = accessGroup
        #endif
        return query
    }
}

// MARK: - Hex

/// Lower-case hex for the session secret and the signature the H5 launcher computes.
enum PopopxEcoHex {
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes at most `maximumByteCount` bytes of hex, rejecting odd length, non-hex characters and anything over the cap.
    ///
    /// Rejected rather than truncated: `secretHex` is the shared secret, and a decoder that silently took the first 32 bytes of a
    /// longer string would produce a key that both sides believe they hold.
    static func decode(_ text: String, maximumByteCount: Int) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumByteCount * 2,
              trimmed.count.isMultiple(of: 2),
              trimmed.allSatisfy(\.isHexDigit)
        else { return nil }
        var data = Data(capacity: trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

// MARK: - Copy

/// All user-visible sentences of the service-account module, declared once for the four files that need them (§4: the atomic
/// control library ships no copy, the page supplies its own).
///
/// The source is the English sentence and that sentence is the Key (`en.lproj` writes none by convention); the 16 translation
/// catalogs each write their own wording. The naming rule of §4 is applied here: a spend of points is always
/// "POPOPX 算力点 / POPOPX Compute Credits", and a relay is never called anything that reads as a VPN.
enum PopopxEcoCopy {
    static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX service account")
    }

    // Menu bar
    static let menuBarLabel = key("Service menu")
    static let menuBarCollapse = key("Hide the service menu")
    static let menuBarOpenHaptics = key("Open the service menu")
    static let menuScanPrompt = key("Scan a code with the camera to continue.")
    static let menuLocationPrompt = key("POPOPX needs location permission to send your position.")
    static let menuComposerPrompt = key("Tap send to deliver this text.")
    static let menuUnavailable = key("This menu item is not available in an offline chat yet.")

    // Cards
    static let cardSpokenPrefix = key("Service card")
    static let cardExpired = key("Expired")
    static let cardClosed = key("Closed")
    static let cardHandled = key("Handled")
    static let cardWaiting = key("Waiting for a reply")
    static let cardSent = key("Sent")
    static let cardPaid = key("Paid")
    static let cardFailed = key("This action could not be completed.")
    static let cardBalanceShort = key("Not enough POPOPX Compute Credits.")
    static let cardOpenStore = key("Open the credit store")
    static let cardConfirmTitle = key("Confirm this action")
    static let cardConfirmSend = key("Confirm")
    static let cardConfirmCancel = key("Cancel")
    static let cardUnverifiedIssuer = key("Sender not independently verified")
    static let cardProgressFormat = key("%1$@ %2$d%%")

    // Credits
    static let creditsPaidNote = key("Service payment")
    static let creditsPaidFormat = key("Paid %1$d POPOPX Compute Credits")

    // Channel keys
    static let keyPageTitle = key("Channel keys")
    static let keyActiveEpoch = key("Active epoch")
    static let keyNoChannel = key("This device holds no channel key yet.")
    static let keyRotate = key("Rotate key now")
    static let keyRotating = key("Rotating")
    static let keyRotateDone = key("A new epoch key was issued.")
    static let keyRotateFailed = key("The key could not be issued on this device.")
    static let keyHistory = key("Epoch history")
    static let keyRevoke = key("Revoke")
    static let keyRevokeTitle = key("Revoke this epoch key?")
    static let keyRevokeBody = key("Messages sealed with this key stop opening on this device. The channel keeps working with its newer keys.")
    static let keyRevoked = key("Revoked")
    static let keyActive = key("Active")
    static let keyTrustRoot = key("Channel identity key")
    static let keyTrustUnpinned = key("No independently held identity key for this channel.")
    static let keyVerified = key("Verified")
    static let keyNotVerified = key("Not verified")
    static let keyImportURI = key("Add a channel key")
    static let keyImportPrompt = key("Paste the channel address, including the part after #.")
    static let keyImportButton = key("Add")
    static let keyImportFailed = key("That is not a channel address this build can read.")
    static let keyImportStored = key("Channel key stored on this device.")
    static let keyNoticeFormat = key("Channel key updated to epoch %d.")
    static let keyNoticeRevokedFormat = key("Channel key updated to epoch %d; earlier keys revoked.")
    static let keyNoticeRejected = key("A channel key update was rejected by this device.")
    static let keyNextEpoch = key("Next key offered")
    static let keySchedule = key("Rotation")
    static let keyScheduleManual = key("Manual only")
    static let keyScheduleAuto = key("Automatic")
    static let keyScheduleExpiring = key("Expires soon")
    static let keyScheduleExpired = key("Expired")
    static let keyScheduleAtRisk = key("At risk")
    static let keyThresholdFormat = key("Warn %d days before a key expires")
    static let keyExpiryFormat = key("Expires %@")
    static let keyNeverExpires = key("No expiry")

    // Deep links
    static let deepServiceTitle = key("Open this service account?")
    static let deepSSOTitle = key("Approve a sign-in request?")
    static let deepLinkOpen = key("Open")
    static let deepLinkCancel = key("Cancel")
    static let deepLinkInvalid = key("This link is not valid.")
    static let deepLinkNeedsContact = key("Follow this service account first, then open the link again.")
    static let deepLinkChannelTitle = key("Join this encrypted channel?")
    static let deepLinkChannelBody = key("The channel key stays on this device and is never sent to a relay.")

    // Common
    static let ok = key("OK")
    static let done = key("Done")
}
