# PopopxTorKit

Embedded Tor for the POPOPX macOS client: a `tor` child process, a ControlPort client, the
kill-switch state machine that decides whether the chat core may connect at all, and the SwiftUI
surface that reports the decision.

macOS only. The package declares `.macOS(.v13)` and lives at `apps/macos/`, so the iOS build cannot
see it: `build.yml`'s iOS paths filter never matches this directory, `scripts/ci/ios-sim` does not
compile it, and `check-previews.py` does not sweep it. Nothing here imports UIKit, and nothing here
is imported by `apps/ios`.

## Verification

Both gates run on this machine without a `tor` binary and without a macOS Xcode target:

```sh
cd apps/macos/PopopxTorKit
swift build      # both library products
swift test       # PopopxTorKitTests only; PopopxTorUI is type-checked by `swift build`
```

Measured 2026-11-23 with Apple Swift 6.4.2 on macOS 27 arm64: `swift build` → `Build complete!`,
`swift test` → `Executed 85 tests, with 0 failures`, 0 compiler warnings. `PopopxTorKit.swiftmodule`
and `PopopxTorUI.swiftmodule` are both produced, which is what proves the UI target compiled —
`swift test` on its own never builds it.

The brief's own gates, re-measured the same day. Each row is the command and its output, so a later
reader can disagree with the claim rather than take it:

| Gate | Measured | Recipe |
| --- | --- | --- |
| Licence header on every Swift file | 20 files, 0 violations | `for f in $(find . -name '*.swift' -not -path './.build/*'); do grep -q 'SPDX-License-Identifier: AGPL-3.0-only' "$f" \|\| echo "MISSING $f"; done` — 14 in `Sources/PopopxTorKit`, 2 in `Sources/PopopxTorUI`, 3 in `Tests`, plus `Package.swift` |
| No CJK characters in the package or the DMG script | 0 | `rg '\p{Han}\|\p{Hiragana}\|\p{Katakana}\|\p{Hangul}' apps/macos scripts/macos -g '!.build'`. The control that proves the pattern can fire: the same expression against `apps/ios/zh-Hans.lproj/Localizable.strings` returns 4720 |
| No `SimpleX` in interface text | 0 displayed | `grep -rn SimpleX Sources/PopopxTorUI` is empty. Case-insensitively the package has 2 hits, `README.md` and `RoutingPolicy.swift`, both doc prose naming upstream's relay host `smpN.simplex.im` |
| UI strings owed to the 18 `.lproj` files | 32 | `grep -oh 'localized("[^"]*")' Sources/PopopxTorUI/*.swift \| sort -u \| wc -l` |
| iOS untouched by this package | 0 tracked changes under `apps/ios` | `git status --porcelain -- apps/ios`, and `git ls-files apps/macos` is empty until the files are committed |

The tests are deliberately daemon-free. Everything that would otherwise need a running Tor is
injected: `ScriptedTransport` replays byte-for-byte captures of real control-port replies, and the
process tests run a `#!/bin/sh` stub that writes to stdout, exits with a chosen status, or waits for
`SIGTERM`.

## Files

