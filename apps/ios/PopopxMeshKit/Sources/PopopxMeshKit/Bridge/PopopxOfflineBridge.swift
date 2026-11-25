//
//  PopopxOfflineBridge.swift
//  PopopxMeshKit  —  module 2
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Everything the mesh needs from the chat core while there is no network at all. The core speaks
//  C through a bridging header this package cannot see, so the dependency points the other way:
//  the package owns the rules (which link may reach the FFI at all, and where the resulting id is
//  recorded) and the app target owns the call. Nothing here pretends to link `libpopopx.a`.
//

import Foundation

/// What `/_connect <userId> incognito=…` handed back: a link to speak over the mesh plus the
/// pending connection that link belongs to.
public struct PopopxOfflineInvite: Hashable, Sendable {
    public let inviteLink: String
    public let tempConnId: Int64

    public init(inviteLink: String, tempConnId: Int64) {
        self.inviteLink = inviteLink
        self.tempConnId = tempConnId
    }
}

/// What consuming a peer's link handed back. Both cases created a pending connection; which one
/// depends on whether we answered an invitation or a contact address, and the app shows them
/// differently.
public struct PopopxOfflineAcceptance: Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// `sentConfirmation` — we took the peer's invitation, so our side now waits for them.
        case confirmation
        /// `sentInvitation` — we approached the peer's contact address with an invitation.
        case invitation
    }

    public let tempConnId: Int64
    public let kind: Kind

    public init(tempConnId: Int64, kind: PopopxOfflineAcceptance.Kind) {
        self.tempConnId = tempConnId
        self.kind = kind
    }
}

/// The FFI door, implemented in phase 2 inside the app target.
///
/// Each method is a thin, non-blocking translation of one local chat-core command, and the adapter
/// must use the functions that already exist rather than a new path:
///
/// - `createOfflineInvite(incognito:)` sends `/_connect <userId> incognito=on|off` — the string
///   built by `apiAddContact(incognito:)` (`Shared/Model/POPOPXAPI.swift:1036`,
///   `Shared/Model/AppAPITypes.swift:363`) — through `sendPOPOPXCmd(.apiAddContact…)`
///   (`POPOPXChat/API.swift:121`) or `sendPOPOPXCmdStr(_:retryNum:)` (`API.swift:130`), and reads
///   the `invitation(_, connLink, connection)` reply. `tempConnId` is
///   `PendingContactConnection.pccConnId` (`POPOPXChat/ChatTypes.swift:2911`), `inviteLink` is
///   `CreatedConnLink.connFullLink` (`POPOPXChat/APITypes.swift:176`).
/// - `acceptOfflineInvite(_:incognito:)` sends
///   `/_connect <userId> incognito=… <connFullLink> <connShortLink?>` — the string built by
///   `apiConnect(incognito:connLink:)` (`POPOPXAPI.swift:1074`, `AppAPITypes.swift:376`) — and maps
///   `sentConfirmation` to `.confirmation`, `sentInvitation` to `.invitation`.
///
/// Both go over `chat_send_cmd_retry` (`POPOPXChat/POPOPX.h:24`) and, if a reply must be awaited,
/// `chat_recv_msg_wait` (`POPOPX.h:25`, `MESSAGE_TIMEOUT` of 15_000_000 µs at `API.swift:140`). The
/// header exports no free function, so the returned C strings belong to `fromCString`
/// (`API.swift:233`) / `dataFromCString` (`API.swift:240`), which `free` them — an adapter that
/// converts with `String(cString:)` alone leaks.
///
/// `/_connect` is a *local* command: it writes to the agent database and, at worst, queues SMP work
/// for later. An implementation that waits for a server round trip here would break the only
/// promise this module makes, which is that pairing works with the radio on and the network off.
public protocol PopopxOfflineChatCore: Sendable {
    func createOfflineInvite(incognito: Bool) async throws -> PopopxOfflineInvite
    func acceptOfflineInvite(_ inviteLink: String, incognito: Bool) async throws -> PopopxOfflineAcceptance
}

