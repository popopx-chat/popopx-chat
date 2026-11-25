# POPOPX Chat

**POPOPX Chat** is an AGPL-3.0-only, permissionless messenger with **no global user identity**: no phone
number, no email address, no account to register, and nothing that binds your contacts to a directory
that anybody operates. Messages travel over unidirectional queues on relays that are configured to
store no profile and see no conversation.

This project is **derived from [SimpleX Chat](https://github.com/simplex-chat/simplex-chat)** and is
**independently operated by POPOPX** — a different distributor, its own infrastructure, its own
release and support channel. The protocol, the cryptography and the core implementation are upstream's
work; [NOTICE](./NOTICE) lists the attribution that must stay in any build.

Versions shipped from this repository: the iOS client is **1.2.0 (build 100)**
(`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `apps/ios/POPOPX.xcodeproj/project.pbxproj`), the
Haskell core is **7.1.2.0** (`popopx-chat.cabal:8`).

---

## What "independently operated" changes in practice

The app presets **only POPOPX's own `popopx.im` cluster**. Upstream and third-party relay addresses were
removed from the preset lists — `src/Popopx/Chat/Operators/Presets.hs` contains no `simplex.im` and no
`simplexonflux.com` host, and the operator entry the app shows you is POPOPX's own:

```haskell
tradeName = "POPOPX Chat", legalName = Just "POPOPX",
serverDomains = ["popopx.im"], conditionsAcceptance = CARequired Nothing
```

That is a deliberate trade-off, stated plainly: **short links created against the removed relays no
longer resolve** on this build. What you gain is that a fresh install talks to exactly one operator —
the one named on the consent screen — and nothing else.

## Identity model

- **No global ID.** Your POPOPX address is a link to a queue on a relay, not a row in a table. There is
  no registration request anywhere in the codebase — no `createAccount`, no SMS or email verification.
- **No phone or email binding.** Nothing in the app collects either; on iOS the address book is never
  read (`CNContactStore` and `NSContactsUsageDescription` do not appear in the target).
- **A new address per conversation** is the design, not an option: the same profile can hold many
  addresses, and the peer only ever sees the one a conversation was started from.
- **No contact graph on a server.** The relay holding queue A does not learn that queue A belongs to the
  same user as queue B.

## Core technology

### Unidirectional queues with end-to-end encryption

The transport is SMP: a queue you create is written to by the sender and read only by you, so
establishing a connection requires no address discovery and no synchronous handshake. Everything the
relays hold is ciphertext, and the ratchet that protects it is yours: a double ratchet whose DH step is
**post-quantum hybrid by default** — `sntrup761` is combined with X25519 in every ratchet advancement
(`PQSupportOn` is the default in `src/Popopx/Chat/Library/Internal.hs:993` and
`src/Popopx/Chat/Library/Commands.hs:2160,3975,3997`; the primitive is compiled unconditionally from
the pinned `popopxmq` dependency, so it does not depend on a build flag). PQ encryption of this kind is
upstream's protocol design and this fork inherits it; the evidence cited above is ours.

### Offline delivery without a push dependency

A message is stored on the relay queue until the app fetches it, so delivery does not require a push
service to succeed. Apple's and Google's notification channels are used only to *wake* the app, and the
wake-up carries encrypted metadata — see [Privacy](./PRIVACY.md).

### Two channels for one contact, including Bluetooth-direct

`PopopxMessageRouter` publishes a `.dualChannel` status when a peer is reachable over more than one path
(`apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Router/PopopxMessageRouter.swift:271,1473`), and
`PopopxBLETransport.swift` implements the central and peripheral GATT roles behind it, with
`bluetooth-central` / `bluetooth-peripheral` background modes declared in
`apps/ios/POPOPX--iOS--Info.plist:61-62,92-100`. This lets a conversation continue between two iPhones
with no network at all.

Two things this section must not oversell:

- It is **iOS only** — there is no equivalent router in `apps/multiplatform`.
- It is **opt-in and fused off by default**: the kill-switch persists `false` when nobody has decided
  yet (`PopopxMeshKit/Sources/PopopxMeshUI/PopopxMeshKillSwitch.swift:245`), so a build does not start
  broadcasting until you enable it.
- The mesh's own handshake is `Noise_XX_25519` (`PopopxMeshKit/Sources/PopopxMeshKit/Crypto/PopopxNoiseXX.swift:8`).
  That is the *mesh* transport; SMP connections use the protocol's own handshake, not Noise.

### Media leaves with its metadata stripped

On iOS, images, video, PDF and documents are re-encoded locally before they are attached, and the
metadata dictionaries are dropped (`apps/ios/Shared/Features/MediaCompression/PopopxMediaEngine.swift:378-379`
for JPEG, `:425` sets `writer.metadata = []` for video). The interceptor that calls it is wired into the
compose view (`Shared/Views/Chat/ComposeMessage/ComposeView.swift:2033-2037,2317`). Voice messages
currently bypass that path (`:2312-2315`), and Android has no equivalent; if media compression is
switched off in settings, files are passed through untouched.

### The node badge, bought inside the app

The supporter badge is a StoreKit 2 purchase (`Shared/Features/BadgeCredits/PopopxStoreKitManager.swift:197-272`,
13 SKUs `com.popopx.badge.node.*`). The ledger is **local, in the device Keychain**
(`PopopxBadgeManager.swift:69,136,215`), and there is no POPOPX store service that could revoke it: the
code says so itself — *"taking an entitlement back across devices would need a server, and this feature
has none"* (`PopopxCreditsManager.swift:285`). Consequences are documented in
[PRIVACY.md](./PRIVACY.md): purchases do not move between devices, and Apple — not POPOPX — holds the
payment record.

### Signed server configuration, applied silently

Two official POPOPX subscriptions are seeded without a dialog on first launch of a profile
(`Shared/Features/ServerConfigSync/PopopxServerConfigSignalHandler.swift:814-820`, guarded by a
per-user persisted marker, so it is idempotent), and configuration pushed down the signed channel is
verified, merged and applied silently, with a rollback snapshot and a revert path if the applied
generation fails its probes (`:10-30`). It is triggered from three points in the app lifecycle
(`Shared/Navigation/MainTabView.swift:233,244,253,262`). Receipts for an applied generation are only
sent uplink from a direct chat — never from the broadcast channel.

### Duress erasure

Two distinct features, because they destroy different things:

- **Duress passphrase** (`Shared/Features/AntiTheftDuress/PopopxDuressAuthManager.swift:831-905`) closes
  the chat, wipes the mesh identity, deletes the databases, backups, exports, wallpapers and the stored
  database password (`apps/ios/POPOPXChat/FileUtils.swift:143-163`), removes the app/duress/mnemonic
  keychain items, and then rebuilds a fresh profile. An alternate strategy (`:998-1053`) keeps one
  chosen profile and deletes the others **including their server queues**.
- **Panic wipe** (red row in `PopopxMeView.swift:514-537`, or a triple-tap of the brand mark) is the
  mesh's two-pass overwrite. In the iOS app it is constructed with `applicationDatabaseURL: nil`
  (`Shared/Model/POPOPXAPI.swift:3808-3816`), so it clears mesh keys, radio state and mesh records —
  **not** the chat database. Enable whichever one matches what you actually need gone.

### Calls

Voice and video calls run over WebRTC with the local rendering and signaling in this repository. The
ICE configuration that ships is STUN-only: `stun:stun1.popopx.im:5349`
(`apps/ios/Shared/Views/Call/WebRTCClient.swift:93`, `packages/popopx-chat-webrtc/src/call.ts:355`).
The parser accepts `turn:` / `turns:` entries and a signed configuration can deliver them, but **POPOPX
operates no TURN server**, so a call between two peers behind restrictive NATs may fail to connect;
self-hosting a TURN and adding it to your ICE configuration is the current answer.

## The infrastructure

Fifteen relay endpoints, each written as a public host **and** a paired V3 onion address in the same
entry, plus one STUN host:

| Role | Hosts | Port | Source |
|---|---|---|---|
| SMP message queues | `smp1..8.popopx.im` | 5223 (port-less addresses) | `Operators/Presets.hs:69-76` |
| Chat relay | `relay1.popopx.im` | 5227 | `Operators/Presets.hs:105,115` |
| XFTP file transfer | `xftp1`, `xftp6`, `xftp8.popopx.im` | 8443 | `Operators/Presets.hs:91-93` |
| NTF push notification | `ntf1..3.popopx.im` | 5226 | `Library/Commands.hs:164-169` |
| STUN | `stun1.popopx.im` | 5349 | `Shared/Views/Call/WebRTC.swift:465` |

The ports are load-bearing, not cosmetic: a port-less SMP address is dialled on the native port (5223),
while a port-less XFTP address would be dialled on 443 — and 443 on this cluster is the web server, not
the file transfer service. `.popopx.im` is deliberately absent from `presetDomains` for the same reason.

**On dual-stack:** every endpoint above carries both a public DNS host and a V3 `.onion` host, measured
2026-11-25. None of them carries an IPv6 `AAAA` record — `dig +short AAAA popopx.chat smp1.popopx.im`
is empty for every host in this project. The second channel is Tor, not IPv6.

### Public sites

Measured 2026-11-25 with `dig` and an HTTP status probe. All four resolve to `43.129.40.33` and answer
`200` at the site root:

| Site | Address | What it is |
|---|---|---|
| Project site | `https://popopx.chat/` | The fork's own homepage |
| Mac Node | `https://node.popopx.chat/` | Self-hosting the server cluster on your own Mac; `/badge` answers 200 |
| Portal | `https://mp.popopx.chat/` | Service accounts and channel ecosystem |
| Bot Studio | `https://bot.popopx.chat/` | Running your own bots against a server you control |

`https://popopx.chat/security/`, `https://popopx.chat/privacy`, `https://popopx.chat/terms` and every
`/docs/…` path answer **404** today: that content was removed from the site, so **the policies are the
files in this repository**, not pages. `popopx.chat` publishes **no MX record** (measured the same day).

### Official POPOPX addresses

These are the two preset official subscriptions the app joins silently; they are the same values the
client reads (`apps/ios/Shared/Features/ServerConfigSync/PopopxServerConfigSignalHandler.swift:919-929`).
Both are published here as complete SMP addresses, because a host without its key and path is not dialable:

- **Configuration channel** (read-only; the server pins members to `observer`):
  `https://smp2.popopx.im/g#AbX7ZWizYxULjL-QpOGJLJm7C33BcXIsLc61IVOa8zM?c=4bJjC-wqSpviWwuDnkhSKTD4V8mYxpLqj4aiCUSfGfA`
- **POPOPX service account** (1:1, silent delivery, and where update receipts go):
  `https://smp6.popopx.im/a#ZwDniscH42Q2di4Ti-2MJns_ow7OasGL1BwoDoVBnis?c=2bIUdRa7VJeB2tx9W3gwaOJ2Sv72fH8Pc_uM9l9r4hM`

## Tor and proxies

No Tor is bundled with any client. The `.onion` half of every address above means the app *can* be
pointed at the hidden-service endpoint instead of the public host, and on iOS
`Shared/Views/UserSettings/NetworkAndServers/AdvancedNetworkSettings.swift:112,142,182-187,365-378`
exposes a SOCKS5 switch plus a `.onion`-preference toggle, plumbed through as `socksProxy`
(`apps/ios/POPOPXChat/AppGroup.swift:362,392`). **That toggle requires a proxy you supply** (the setting
itself says "Requires compatible VPN") and it is off by default — so on mobile, IP protection against a
compromised relay is something you configure, not something the build does for you. The CLI has the
corresponding options (`src/Popopx/Chat/Options.hs:127-150`).

## Building from source

### iOS: the native Haskell core

The static libraries the Xcode project links are cross-compiled with Nix. The flake attributes are
branded, so the target is `…:lib:popopx-chat`, never `…simplex-chat`. Both forms below instantiate
(verified 2026-11-25 with `--dry-run`):

```bash
nix build '.#hydraJobs.aarch64-darwin."aarch64-darwin-ios:lib:popopx-chat"' \
  --extra-experimental-features "nix-command flakes" -o ./ios-core
# equivalent short form:
nix build '.#"aarch64-darwin-ios:lib:popopx-chat"' \
  --extra-experimental-features "nix-command flakes" -o ./ios-core
```

`flake.nix` builds from a `cleanGit` tree, so **uncommitted Haskell changes are not in the output** —
commit before rebuilding. The result is `pkg-ios-aarch64-swift-json.zip`; unpack the five `.a` files
into `apps/ios/Libraries/ios/`.

Then align the archives' minimum OS to the app's floor. `scripts/ios/set-minos.py` takes a positional
version, not a flag, and patches every `LC_BUILD_VERSION` in place:

```bash
python3 scripts/ios/set-minos.py 17.0 apps/ios/Libraries/ios/*.a
```

Running it a second time reports `written=0`, which is the proof the field already holds 17.0. Skipping
this step leaves the RTS-built members stamped with the SDK version and the linker emits thousands of
"built for newer iOS" warnings.

Gate the result with a build that needs no signing:

```bash
xcodebuild build -project apps/ios/POPOPX.xcodeproj -scheme "POPOPX (iOS)" \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

For a simulator build, pass `ARCHS=arm64` explicitly. The libraries directory is gitignored: what makes
a build reproducible is the flake plus this command, not the artifacts on a disk.

### Other platforms

Android, desktop and the CLI are built from this repository by the workflows in `.github/workflows/`;
`docs/CLI.md` covers the command-line client, and the desktop DMG recipe is in
`apps/multiplatform/README.md` where upstream left it.

## Self-hosting

Every server the app presets is replaceable in Settings without a rebuild, and the same binaries that
serve `popopx.im` are the ones you can run: `node.popopx.chat/` documents doing it on your own Mac.
Relay keys are part of the address, so switching relays means new addresses for existing contacts — the
app's server-switch flow is the place to read before migrating a live contact.

## Privacy

**[PRIVACY.md](./PRIVACY.md)** is POPOPX's policy for this application and the cluster above: what the
app does not collect, what the relays hold, what iOS protects on disk, and where the boundaries are that
this fork cannot promise more than Apple or a self-hosting user already implies.
**[PRIVACY-POPOPX.md](./PRIVACY-POPOPX.md)** is the companion record — who operates what, which text is
upstream's, and the measurement or file each claim rests on.

## Security contact

Report a vulnerability in a POPOPX Chat build to **chat@popopx.chat**. Delivery to that address is
**not verified**: `popopx.chat` publishes no MX record (measured 2026-11-25), and POPOPX publishes no
OpenPGP key for it, so a report travels unencrypted unless you supply a key from elsewhere. Closing that
gap — a working mail route and a published key — is open work, not a documented capability. Please do
**not** report vulnerabilities as GitHub issues.

## License

**The code, the artwork, the names.** The source code of this software is licensed under the GNU Affero
General Public License version 3 (AGPLv3) — see the [LICENSE](./LICENSE) file. The artwork this fork
created carries the same grant, or CC0-1.0 at the recipient's option, since 2026-11-16. The names follow
from nothing here: a trade mark sits outside a copyright licence. Upstream's side of both is separate
again:

- **Upstream (SimpleX Chat Ltd).** The SimpleX and SimpleX Chat name, logo, associated branding materials,
  and application and website graphic assets (illustrations, images, visual designs, etc.) are not
  covered by this license and are subject to the terms outlined in the
  [TRADEMARK](https://github.com/simplex-chat/simplex-chat/blob/stable/docs/TRADEMARK.md) and
  [ASSETS_LICENSE](./assets/ASSETS_LICENSE.md) files respectively.
- **POPOPX (this fork).** The POPOPX and POPOPX Chat name, the wordmark, the logo and the icons derived
  from it, and the `popopx.chat` domain are not licensed to anyone by this document and are subject to
  [TRADEMARK-POPOPX](./TRADEMARK-POPOPX.md). The artwork this fork created is licensed, not reserved:
  [ASSETS_LICENSE-POPOPX](./ASSETS_LICENSE-POPOPX.md). It licenses only what this fork drew — it cannot
  and does not release the upstream-identical files listed there.

**If you fork this repository and distribute it, rebrand.** You keep every right AGPLv3 gives you over
the code, and since 2026-11-16 the same rights over this fork's own artwork; what you may not carry away
is either project's name, or upstream's artwork. So your build must ship a different name and its own
wordmark, icons and marks — our other drawings you may keep, but never as the identity of your product.
[NOTICE](./NOTICE) lists the upstream attribution that has to stay.
