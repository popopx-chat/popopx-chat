//
//  PopopxInviteShare.swift
//  PopopxMeshKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  The share formatter: the one string a screen prints as text, encodes as a QR and hands to the
//  share sheet. It lives here, beside the codec, so the rule "a share never names its SMP server"
//  is pinned by this package's tests instead of only by the screens that call it.
//

import Foundation

/// What an invitation is shared as: the published `/i/v1/` code, with the plain address reachable
/// behind a fold.
///
/// Sealing is decided by the address that is actually being shared, and it is not optional: every
/// form a core hands out carries its SMP host in plaintext - the full link names it in the host or
/// in `?smp=`, and the "short" form (`popopx:/…?h=<host>&p=<port>&c=<hash>`, or the `https://<host>/…`
/// spelling) names it in the query or authority. So this type does not consult schemes or lengths to
/// decide whether a host is exposed. Only an address the codec refuses (wrong scheme, over the size
/// ceiling) falls back to its plain form, because a share that cannot be opened is worse than one
/// that names its server.
public struct PopopxInviteShare: Hashable, Sendable {
    /// The sealed link, or nil when the codec refuses the address (scheme, size).
    public var opaque: String?
    /// The plain form of what this share carries. Shown only when sealing failed, so an unsealable
    /// link is shared rather than lost.
    public var fallback: String
    /// The plain address, host included - the thing the fold reveals.
    public var original: String

    public var display: String { opaque ?? fallback }
    public var sealed: Bool { opaque != nil }

    /// - Parameters:
    ///   - fullLink: the core-minted full address (`popopx:/…` or `https://…`).
    ///   - shortLink: the core-minted short form, when one exists.
    ///   - short: whether the user selected the short form. It selects which address is sealed; it
    ///     can no longer select a form that is not sealed.
    ///   - seal: the envelope mint. Injectable so a test can pin the nonce; the app passes its
    ///     memoising cache, so one invitation keeps one code across text, QR and share sheet.
    public static func make(
        fullLink: String,
        shortLink: String? = nil,
        short: Bool,
        seal: (String) -> String? = { PopopxOpaqueInviteCodec.link(forURI: $0) }
    ) -> PopopxInviteShare {
        let full = tappable(fullLink)
        let chosen = short ? shortLink.map { tappable($0) } ?? full : full
        return PopopxInviteShare(opaque: seal(chosen), fallback: chosen, original: chosen)
    }

    /// The form a recipient's phone can open: the scheme the core mints for internal links, rewritten
    /// to this app's published domain. Exactly the app's `popopxChatLink` rule.
    public static func tappable(_ uri: String) -> String {
        uri.hasPrefix("popopx:/") ? uri.replacingOccurrences(of: "popopx:/", with: "https://popopx.chat/") : uri
    }

    /// The one form to show, print and share for a stored connection address: the sealed code when
    /// the address can be sealed, unchanged when it already is one of those codes (a share that is
    /// handed back to a formatter must not be sealed again), and the plain address when the codec
    /// refuses it. Not for migration file links or relay addresses, which are not connection
    /// addresses and are consumed by other parsers in their plain form.
    public static func sharedLink(
        forURI uri: String,
        seal: (String) -> String? = { PopopxOpaqueInviteCodec.link(forURI: $0) }
    ) -> String {
        let plain = tappable(uri)
        if PopopxOpaqueInviteCodec.looksLikeOpaqueLink(plain) { return plain }
        return seal(plain) ?? plain
    }
}