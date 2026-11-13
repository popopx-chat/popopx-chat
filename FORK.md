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

4. **Release artifacts** (2026-11-13) — the file names this repository's CI publishes into its own
   releases are `popopx-chat-*` (CLI) and `popopx-desktop-*` (dmg, msi, deb, AppImage). They are not
   cosmetic: the desktop updater filters `release.assets` by `name == githubAssetName`
   (`Platform.desktop.kt:14-18`, `AppUpdater.kt:397-402`) and reads the release list from one
   repository (`AppUpdater.kt:188`), so the CI name, the app literal, the API repository and the
   docs/website URLs are one value with four readers — moving any subset fails silently, with no
   error in the app. The packaging *producers* had been renamed earlier
   (`make-deb-linux.sh:57` → `popopx_${ARCH}.deb`, `desktop/build.gradle.kts:72,81,124` →
   `packageName = "POPOPX"/"popopx"`), while the CI steps that locate their output still globbed the
   upstream spellings; those seven readers (4 in `build.yml`, 3 in `desktop-linux.yml`) now derive the
   name from the build tree instead of hard-coding it.

5. **Download links** (2026-11-13) — every user-facing link that pointed at an APK asset now points at
   the Google Play listing, because this fork publishes no APK (see "What is still unset"). 25 URLs in
   README, `docs/DOWNLOADS.md`, the three `docs/lang/*/README.md` and 8 website pages. This leaves pages
   that show a Play badge next to a badge still labelled "APK"; relabelling or removing those is a copy
   decision, not a wire one. The three places that still name upstream's APK on purpose are
   `docs/REPRODUCE.md` (it verifies *their* signed build), `scripts/ci/android/release-apk.sh` with
   `.github/workflows/android-emu.yml:490` (the emulator smoke test installs that same upstream APK), and
   `plans/website-file-page-implementation.md:167` (a historical plan).
   The same pass defined `release` in `.eleventy.js`'s `globalConfig` and replaced 20 uses of
   `{{ release }}`: that variable is defined nowhere in `website/src`, so eleventy rendered it as the
   empty string and every desktop and CLI link on `/downloads` was a *relative* path — a 404 on our own
   site. It is exposed through the shortcode the site already uses for its other two global URLs
   (`{% cfg 'siteLocation' %}`), which is why it is `{% cfg 'release' %}` and not a `{{ }}` variable:
   Eleventy 1.x has no `addGlobalData`.

6. **The libs release assets** (2026-11-13) — `simplex-chat-libs-<os>-<arch>[-postgres].zip` and
   `simplex-chat-nodejs-<platform>.node` became `popopx-*`, together with the repository they are
   downloaded from. That repository is no longer upstream's: `popopx-chat/popopx-chat-libs` is this
   fork's, so the earlier reasoning ("an artifact name is data produced by whoever hosts the releases;
   renaming our side changes nothing") stopped applying, and `LIBS_REPOSITORY` already resolved to the
   fork in CI. What made this a two-ended value rather than a cosmetic one: the publisher
   (`packages_release.py`, `build.yml`, `package-tests.sh`), the *runtime* downloaders
   (`packages/popopx-chat-nodejs/src/libs.ts`, `packages/popopx-chat-python/src/simplex_chat/_native.py`)
   and the pinned digest dictionaries they look the name up in (`src/release.ts`, `dist/release.js`,
   `_version.py`) all spell it — a fork there does not fail, it downloads upstream's `libsimplex` into a
   POPOPX package and reports success. The digest *values* in those pins still describe upstream's
   builds; the next `packages_release.py prepare` rewrites them, and that is also the first run that can
   resolve a release published under these names, because `popopx-chat-libs` has no releases yet. Until
   then `release-status`/`download` against our repository returns nothing, which is the correct failure:
   `release_digests` requires every asset of the tag to be present, so a half-published release is
   refused rather than silently pinned.