public enum PopopxOfflineBridgeError: Error, Hashable, Sendable {
    /// Refused before reaching the FFI — the string is never echoed, only counted.
    case inviteLinkRejected(characterCount: Int)
    case meshPublicKeyRejected(characterCount: Int)
    case coreFailed(reason: String)
    /// The core created a pending connection that could not be bound, so the mesh would keep
    /// talking to a chat object nobody can resolve. The id is in the payload: the caller deletes it.
    case inviteUnbound(tempConnId: Int64, reason: String)
    case acceptanceUnbound(tempConnId: Int64, reason: String)
}

public actor PopopxOfflineBridge {
    /// The scheme the chat core itself emits, e.g. `popopx:/contact#…`.
    public static let schemePrefix = "popopx:/"
    /// The double slash people type after a colon; `popopx:/` is what the core then parses.
    public static let handTypedSchemePrefix = "popopx://"
    /// The shared form `popopxChatLink` produces (`POPOPXChat/APITypes.swift:194`) — its inverse.
    public static let sharePrefix = "https://popopx.chat/"

    /// A link this long is not a link. The bound is generous enough for a full contact invitation
    /// and low enough that a flood cannot grow an FFI command line.
    public static let maxInviteLinkCharacters = 2_048

    /// Quoting and expansion metacharacters: they would break the JSON envelope the command
    /// travels in even where the byte itself is printable.
    public static let forbiddenLinkCharacters: Set<Character> = ["\"", "'", "`", "\\", "$"]

    private let core: any PopopxOfflineChatCore
    private let store: IdentityMappingStore

    public init(core: any PopopxOfflineChatCore, store: IdentityMappingStore = .shared) {
        self.core = core
        self.store = store
    }

    /// The only prefix gate in the package. Accepts `popopx:/…`, the mistyped `popopx://…` and the
    /// share form `https://popopx.chat/…`, and returns them all as `popopx:/…`.
    ///
    /// Everything else is nil, and the refusals are not cosmetic. The link becomes one
    /// space-separated argument of a `/_connect` command line handed to `chat_send_cmd_retry`, so
    /// whitespace would split that argument in two, and the quote, backtick, backslash and dollar
    /// characters would break the JSON envelope the command travels in — a newline does both at
    /// once, which is command injection with somebody else's chat controller. A non-ASCII byte is
    /// refused for the same reason: our own links are percent-encoded ASCII, so anything else
    /// arrived by paste or by attack. Other schemes (`http://`, `simplex:/`, `nostr:`) are refused
    /// because a link we do not mint is not a POPOPX invitation, whatever it claims to be.
    public static func normalizedInviteLink(_ raw: String) -> String? {
        guard isCommandLineSafe(raw) else { return nil }
        for prefix in [Self.sharePrefix, Self.handTypedSchemePrefix, Self.schemePrefix] where raw.hasPrefix(prefix) {
            let remainder = raw.dropFirst(prefix.count)
            // `popopx:/` and `https://popopx.chat/` on their own carry no invitation at all.
            guard !remainder.isEmpty else { return nil }
            return prefix == schemePrefix ? raw : schemePrefix + remainder
        }
        return nil
    }

    // MARK: - Outbound: we offer a link

    /// Generates our offline invite link and binds it to the peer's mesh key in the same step —
    /// the temporary `connId` a pairing produces has nowhere else to land, and an unbound one is a
    /// pending connection the user never sees.
    public func generateOfflineInviteLink(meshPublicKeyHex candidate: String, incognito: Bool = false)
        async throws(PopopxOfflineBridgeError) -> PopopxOfflineInvite
    {
        // Validated first: a malformed key must not be able to open a connection on the way to
        // failing, leaving a pending contact with no peer.
        let meshPublicKeyHex = try Self.validated(meshPublicKeyHex: candidate)
        let invite: PopopxOfflineInvite
        do {
            invite = try await core.createOfflineInvite(incognito: incognito)
        } catch {
            PopopxMeshLog.offline.error("❌ offline invite failed: \(String(describing: error), privacy: .public)")
            throw .coreFailed(reason: String(describing: error))
        }
        // Our own output goes through the same gate as a peer's, because the link comes back over
        // the mesh into this function on the peer's device.
        guard let canonical = Self.normalizedInviteLink(invite.inviteLink) else {
            PopopxMeshLog.offline.error(
                "🚫 generated link failed prefix rules (\(invite.inviteLink.count, privacy: .public) characters) — nothing bound"
            )
            throw .inviteUnbound(tempConnId: invite.tempConnId, reason: "generated link failed prefix validation")
        }
        do {
            try await store.bind(tempConnId: invite.tempConnId, meshPublicKeyHex: meshPublicKeyHex, nickname: nil)
        } catch {
            // The package cannot undo `/_connect` — deleting a pending connection is the core's
            // job and is not on this door, so the id is reported instead of quietly dropped.
            PopopxMeshLog.offline.error(
                "⚠️ invite bound nowhere: pending :\(invite.tempConnId, privacy: .public) needs cleanup — \(String(describing: error), privacy: .public)"
            )
            throw .inviteUnbound(tempConnId: invite.tempConnId, reason: String(describing: error))
        }
        PopopxMeshLog.offline.notice(
            "📨 offline invite minted for \(meshPublicKeyHex.prefix(8), privacy: .public) on pending :\(invite.tempConnId, privacy: .public)"
        )
        return PopopxOfflineInvite(inviteLink: canonical, tempConnId: invite.tempConnId)
    }

    // MARK: - Inbound: we accept a link

    public func acceptOfflineInviteLink(_ inviteLink: String, meshPublicKeyHex candidate: String? = nil, incognito: Bool = false)
        async throws(PopopxOfflineBridgeError) -> PopopxOfflineAcceptance
    {
        guard let canonical = Self.normalizedInviteLink(inviteLink) else {
            PopopxMeshLog.offline.error(
                "🚫 invite link rejected before the FFI (\(inviteLink.count, privacy: .public) characters)"
            )
            throw .inviteLinkRejected(characterCount: inviteLink.count)
        }
        let meshPublicKeyHex: String?
        if let candidate {
            meshPublicKeyHex = try Self.validated(meshPublicKeyHex: candidate)
        } else {
            meshPublicKeyHex = nil
        }
        let acceptance: PopopxOfflineAcceptance
        do {
            acceptance = try await core.acceptOfflineInvite(canonical, incognito: incognito)
        } catch {
            PopopxMeshLog.offline.error("❌ offline accept failed: \(String(describing: error), privacy: .public)")
            throw .coreFailed(reason: String(describing: error))
        }
        if let meshPublicKeyHex {
            do {
                try await store.bind(tempConnId: acceptance.tempConnId, meshPublicKeyHex: meshPublicKeyHex, nickname: nil)
            } catch {
                PopopxMeshLog.offline.error(
                    "⚠️ acceptance bound nowhere: pending :\(acceptance.tempConnId, privacy: .public) needs cleanup — \(String(describing: error), privacy: .public)"
                )
                throw .acceptanceUnbound(tempConnId: acceptance.tempConnId, reason: String(describing: error))
            }
            PopopxMeshLog.offline.notice(
                "🤝 offline \(acceptance.kind.rawValue, privacy: .public) on pending :\(acceptance.tempConnId, privacy: .public) tied to \(meshPublicKeyHex.prefix(8), privacy: .public)"
            )
        } else {
            PopopxMeshLog.offline.notice(
                "🤝 offline \(acceptance.kind.rawValue, privacy: .public) on pending :\(acceptance.tempConnId, privacy: .public) (no mesh key supplied)"
            )
        }
        return acceptance
    }

    private static func validated(meshPublicKeyHex candidate: String) throws(PopopxOfflineBridgeError) -> String {
        guard let canonical = IdentityMappingStore.canonicalMeshPublicKeyHex(candidate) else {
            throw .meshPublicKeyRejected(characterCount: candidate.count)
        }
        return canonical
    }

    private static func isCommandLineSafe(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= maxInviteLinkCharacters else { return false }
        if candidate.contains(where: { forbiddenLinkCharacters.contains($0) }) { return false }
        // 0x21…0x7E only: printable ASCII, so no space, no control byte, no DEL, no UTF-8.
        return candidate.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }
}