| File | Responsibility |
| --- | --- |
| `IPAddressLiteral.swift` | Accepts only a numeric IPv4/IPv6 host. A hostname is a fail-open upstream, so it is rejected here with a reason instead of dropped in silence. |
| `LoopbackPortAllocator.swift` | Binds and holds two distinct high loopback ports, then hands them to the daemon. A reservation, not a scan. |
| `Torrc.swift` | The generated configuration and the `TorError` vocabulary. `0700` directory, `0600` file, cookie authentication, one `SocksPort` line. |
| `TorBinaryLocator.swift` | Finds `Contents/Helpers/tor` in the bundle, then an explicit override, then Homebrew (development only). |
| `TorProcess.swift` | The child process: `-f <torrc>`, a two-key environment, drained pipes, `SIGTERM`-then-`SIGKILL` stop, and `TorLifecycle`'s shutdown hooks. |
| `ControlTransport.swift` | One blocking loopback socket, refusing any host that is not a loopback literal before `connect()`. `ScriptedTransport` is the test double. |
| `ControlProtocol.swift` | Byte-level framing of `250-` / `250+` / `250 ` / `650` replies, and the escaping of quoted arguments. |
| `ControlAuthentication.swift` | `PROTOCOLINFO` parsing and the credential presentation. |
| `TorController.swift` | One reader for one connection: commands out, replies to waiters in write order, `650` events to the callback. |
| `TrafficGate.swift` | `TorPhase`, bootstrap parsing, and the total function from `(phase, strict)` to "may this connect?". |
| `RoutingPolicy.swift` | The values the host app writes into `NetCfg`. |
| `TorExitNode.swift` | The current general circuit's exit hop. |
| `BridgeLine.swift` | Validation of the bridge lines a user pastes in. |
| `TorManager.swift` | `@MainActor` owner of one daemon; publishes `phase`, `gate`, `policy`, `exitNode`. |
| `PopopxTorUI/TorStatusCapsule.swift` | The status capsule and the blocking banner. |
| `PopopxTorUI/TorControlPanel.swift` | The popover: bootstrap progress, strict toggle, exit relay, bridges, and the boundary text. |

## What the host app must do with a published policy

`TorManager` never calls into the chat core — that would import UIKit back in. It publishes a
`TorRoutingPolicy` and the macOS app writes it onto `NetCfg`. Field by field, with the app-side
declarations this was measured against on 2026-11-23:

| `TorRoutingPolicy` | App target | Wire value | Where it lands |
| --- | --- | --- | --- |
| `proxyString` | `NetworkProxy.host` + `.port`, then `toProxyString()` (`APITypes.swift:446`, `:472`) | `127.0.0.1:49711` | `NetCfg.socksProxy` (`APITypes.swift:262`) |
| — (pinned) | `NetworkProxy.auth = .isolate` (`APITypes.swift:498`) | empty credential prefix | same field |
| `smpProxyFallback` | `NetCfg.smpProxyFallback` (`APITypes.swift:352-355`) | `allow` / `allowProtected` / `prohibit` | `setNetworkConfig` |
| `hostMode` | `NetCfg.hostMode` (`APITypes.swift:321-325`) | `onionViaSocks` / `onion` / `public` | `setNetworkConfig` |
| `socksMode` | `NetCfg.socksMode` (`APITypes.swift:327-330`) | `always` only | `setNetworkConfig` |
| `requiredHostMode` | `NetCfg.requiredHostMode` (default `true`) | `false` from this package | `setNetworkConfig` |
| `directConnectionsPermitted` | UI only | — | the banner text |

`setNetworkConfig(_:)` is `apps/ios/Shared/Model/POPOPXAPI.swift:923`; the app writes the stored
configuration through `setNetCfg(_:networkProxy:)` (`AppGroup.swift:41`, `:361`, `:410`) and re-applies
it with `setNetworkConfig(getNetCfg())` (`POPOPXAPI.swift:2430`).

Three rules in that table are not negotiable, and the types enforce them:

1. **No URL scheme.** `proxyString` is `host:port`. The dependency decodes it with a `StrEncoding`
   instance (`Transport/Client.hs:253-258`), so a `socks5h://` prefix is consumed as the username and
   the proxy silently disappears. Remote DNS does not need the `h`: with a proxy set, a domain is
   handed to it as `SocksAddrDomainName` (`Transport/Client.hs:172-186`) and is never resolved locally.
2. **Numeric host only.** `NetworkProxy.valid` (`APITypes.swift:457-465`) accepts only `.ipv4` and
   `.ipv6`; an invalid proxy is dropped by `toProxyString()` returning nil, the setting is still saved,
   and the app connects directly. That is a fail-open, so `IPAddressLiteral` rejects the same inputs
   earlier and with a reason.
