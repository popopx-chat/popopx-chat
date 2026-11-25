//
//  RoutingPolicy.swift
//  PopopxTorKit
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Mirrors `SMPProxyFallback` in the dependency (`Popopx/Messaging/Client.hs:379`).
///
/// Duplicated rather than imported because the core types live in the iOS target's
/// `POPOPXChat` module, which this package must not depend on: importing it would drag UIKit back
/// in. The mapping onto the app's `NetCfg` fields is asserted by a test naming both raw values.
public enum SmpProxyFallbackIntent: String, Sendable, CaseIterable {
    /// Connect directly when the chosen proxy or the destination relay does not support the proxy
    /// protocol. Never produced by this package.
    case allow
    /// Connect directly only when the IP address is already protected (SOCKS proxy or `.onion`).
    case allowProtected
    /// Prohibit direct connection to the destination relay — the kill switch.
    case prohibit
}

/// Mirrors `HostMode` in the dependency (`Popopx/Messaging/Client.hs:277`).
public enum HostModeIntent: String, Sendable, CaseIterable {
    /// Prefer onion hosts when connecting via a SOCKS proxy.
    case onionViaSocks
    /// Prefer onion hosts.
    case onion
    /// Prefer public hosts.
    case `public`
}

/// Mirrors `SocksMode` in the app target (`APITypes.swift:327`), whose wire values are `always`
/// and `onion`.
///
/// The package only ever emits ``always``. `onion` means "send only `.onion` destinations through the
/// proxy", so with a proxy configured and this mode set, a clearnet relay bypasses Tor entirely —
/// which would make ``TorRoutingPolicy/directConnectionsPermitted`` a statement the core does not
/// honour.
public enum SocksModeIntent: String, Sendable, CaseIterable {
    case always
    case onion
}

/// The values the host app must write into `NetCfg` for traffic to reach the embedded daemon.
///
/// Two rules here are load-bearing and easy to break from the outside:
///
/// 1. `proxyString` carries **no URL scheme**. The dependency parses the proxy with a
///    `StrEncoding` instance (`Transport/Client.hs:253-258`), not a URL, and a `socks5h://` prefix
///    would be consumed as the username. Remote DNS does not need the `h`: on the proxied branch the
///    host is mapped by `hostAddr` (`Transport/Client.hs:173`, `:191-195`) so a domain — and an
///    `.onion` — travels to the daemon as a `SocksAddrDomainName` and is resolved at the exit side.
///    A hostname is resolved locally instead (`:198-206`), which is the leak this whole rule is about.
/// 2. Isolate authentication is encoded as an **empty prefix** (`Transport/Client.hs:280`) and is the
///    core's own default (`Transport/Client.hs:234`), so it is pinned here with no setter: it derives
///    a per-session username from the entity rather than storing a secret
///    (`Client.hs:461-476`). It pairs with `hostMode = .onionViaSocks`, which
///    `chooseTransportHost` (`Client.hs:538-541`) resolves to the onion host when a proxy is present
///    and the public host when it is not — the other direction would put a clearnet address on the
///    wire next to a proxy that was supposed to hide it.
public struct TorRoutingPolicy: Sendable, Equatable {
    public let proxyString: String?
    public let smpProxyFallback: SmpProxyFallbackIntent
    public let hostMode: HostModeIntent
    /// Which connections the proxy applies to. Always ``SocksModeIntent/always`` from this package:
    /// see ``SocksModeIntent`` for the bypass that `onion` would open.
    public let socksMode: SocksModeIntent
    /// `false` means onion addresses are preferred when present but a public address is still
    /// usable. Forcing onion is deliberately off by default: the core has no fallback for it, so a
    /// server whose address carries no onion fails the connection with `PCEIncompatibleHost`
    /// (`Popopx.Messaging.Client.chooseTransportHost`) rather than degrading to the public host.
    public let requiredHostMode: Bool
    /// True when a direct connection would be permitted by the core. Only ever true when the kill
    /// switch is off; the UI reads this rather than inferring it from a spinner.
    public let directConnectionsPermitted: Bool

    public init(
        proxyString: String?,
        smpProxyFallback: SmpProxyFallbackIntent,
        hostMode: HostModeIntent,
        socksMode: SocksModeIntent,
        requiredHostMode: Bool,
        directConnectionsPermitted: Bool
    ) {
        self.proxyString = proxyString
        self.smpProxyFallback = smpProxyFallback
        self.hostMode = hostMode
        self.socksMode = socksMode
        self.requiredHostMode = requiredHostMode
        self.directConnectionsPermitted = directConnectionsPermitted
    }

    /// The state before any daemon is known: no proxy, and direct traffic allowed only because the
    /// user has not asked for Tor.
    public static let disabled = TorRoutingPolicy(
        proxyString: nil,
        smpProxyFallback: .allowProtected,
        hostMode: .public,
        socksMode: .always,
        requiredHostMode: false,
        directConnectionsPermitted: true
    )

    /// The configuration to hand the core when Tor is required but there is no working proxy to
    /// describe. `proxyString` is nil because there is genuinely nothing to point at, and the relay
    /// fallback stays prohibited so the only consequence is that connections fail.
    public static let prohibited = TorRoutingPolicy(
        proxyString: nil,
        smpProxyFallback: .prohibit,
        hostMode: .onionViaSocks,
        socksMode: .always,
        requiredHostMode: false,
        directConnectionsPermitted: false
    )

    /// Builds the policy for a daemon listening on `port`, given the kill-switch decision.
    ///
    /// Throws rather than returning a policy with a nil proxy: with strict mode on, losing the proxy
    /// string is precisely the fail-open this feature exists to prevent, so the caller has to be told
    /// and hand the core ``TorRoutingPolicy/prohibited`` instead.
    public static func makePolicy(
        socksHost: String,
        socksPort: UInt16,
        strict: Bool,
        circuitReady: Bool
    ) throws -> TorRoutingPolicy {
        guard let address = IPAddressLiteral(socksHost) else {
            throw RoutingPolicyError.hostIsNotAnIPLiteral(socksHost)
        }
        guard socksPort > 0 else {
            throw RoutingPolicyError.portOutOfRange(socksHost)
        }
        let proxy = "\(address.encodedHost):\(socksPort)"
        return strict
            ? TorRoutingPolicy(
                proxyString: proxy,
                // Held at `prohibit` whether or not the circuit is up. While Tor is still
                // bootstrapping the SOCKS port answers and connections fail; that failure is the
                // intended behaviour, and relaxing it to `allowProtected` would silently route
                // the gap to the clearnet.
                smpProxyFallback: .prohibit,
                hostMode: .onionViaSocks,
                socksMode: .always,
                requiredHostMode: false,
                directConnectionsPermitted: false
            )
            : TorRoutingPolicy(
                proxyString: proxy,
                smpProxyFallback: .allowProtected,
                hostMode: .onionViaSocks,
                socksMode: .always,
                requiredHostMode: false,
                // `circuitReady` only ever relaxes this when the user did not ask for a
                // guarantee, so it cannot loosen a strict policy.
                directConnectionsPermitted: !circuitReady
            )
    }
}

public enum RoutingPolicyError: Error, Equatable, CustomStringConvertible {
    case hostIsNotAnIPLiteral(String)
    case portOutOfRange(String)

    public var description: String {
        switch self {
        case let .hostIsNotAnIPLiteral(host):
            return "the chat core only accepts a numeric address as a SOCKS proxy host, and \(host) "
                + "is not one; a hostname here is dropped in silence and the app connects directly"
        case .portOutOfRange:
            return "the SOCKS port was never bound"
        }
    }
}