7. **References to the SMP dependency** (2026-11-13) — 144 of the 446 `simplexmq` occurrences became
   `popopxmq`: the contributor instructions (`docs/CONTRIBUTING.md` and its `pl` translation,
   `docs/contributing/PROJECT.md`, `scripts/ci/README.md`, `scripts/ci/desktop-linux/README.md`), the
   operator and product docs a POPOPX reader follows (`README.md`, `docs/SERVER.md`,
   `docs/XFTP-SERVER.md`, `docs/CLI.md`, `docs/SIMPLEX.md`, `docs/SECURITY.md` and their
   `pl`/`fr`/`cs` translations), the iOS product/spec layer (`apps/ios/product/glossary.md`,
   `apps/ios/product/rules.md`, `apps/ios/spec/architecture.md`), the website's nav item, and one link
   that was simply broken: `apps/ios/Shared/Views/UserSettings/VersionView.swift:40` rendered
   "popopxmq: v… (commit)" hyperlinked into **upstream's** commit list, so every build of the settings
   screen 404ed on our own version information.
   A reference moved only where the same thing exists in `popopxmq`, which is not string equality: the
   fork renamed its own files, so `protocol/simplex-messaging.md` is `protocol/popopx-messaging.md` and
   `src/Simplex/**` is `src/Popopx/**`; and because the fork has one branch (`master`, its
   `origin/HEAD`), every `blob/stable/` and `raw/…/stable/` ref segment had to move with the path or the
   link 404s on a file that is there. The `#anchor` links moved only where the fork's README still
   produces that slug (all 8 do). Checked over HTTP: the moved URLs return 200.
   The three test harnesses that download a server for their suites
   (`packages/popopx-chat-mcp/test/e2e/smpServer.ts`, `packages/popopx-chat-nodejs/tests/smpServer.ts`,
   `apps/popopx-calculator-bot/test/smpServer.ts`) were ruled the same day to take it from
   `popopx-chat/popopxmq`. `popopxmq` publishes no releases, so those suites now fail with a 404 until it
   does — the comment at each site says so. That is the intended shape: a harness must not test our core
   against a server built from someone else's source and report a pass, and a 404 is loud. The operator
   docs are the opposite case, where the download is an instruction to a third party run against a
   server that has to work today — see "The server artifacts" below.

8. **The site host where a client or a user follows it** (2026-11-13) — 378 of the 680 remaining
   `https://simplex.chat` occurrences outside `website/**` became `https://popopx.chat`, per file, over
   300 lines / 83 files: iOS Swift (`Views/Onboarding`, `Views/Chat/ChatItem`, the snapshot harness's
   markdown fixtures), Kotlin multiplatform onboarding, `scripts/flatpak/com.popopxchat.popopx.metainfo.xml`
   (AppStream `homepage`/`help`/`donations` URLs a store and `appstreamcli` read), `scripts/ios`, the
   badge/directory/support-bot packages, `README.md`, `docs/guide`, `docs/FAQ.md`, the Node/Python SDK
   READMEs and the MCP card fixtures, and 98 occurrences in `tests/**` that mirror those same strings.
   Two of them were live defects: `packages/popopx-chat-python` built group share links as
   `https://simplex.chat/contact#/?v=2&group=…` — our app emitting an upstream-hosted link for a group our
   own relay serves, with the test mirrors agreeing with it — and `apps/popopx-badge-service/web` renders
   a contact footer whose visible label had to move with its `href` (`web/test/main.test.ts:483` asserts
   the label, so the pair moved together).
   Held, 302 occurrences: 135 in the 23 generated `apps/ios/POPOPX Localizations/*.xliff` catalogs
   (regenerated from source strings by Xcode — hand-editing them guarantees a drift the next build
   undoes), 42 carrying an encoded SMP/XFTP address or key, 124 in upstream's published text (`blog/`,
   `plans/`, `CHANGELOG.md`, `PRIVACY.md`, `docs/lang/`, `docs/protocol/`), 1 more protocol-document match.
   Reconcile a recount before suspecting a missed site: `git grep -o 'https://simplex\.chat'` outside
   `website/**` reads **306** on this tree, not 302, because 4 of those occurrences are this file and
   `CHANGELOG-POPOPX.md` *quoting* the old spelling to explain the ruling. The same command on the
   parent of `d7635b53d` reads 679, which is the denominator this item moves 378 of; the bare and
   subdomain forms (`simplex.chat`, `directory.simplex.chat`, `chat.simplex.app`) are a separate count of
   582 and were not this tier's subject.
   The 42 payload links are the reason this was not one find-and-replace: for a *contact* the address is
   now ours by ruling and it became `mailto:chat@popopx.chat` (item 9), and for a *group invitation* the
   group exists on upstream's relay, so neither the host nor the payload may move alone.