3. **Isolate auth, `socksMode` always.** The isolate mode encodes as an empty prefix
   (`Transport/Client.hs:280`) and is the core's own default (`Transport/Client.hs:234`); it derives a
   per-session username from the entity instead of storing a secret (`Client.hs:461-476`). It pairs
   with `hostMode = onionViaSocks`, which `chooseTransportHost` (`Client.hs:538-541`) resolves to the
   onion host when a proxy is present and the public host when it is not. `socksMode = .onion` would
   proxy only `.onion` destinations (`Client.hs:456-459`), so a relay reached by its public host would
   go straight to the clearnet while the UI still said Tor was on — which is why `SocksModeIntent`
   exists but `makePolicy` never returns `.onion`. `defaultNetworkConfig` already carries
   `socksMode = SMAlways` (`Client.hs:430-436`); writing it explicitly keeps that true if the core's
   default ever moves.

## Kill switch

`TrafficGate.evaluate(phase:strict:)` is total: every `TorPhase` maps to a verdict, so a new state
cannot be added without deciding what it means for the network.

- `strict` on — only `.ready` passes. Bootstrap-in-progress, a lost circuit, and a dead daemon all
  block, and the published policy carries `smpProxyFallback = .prohibit` the whole time, including
  the window where the SOCKS port answers but no circuit exists yet. Relaxing that window to
  `allowProtected` is a silent clearnet route.
- `strict` off — nothing blocks; `directConnectionsPermitted` tracks whether a circuit is up, so the
  UI can say what is true without inferring it from a spinner.
- Losing the proxy string is a failure, not a nil: `makePolicy` throws and `TorManager` publishes
  `.prohibited` rather than `.disabled`.

`TorPhase` never moves backwards to a lower bootstrap percent, and `.ready` is not cut by a progress
event — only by `CIRC` confirmation failing or the socket dying.

## Lifecycle

Three exit paths, and the third is the reason `__OwningControllerProcess` is written into every
generated `torrc`:

1. `NSApplication.willTerminateNotification` → `TorLifecycle.fire()`.
2. `SIGTERM` / `SIGINT` / `SIGHUP` → the same handler, which then restores the default disposition
   and re-raises so the exit status is what the OS would have reported.
3. Crash or `kill -9` → no in-process handler runs at all. Tor watches the owning PID and leaves by
   itself.

`fire()` tears the control socket down before the process, because a parked `await` on the controller
has to be resumed with an error rather than outliving the peer it was talking to. It runs the kill
synchronously: the manager is `@MainActor`, a signal source fires on an arbitrary thread, and an actor
hop during `willTerminate` queues behind the termination it exists to complete. That is why
`TorLifecycle.adopt(process:controller:)` holds the raw objects instead of calling back into the
manager.

`terminate(graceInterval:)` sends `SIGTERM`, waits, then `SIGKILL`. The grace period is not politeness
— Tor flushes its cached consensus on `SIGTERM`, and killing it mid-write costs the next launch a full
directory download.

## Known boundaries

These are limits of the design, not bugs to be found later. `TorControlPanel` shows the WebRTC and
`.onion` boundaries in its own UI text, and the bridge boundary in the footnote under its own field.

- **Voice and video calls do not go through Tor.** WebRTC and its STUN/TURN signalling bypass the
  core's SOCKS proxy, so enabling Tor hides relay traffic and not media. Ruled on 2026-11-22:
  `WebRTCClient.swift` is not to be modified, and the boundary is annotated instead.
- **Bridges are parsed, validated and refused.** Every transport `BridgeLine` accepts (obfs4,
  snowflake, meek, ctubid, fte, scrambleSuite) is implemented outside the `tor` binary, and the
  generated `torrc` writes no `ClientTransportPlugin` line because the package has no plugin path to
  write: `scripts/macos/build_macos_dmg.sh` embeds exactly one helper, `Contents/Helpers/tor`.
  `TorManager.apply(bridges:)` therefore fails with `TorError.clientTransportPluginMissing` before it
  tears down a working daemon, instead of launching one that can never finish bootstrapping. Closing
  this needs a decision, not code: bundle a digest-pinned `obfs4proxy` beside `tor` and emit the
  plugin line, or delete the bridge surface.
