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

- **No service is operated.** The relay presets, the link domain, `.well-known`, the directory and
  the badge service all still name infrastructure SimpleX Chat Ltd operates; `chat@popopx.chat` is
  not reachable until `popopx.chat` is served.
- **Android link verification is broken by design until re-signed.**
  `website/src/.well-known/assetlinks.json` carries our `package_name` with SimpleX Chat Ltd's
  three signing-certificate fingerprints; `autoVerify` cannot pass for a package signed by anybody
  else. Same class on iOS: the Team ID `PDBA6XRBQT` is hardcoded in three places that must agree
  with whatever certificate actually signs the distribution — `KeyChain.swift:13`, two build
  configurations in `POPOPX.xcodeproj/project.pbxproj`, and
  `apple-app-site-association/index.json`. A wrong one fails silently: keychain sharing and
  universal links stop working, and only on device.
- **`popopx.chat` is not ours yet.** The link namespace, `.well-known` and universal-link entries
  point at it, so link previews and domain-verified names are inert until the domain is owned,
  served over HTTPS with those files reachable, and the app is rebuilt against it.
- **Store links 404.** Every `market://` / `details?id=com.popopxchat.popopx` / App Store URL in
  this repository names an app record that does not exist yet.
- **The artwork is still SimpleX's.** The icons, illustrations and the 376 iOS snapshot baselines
  are proprietary and licensed only for the *unmodified* application, so a rebranded fork may not
  redistribute them; they need replacing with POPOPX-owned assets and regenerating.

## Obtaining the source

The complete source code for this program, including everything needed to generate the
binaries distributed for it, is available at
[github.com/popopx-chat/popopx-chat](https://github.com/popopx-chat/popopx-chat) at no cost,
under AGPL-3.0, for as long as the corresponding object code remains available.