9. **The contact is chat@popopx.chat** (2026-11-13) — every "contact us / ask the team" link that carried
   SimpleX Chat Ltd's encoded SMP address was replaced with `mailto:chat@popopx.chat`: the site's
   `/connect-team` redirect target, the two llms answers/agents links (label included), and 21
   `website/langs/*.json` translated contact strings. Group invitation links were left alone — replacing
   one with an email silently deletes the group it pointed at.

Every modification carries the date of the commit that made it; `git log` is the
authoritative per-file record.

## What was deliberately NOT changed

- **Copyright and attribution.** The `author` / `maintainer` / `copyright` fields of
  `popopx-chat.cabal`, the three `Copyright (C) 2026 SimpleX Chat Ltd` asset-licence lines
  and the ~78 company-name references in the privacy, licence and legal texts are retained
  verbatim, as AGPL-3.0 §7 requires (and §4 forbids removing). This codebase carries no
  per-file copyright headers, so there is nothing else to preserve.
- **Upstream GitHub URLs**, and the dependency references that are not ours to claim: `docs/protocol/**`
  and `docs/rfcs/**` (those documents *are* upstream's source of record), `docs/REPRODUCE.md` and its
  `simplexmq-reproduce-builds.sh` / `v6.3.1-simplexmq` lines (the recipe reproduces upstream's signed
  build), `docs/dependencies/HASKELL.md` (a Dependency License Report whose entries are Hackage package
  names — `simplexmq-6.4.0.1` is upstream's), `plans/**`, `blog/**`, `CHANGELOG.md`, `docs/LINKS.md`,
  `docs/TRANSPARENCY.md` and `PRIVACY.md` as records, the `dist-newstyle/**` paths that captured commands
  quote, and the parts of `website/**` that are content rather than this site's own declaration.
  2026-11-13: `siteLocation` and the two feeds' `metadata.url` now say `https://popopx.chat`, because
  `website/src/CNAME` already read `popopx.chat` — the site was configured to be served from our domain
  while declaring itself `simplex.chat` to crawlers, feed readers and link previewers; `onionLocation`
  beside it stayed upstream's. The same pass moved every *self-pointer* the templates hardcode instead of
  reading `cfg` — 142 occurrences in 19 files: the generated sitemap `<loc>`, `robots.njk`'s `Sitemap:`,
  the llms indexes and their facts sources, the badge/store links in `js/channel-preview.jsc`,
  `js/directory.jsc`, and both arms of `isCurrentSite` in `js/simplex-lib.jsc` (so the `www.` alias became
  `www.popopx.chat`). The site is closed: what stayed there is 10 URLs on upstream's *service* subdomains
  (`directory.`, `app.` — including the F-Droid repo line and its signing fingerprint, `badges.`, `git.`,
  `api.`) which are held by the host-authority rule below, and 2 occurrences in
  `src/_includes/blog_previews/20221108.html`, upstream's own 2022 announcement ("the new website is
  live"), which is a record. The translated strings and llms documents that used to carry upstream's
  contact address now carry `chat@popopx.chat` (item 9), and the `simplex.chat/downloads` links in
  `website/langs/*.json` followed the host. The site's remaining `simplexmq` links still describe
  upstream's copy of the spec, which is what `--include-website` would move. Two
  `…/simplexmq/refs/heads/stable/scripts/docker/docker-compose-smp-{complete,manual}.env` references also
  stayed because those files exist nowhere: upstream ships only `docker-compose-smp.env`, so the two doc
  lines are broken at the source and are not this fork's regression.
- **The server artifacts, though their paths moved.** On 2026-11-13 the operator docs (`docs/SERVER.md`,
  `docs/XFTP-SERVER.md` and their `pl`/`fr`/`cs` translations, `docs/CHAT-RELAY.md`) were switched to
  `popopx` filesystem identity — `/etc/opt/popopx{,-xftp}`, `/var/opt/popopx{,-xftp}`,
  `/var/lib/tor/popopx-smp`, the caddy/systemd/docker-compose names — because that is what `popopxmq`
  compiles in (`apps/*/Main.hs defaultCfgPath`) and what its own docs already said. The lines that
  *obtain* a server did not: `docs/SERVER.md:293` and `:854` still download upstream's release binary
  and the compose blocks still default to `image: ${SIMPLEX_IMAGE:-simplexchat/smp-server:latest}`,
  whose `defaultCfgPath` really is `/etc/opt/simplex`. A self-hoster must therefore build the server
  from `popopxmq` (or set `SIMPLEX_IMAGE` to a POPOPX-built image); with upstream's artifact the
  mounted path and the path the process reads disagree, and the keys land in the container layer.
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
  SimpleX Chat Ltd; see [their `docs/TRADEMARK.md`](https://github.com/simplex-chat/simplex-chat/blob/stable/docs/TRADEMARK.md)
  for the policy, which
  forbids using the mark in a fork's name or branding. POPOPX is used instead for that
  reason. This fork makes no claim of affiliation.
- **Application graphics.** The illustrations, icons, visual designs and test-snapshot
  screenshots were proprietary and all rights reserved per
  [`assets/ASSETS_LICENSE.md`](./assets/ASSETS_LICENSE.md), which permits only distribution
  of the **unmodified** application. That permission does not extend to a rebranded fork, so the
  application graphics have been redrawn as POPOPX work product — the icons, the brand kit, the
  moko build-input illustrations, and (2026-11-13) the last upstream files in the iOS catalog: the
  crowdfunding badges, the chat wallpapers, `privacy` and `shield`. Any regenerated snapshot
  baselines are POPOPX Chat work product. What remains of upstream's artwork is documentation and
  website imagery, measured in [`ASSETS_LICENSE-POPOPX.md`](./ASSETS_LICENSE-POPOPX.md).

## What is still unset

This fork is published by **POPOPX**, contact **chat@popopx.chat** — see
[`PRIVACY-POPOPX.md`](./PRIVACY-POPOPX.md). The two documents that exist because the fork needs its
own statements are [`PRIVACY-POPOPX.md`](./PRIVACY-POPOPX.md) (this fork's privacy statement,
upstream's [`PRIVACY.md`](./PRIVACY.md) untouched) and
[`CHANGELOG-POPOPX.md`](./CHANGELOG-POPOPX.md) (this fork's release record, upstream's
[`CHANGELOG.md`](./CHANGELOG.md) untouched).

What remains below is not an undecided attribution — it is infrastructure this fork does not have
yet. Before any build of this fork is distributed:

- **No service is operated *by this fork* — except that `popopx.chat` is now in use anyway.** Ruled
  2026-11-13: the domain is used before its infrastructure is complete, and the gap is recorded rather
  than held. Since items 8 and 9 and the website pass, every self-declaration and every live link in the
  site, the app display copy, the SDKs, the Flatpak metainfo and the docs names `popopx.chat`, and the
  contact is `chat@popopx.chat`. Two things are still missing on that host and both are silent-to-loud
  failures to fix there, not in code: its TLS certificate SAN does not include `popopx.chat` (it names
  `popopxchat.com`), and neither `.well-known/apple-app-site-association` nor
  `.well-known/assetlinks.json` is served — both answered 404 when measured 2026-11-13. So universal
  links and `autoVerify` cannot be claimed by an installed app yet, link unescaping falls back to the
  scheme, and `assetlinks.json` will additionally need our Android signing fingerprints (upstream's three
  are still in the committed copy) before it verifies. The relay presets and the directory/badge service
  still name infrastructure SimpleX Chat Ltd operates, because a preset needs their key material and
  `popopx.im` relays have none published yet. `chat@popopx.chat` is likewise not reachable until that host
  serves mail or forwards.
- **This fork publishes no Android APK.** `.github/workflows/build.yml` builds and signs nothing for
  Android; `scripts/ci/android/release-apk.sh` downloads **upstream's** release APK and verifies
  SimpleX's signing certificate, which is what the emulator smoke test installs. The gradle output
  names (`popopx-arm64-v8a.apk`, `popopx-armv7a.apk`) are therefore only local artifacts. Ruled
  2026-11-13: the documentation links point at the stores (item 5 above) — but note that our Play
  listing is itself not published yet, so those links 404 *for us* until it is.
- **The bug-report address is still upstream's.** `StartupError.kt:28` `ISSUES_URL` →
  `github.com/simplex-chat/simplex-chat/issues`: a Windows startup crash tells the user to report it in
  upstream's tracker. Ruled 2026-11-13 to stay until our own tracker is set up; the reason is recorded
  as a comment above the constant. `SUPPORT_EMAIL` on the next line is already `chat@popopx.chat`, which
  is itself not yet reachable (first bullet).
- **`popopx-chat-libs` has published no releases yet.** The asset names and the source they are fetched
  from are ours (item 6 above), so nothing in this repository can resolve a `core-<version>` release
  today: the fork carries the build inputs and `releases.toml`, and its Releases list is empty. The first
  one has to come from our own CI, and that publish is also what rewrites the pinned digests in
  `release.ts`, `dist/release.js` and `_version.py` — until it does, those dictionaries still record
  upstream's build, under our names.
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
- **The application artwork is done; the documentation artwork is not.** The icons, illustrations and
  the 376 iOS snapshot baselines are POPOPX work product now (the iOS catalog's last upstream files —
  badges, wallpapers, `privacy`, `shield` — were redrawn on 2026-11-13). Still upstream's, and still
  licensed only for the *unmodified* application: the 210 desktop snapshot baselines, and the
  documentation and website imagery listed with counts in
  [`ASSETS_LICENSE-POPOPX.md`](./ASSETS_LICENSE-POPOPX.md).

### Upstream-operated hosts, and how each one fails

These are functional destinations, not branding: every one of them is where a POPOPX-branded build
sends a user. They are held as upstream wrote them, because renaming one only changes *who the
request says it belongs to* — the service itself does not move. Each row moves in the change that
stands up the equivalent POPOPX service, together with its keys.

| what it is | where | failure if the host moved alone |
| --- | --- | --- |
| badge service contact (an SMP relay + its key, in one address) | `src/Popopx/Chat.hs:74` | **silent**: TLS fingerprint mismatch, retried forever |
| notification servers preset (`ntf://<key>@ntf3.simplex.im`, `.onion` too) | `src/Popopx/Chat/Library/Commands.hs:167-168` | **silent**: same class. This is the one upstream preset still enabled in the client — the SMP/XFTP presets in `Chat.hs` were emptied, these were not. Kept on purpose: the list is a plain `[NtfServer]` (`Controller.hs:275`, and nothing downstream forces `NonEmpty` — `NtfSubSupervisor.hs:591` returns `Nothing`, `Agent.hs:3283` then fails token registration with `PROHIBITED`), so emptying it would be implementable but only costs push, exactly like the relays cost messaging. It moves with them |
| which stored relays count as "presets" | `src/Popopx/Chat.hs:103` `presetDomains = [".simplex.im"]` — `.simplexonflux.com` left with the Flux operator | **silent**: keyed on the host suffix, so renamed relays stop matching any stored row |
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