- **No `.onion` bias.** `requiredHostMode` is always `false`. The preset SMP rows in
  `src/Popopx/Chat/Operators/Presets.hs` are dual-stack - each carries this fork's own
  `smpN.popopx.im` clearnet host beside its onion - so the earlier objection (that forcing onion moved
  this fork's users onto another operator's infrastructure) no longer applies; the option stays off
  because the core has no fallback for it and a server without an onion address fails the connection
  with `PCEIncompatibleHost`. Onion is used when a contact or relay supplies one, never preferred by
  policy.
- **SAFECOOKIE is not implemented.** `TorController`'s connect path throws with a message telling the
  operator to enable `CookieAuthentication` if the daemon offers only SAFECOOKIE. The generated
  `torrc` always sets it, so this only bites a configuration this package did not write.
- **`IsolationMode.username` is unverified — do not ship it.** It emits `Socks5PasswordAuth 1` with no
  `Socks5PasswordAuthAccept` list. The core's default `SocksIsolateByAuth`
  (`popopxmq/src/Popopx/Messaging/Client.hs:461-476`) sends `base64(sha256(userId <> session material))`
  as the username with an empty password, and Tor requires each accepted username to be listed. Those
  two do not obviously agree, and the failure mode is "every connection refused". The shipped default
  is `.destination`. No `tor` binary exists on this machine (`which tor` → not found, 2026-11-23), so
  this has not been run:

  ```sh
  # What Tor itself does with a SOCKS5 username it was never told to accept.
  printf 'DataDirectory /tmp/popopx-torcheck\nSocksPort 127.0.0.1:39199 IsolateDestAddr IsolateDestPort\nSocks5PasswordAuth 1\nSafeLogging 1\n' > /tmp/popopx-torcheck.torrc
  tor -f /tmp/popopx-torcheck.torrc &
  curl -sS --max-time 20 --socks5-hostname "user:pass@127.0.0.1:39199" https://example.com
  ```

  A refusal here means `.username` must additionally write `Socks5PasswordAuthAccept`, and the core's
  derived username is not a constant that can be listed — in which case the mode should be deleted
  rather than fixed. An acceptance means the only change needed is to drop the scary comment.

## Adding this to the macOS target (manual, one time)

No script in this repository edits `POPOPX.xcodeproj/project.pbxproj`, and none is needed:

1. Xcode → File → Add Package Dependencies → Add Local… → `apps/macos/PopopxTorKit`.
2. Add the `PopopxTorKit` and `PopopxTorUI` products to the macOS app target only. The iOS target must
   not link them.
3. Embed a `tor` binary at `POPOPX.app/Contents/Helpers/tor` — `scripts/macos/build_macos_dmg.sh`
   downloads, verifies by digest, installs and signs it at build time. The binary is never committed.
   The same run installs the licence that came out of the verified archive to
   `Contents/Resources/licences/tor/LICENSE`; a Developer ID build stops if the asset has none, so a
   published bundle always carries the notice for the version it carries (`NOTICE` explains the rule).
4. Copy the 32 UI strings into the 18 `.lproj` `Localizable.strings` files. `en` is the key language —
   iOS uses the English literal as the key, so an untranslated locale silently falls back to English
   and the build stays green. Enumerate the keys with:

   ```sh
   grep -rho 'localized("[^"]*")' apps/macos/PopopxTorKit/Sources/PopopxTorUI \
     | sed 's/localized("//; s/")$//' | sort -u
   ```

There is no macOS product target in `POPOPX.xcodeproj` yet. Measured 2026-11-23 with
`xcodebuild -list -project apps/ios/POPOPX.xcodeproj`: the six targets are `POPOPX (iOS)`,
`Tests iOS`, `POPOPX Snapshots`, `POPOPX NSE`, `POPOPX SE` and `POPOPXChat`, and the six schemes are
`POPOPX (iOS)`, `POPOPX NSE`, `POPOPX SE`, `POPOPXChat`, `PopopxMeshKit`, `PopopxMeshUI` — none is a
macOS product. That is why the package is verified with `swift build` / `swift test` rather than
`xcodebuild`, and why `build_macos_dmg.sh` cannot get past its scheme check until one exists.
