# Fork and modification notice

> This file is the "prominent notice of modification" required by
> [AGPL-3.0 §5c](./LICENSE) and AGPL-3.0 §7 attribution note. It is not part of the
> AGPL text and does not modify it.

**POPOPX Chat is a non-official, modified fork of SimpleX Chat.** It is not affiliated with,
sponsored by, or endorsed by SimpleX Chat Ltd.

| | |
|---|---|
| Upstream project | [github.com/simplex-chat/simplex-chat](https://github.com/simplex-chat/simplex-chat) |
| Upstream code imported at | our commit `db0768c21` (2026-11-11) |
| This fork's source | [github.com/popopx-chat/popopx-chat](https://github.com/popopx-chat/popopx-chat) |
| Complete corresponding source | this repository, including build scripts (`cabal.project`, `flake.nix`, `apps/ios`, `apps/multiplatform`) |
| Licence of the code | AGPL-3.0-only, unmodified — see [`LICENSE`](./LICENSE) |

## What was changed

The changes so far are a **name and identifier rebranding** (`simplex` → `popopx`,
`SimpleX` → `POPOPX`), not a functional rewrite of the protocol or the cryptography. In
summary:

1. **Identifiers** — iOS bundle ids, App Group, keychain access group, team id, Android
   `applicationId`, notification-channel and preference-store ids, macOS `bundleID`,
   Windows registry capabilities, AppImage/AppStream ids, store links, the Haskell module
   namespace `src/Popopx/**`, the cabal package pin for the forked `popopxmq`, and the
   library name `libpopopx` (a dual lookup for `libsimplex*` is retained).
2. **Brand text layer** — iOS `.strings`/`.xliff` catalogues, Swift and Kotlin display copy,
   `strings.xml` for every locale, terminal/UI strings, and the documentation/README copy.
3. **Structural names** — directory and file names under `apps/` and `packages/`, and the
   paths that reference them in CI, Nix, Docker and flatpak scripts.

Every modification carries the date of the commit that made it; `git log` is the
authoritative per-file record.

## What was deliberately NOT changed

- **Copyright and attribution.** The `author` / `maintainer` / `copyright` fields of
  `popopx-chat.cabal`, the three `Copyright (C) 2026 SimpleX Chat Ltd` asset-licence lines
  and the ~78 company-name references in the privacy, licence and legal texts are retained
  verbatim, as AGPL-3.0 §7 requires (and §4 forbids removing). This codebase carries no
  per-file copyright headers, so there is nothing else to preserve.
- **GitHub URLs** of the upstream project, which still point at the original source.
- **Cryptographic pre-images** (HKDF info parameters, badge hash inputs, SQLite FFI symbol
  names). Renaming these would silently break key derivation instead of failing to compile.
- **Anything naming an upstream thing**: upstream operator addresses, the `simplex:` address
  format as understood on the public network, upstream social accounts. An identifier that
  names something belonging to upstream keeps upstream's name, or it stops resolving.
- **The domains** (`simplex.chat`, `simplex.im`) and the associated-domains / universal-link
  entries, until POPOPX owns and operates its own.

## Trademarks and artwork — outside the AGPL grant

Clause-by-clause compliance record, including what the asset licence blocks before a release:
[`AGPL-COMPLIANCE-POPOPX.md`](./AGPL-COMPLIANCE-POPOPX.md).

Two things in this repository are **not** licensed to you under AGPL-3.0, and a text
substitution does not change that:

- **Trademarks.** "SimpleX", "SimpleX Chat" and the associated logos are trademarks of
  SimpleX Chat Ltd; see [`docs/TRADEMARK.md`](./docs/TRADEMARK.md) for their policy, which
  forbids using the mark in a fork's name or branding. POPOPX is used instead for that
  reason. This fork makes no claim of affiliation.
- **Application graphics.** The illustrations, icons, visual designs and test-snapshot
  screenshots are proprietary and all rights reserved per
  [`assets/ASSETS_LICENSE.md`](./assets/ASSETS_LICENSE.md), which permits only distribution
  of the **unmodified** application. That permission does not extend to a rebranded fork.
  The bundled artwork is therefore pending replacement with POPOPX-owned assets or removal;
  it must not be redistributed as part of this fork. Any regenerated snapshot baselines are
  POPOPX Chat work product.

## What is still unset

This fork is published by **POPOPX**, contact **chat@popopx.chat** — see
[`PRIVACY-POPOPX.md`](./PRIVACY-POPOPX.md). The two documents that exist because the fork needs its
own statements are [`PRIVACY-POPOPX.md`](./PRIVACY-POPOPX.md) (this fork's privacy statement,
upstream's [`PRIVACY.md`](./PRIVACY.md) untouched) and
[`CHANGELOG-POPOPX.md`](./CHANGELOG-POPOPX.md) (this fork's release record, upstream's
[`CHANGELOG.md`](./CHANGELOG.md) untouched).

What remains below is not an undecided attribution — it is infrastructure this fork does not have
yet. Before any build of this fork is distributed:

- **No service is operated *by this fork*.** The relay presets, the link domain, `.well-known`, the directory
  and the badge service all still name infrastructure SimpleX Chat Ltd operates. The `popopx.im` relays and the
  `popopx.chat` web server that this fork's own domains point at are up (see the two bullets below), but
  nothing in a build of this fork talks to them yet: no preset names them, because a preset needs their
  fingerprints and those are only readable on the servers themselves. `chat@popopx.chat` is likewise not
  reachable until that host serves mail or forwards.
- **No registry namespace.** The npm and PyPI names in the committed manifests are upstream's, and
  that is the shape the release tooling expects: `packages_release.py test-names` rewrites the names,
  the repository URL and the cross-package dependencies to `npm:` aliases at publish time from the
  repository variables `NPM_SCOPE` and `PYPI_PROJECT`. Setting those two variables — plus an
  `@popopx-chat` npm org, a `popopx-chat` PyPI project and a `popopx-chat-libs` repository — is the
  fix; hand-editing the manifests would break `unreleased_pins()` and `check-pins` instead.
  Full method: [`NODE-PACKAGES-POPOPX.md`](./NODE-PACKAGES-POPOPX.md).
- **Link claims are inert, for three independent reasons.** All three must clear in the same change.
  - *This tree publishes nothing.* The Deploy step of `.github/workflows/web.yml:36` is gated
    `if: github.repository == 'simplex-chat/simplex-chat'`, so this repository never publishes a
    site at all; `website/src/CNAME`, passed through to the site root by `website/.eleventy.js:471`,
    still reads `simplex.chat` — GitHub Pages would claim the upstream domain. What does answer on these
    domains is a different deployment, described next.
  - *Measured 2026-11-12, corrected by a closer look on 2026-11-13.* `popopx.chat` is registered
    (Namecheap) and resolves to `43.129.40.33` — identically from 1.1.1.1, 8.8.8.8 and 9.9.9.9, unlike
    `simplex.chat`, which answers a different address per resolver on this network, so these records are real
    and not injected. Something does answer there, and it is **this fork's own site** — `<title>Home - Popopx
    Chat</title>`, `nginx/1.14.1`, `x-powered-by: PHP/7.2.24`, served for `popopx.chat`, `popopxchat.com` and
    `www.popopxchat.com` alike, over plain HTTP as well as HTTPS. Three consequences, none of them fixable in
    this repository:
    - **The site that is deployed is not the site in this tree.** `website/` is upstream's Eleventy build and
      nothing in CI publishes it (there is no `gh-pages` branch either — `git ls-remote --heads origin`
      returns one ref). So `web.yml:36` and `website/src/CNAME` are not the levers; publishing
      `.well-known` means adding two static locations to that nginx.
    - **The certificate is single-name.** `CN=popopxchat.com`, and its SAN holds only
      `DNS:popopxchat.com` — no `popopx.chat`, no `www`. Every client therefore sees a name mismatch on
      `https://popopx.chat/`, including the OS link verifier, which requires a valid TLS connection before it
      reads a single byte of `apple-app-site-association`. `www.popopxchat.com` fails the same way.
      Ruled 2026-11-13: the replacement certificate carries `popopx.chat`, `popopxchat.com` and
      `www.popopxchat.com`.
    - **The two association files need exact paths and content types**, not just a directory. Apple fetches
      `https://<domain>/.well-known/apple-app-site-association` — no extension, no trailing slash — while this
      repository stores it as `apple-app-site-association/index.json`, so the server must map that name to the
      JSON (or redirect, which Apple follows). `assetlinks.json` is stricter: exactly one path, `200`,
      `application/json`, no redirect and no HTML error page, and Android reads it before it will verify
      `autoVerify` for `com.popopxchat.popopx`.
    - **Nothing is published under `/.well-known/` on either name** — each returns the PHP application's 404
      HTML page, so the files in `website/src/.well-known/` are not deployed anywhere.
  - *The relay hosts exist too, and all but one are not serving.* `smp1-8`, `xftp1`, `xftp6`, `ntf1-3`
    under `popopx.im` each resolve to a distinct address (`xftp2-5` and `ntf4` do not resolve, and the zone
    has no wildcard, so every record was written deliberately); `smp1-8`, `xftp1` and `xftp6` carry the same
    A records under `popopxchat.com` too, which is the name the servers were initialized with. The fill-in
    table for their keys is the fork's `relay-keys.yaml`, kept with the rebrand tooling outside this
    repository. A fingerprint does **not** need the server's
    shell: it is `base64url(sha256(DER of the CA certificate))`, and a listening relay sends that CA as the
    second certificate of its chain — which is exactly how the client pins it
    (popopxmq `src/Popopx/FileTransfer/Client.hs:186` matches `[_leaf, ca]`). It is also stored on the box,
    in the file `fingerprint` in the server's config directory (`/etc/opt/popopx`, `/etc/opt/popopx-xftp`,
    `/etc/opt/popopx-notifications`, per that repository's `apps/*/Main.hs`). Reading it from here requires
    OpenSSL 3, because the relays sign with
    Ed448 and the system TLS stack answers `handshake failure` for anything else — so a failed handshake is
    not evidence about the server.
    Measured 2026-11-13 across those 13 hosts and both protocol ports: **one serves a relay.**
    `xftp1.popopx.im:443` sends a chain whose CA subject is `CN=SMP server CA, O=POPOPX` — a string only
    this fork's `popopxmq` writes — so that box already runs our dependency's server. Every other host
    refuses the connection or is filtered. Nothing therefore moves yet: SMP has zero relays listening, so
    presetting our own relays would ship a build that cannot message, which is a worse half-config than the
    one the reverted pin fixed. The remaining input is operational, not informational — start
    `smp-server`/`xftp-server`/`ntf-server` on those boxes and open the port in the provider's security
    group; the keys then read themselves and the cutover is one scripted pass (see "Upstream-operated
    hosts" below).
  - *The signing identity is not ours.* `website/src/.well-known/assetlinks.json` carries our
    `package_name` with SimpleX Chat Ltd's three signing-certificate fingerprints, so `autoVerify`
    cannot pass for a package signed by anybody else. Same class on iOS: the Team ID `PDBA6XRBQT`
    appears in four places across three files — `KeyChain.swift:13`, two build configurations in
    `POPOPX.xcodeproj/project.pbxproj`, and `apple-app-site-association/index.json` — and all of
    them must agree with whatever certificate actually signs the distribution. A wrong one fails
    silently: keychain sharing and universal links stop working, and only on device.
- **`popopx.chat` is owned and serving, and is now the ruled link domain.** Ruled 2026-11-13:
  `popopx.chat` for links and the site, `popopx.im` for relays. `website/src/CNAME` moved to
  `popopx.chat` — nothing reads it but `website/.eleventy.js:471`, which publishes it to the site root, so
  the change is inert until something departs from the hand-run nginx. What still makes link handling inert
  is on that box: a certificate that names only `popopxchat.com`, and no `/.well-known/` at all.
- **Store links 404.** Every `market://` / `details?id=com.popopxchat.popopx` / App Store URL in
  this repository names an app record that does not exist yet.
- **The artwork is still SimpleX's.** The icons, illustrations and the 376 iOS snapshot baselines
  are proprietary and licensed only for the *unmodified* application, so a rebranded fork may not
  redistribute them; they need replacing with POPOPX-owned assets and regenerating.

### Upstream-operated hosts, and how each one fails

These are functional destinations, not branding: every one of them is where a POPOPX-branded build
sends a user. They are held as upstream wrote them, because renaming one only changes *who the
request says it belongs to* — the service itself does not move. Each row moves in the change that
stands up the equivalent POPOPX service, together with its keys.

| what it is | where | failure if the host moved alone |
| --- | --- | --- |
| badge service contact (an SMP relay + its key, in one address) | `src/Popopx/Chat.hs:74` | **silent**: TLS fingerprint mismatch, retried forever |
| notification servers preset (`ntf://<key>@ntf3.simplex.im`, `.onion` too) | `src/Popopx/Chat/Library/Commands.hs:167-168` | **silent**: same class. This is the one upstream preset still enabled in the client — the SMP/XFTP presets in `Chat.hs` were emptied, these were not. Kept on purpose: the list is a plain `[NtfServer]` (`Controller.hs:275`, and nothing downstream forces `NonEmpty` — `NtfSubSupervisor.hs:591` returns `Nothing`, `Agent.hs:3283` then fails token registration with `PROHIBITED`), so emptying it would be implementable but only costs push, exactly like the relays cost messaging. It moves with them |
| which stored relays count as "presets" | `src/Popopx/Chat.hs:103` `presetDomains = [".simplex.im", ".simplexonflux.com"]` | **silent**: keyed on the host suffix, so renamed relays stop matching any stored row |
| shared directory listing | `website/src/js/directory.jsc:1` (`/data/`), filter at `:149` | **silent-empty**: the fetch fails and the page shows no results |
| badge embed allow-list | `apps/popopx-badge-service/web/src/embed.ts:53` | **silent**: the widget refuses an origin outside `simplex.chat`/`.simplex.chat` and renders blank |
| badge purchase deep links | `apps/multiplatform/common/src/commonMain/kotlin/chat/popopx/common/views/badges/BadgeStore.kt:53-54` | **visible**: leaves the app into `badges.simplex.chat` — an upstream-branded page under a POPOPX label |
| ICE/STUN/TURN defaults | `packages/popopx-chat-webrtc/src/call.ts:355-359` (`stun.simplex.im`, `turn.simplex.im`; the TURN line carries a username and a literal credential) | **visible**: calls fail to connect. Used only when the user configured none (`AppSettings.hs:45` `webrtcICEServers`), and the credential is upstream's to revoke |

One entry in that list is not a host+key pair and could be fixed without any infrastructure, so it was:
the discovery document `website/src/.well-known/simplex.json` carried five SimpleX Chat Ltd channels, groups
and contacts (`smp4/smp10/smp18.simplex.im` links titled "SimpleX Network News", "SimpleX Crowdfunding News",
"SimpleX users group", "Ask SimpleX Team", "SimpleX Directory"). The *path* is a protocol value —
`docs/protocol/web-discovery.md:99` and `:218` register `simplex.json` as an RFC 8615 URI suffix, and a client
follows exactly that name — so the file keeps its name; the *entries* are not a protocol value, and publishing
another operator's identities under our own domain claims them as ours. The three arrays are empty until this
fork operates relays and can author its own addresses.

The **silent** class is the dangerous one. A host+key pair identifies one server, and only that pair
is a wire value: `smp://<key>@<host>` is hand-written, never generated, so an identifier sweep that
renames one half compiles, decodes and connects to nothing. What the agent then reports is a TLS
fingerprint mismatch (`UNKNOWNCA`), which it classifies as *temporary* — so it retries the same
preset indefinitely instead of failing over to the next one, and onboarding hangs with no error the
user can act on. That is what happened during this fork's preset testing; the pairs in the
dependency are reverted for exactly that reason (see popopxmq `NOTICE` §3).

The `pairs` mode of this fork's wire-audit tool (`ding_wire_audit.py`, kept with the rebrand
tooling outside the repository) gates this class: it collects every address
whose key is a real fingerprint from the client, the pinned dependency and the pre-rebrand upstream
base, in both spellings a pair travels in — `smp://<key>@<host>` and the link form
`https://<host>/a#<key>` that published documents use — and reports any ours-host+upstream-key pair,
any pair that drifted into a generated artifact, and any brand host a shipped artifact still names
that no source mentions. Keys that base64-decode to readable text are test vectors, and are excluded
by value rather than by path, so the encoder tests in the dependency do not read as broken pairs.

## Obtaining the source

The complete source code for this program, including everything needed to generate the
binaries distributed for it, is available at
[github.com/popopx-chat/popopx-chat](https://github.com/popopx-chat/popopx-chat) at no cost,
under AGPL-3.0, for as long as the corresponding object code remains available.
