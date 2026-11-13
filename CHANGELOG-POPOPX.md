# POPOPX Chat — release history of this fork

> This file records **this fork**. [`CHANGELOG.md`](./CHANGELOG.md) is upstream's release history and
> is kept unmodified; the versions below are the fork's own state, not upstream releases.

## Unreleased — as of 2026-11-13 (90 commits after the import point `db0768c21`)

Forked from `github.com/simplex-chat/simplex-chat` at `db0768c21` (2026-11-11), code version
`7.1.2.0` (`v7.1.2`). No POPOPX binaries have been published from this repository yet: the store
links, the APK/F-Droid artifacts and the website are all still upstream's or absent, so there is no
"installed version" of this fork to upgrade or downgrade.

Everything below is a **name and identity** change. Nothing in this list alters the protocol, the
cryptography or the wire format.

### Data locations — treat this as a new application

An installation that ever used a SimpleX-named build does **not** see its chats in this one, and no
migration is provided on purpose. The moved locations are the iOS bundle id / App Group / keychain
access group, the Android `applicationId`, notification-channel and preference-store ids, the
on-disk database prefixes `popopx_v1*`, the macOS `bundleID` and Windows registry capabilities, the
AppImage/AppStream ids, the Flatpak desktop/metainfo ids (`scripts/flatpak/com.popopxchat.popopx.*`)
and `.appdata.xml` filename, and the application data directories. The CLI and the bots call
`getAppUserDataDirectory "popopx"`: `~/.local/share/popopx` on Linux,
`~/Library/Application Support/popopx` on macOS, `%APPDATA%\popopx` on Windows. The desktop app uses
`~/.local/share/popopx` and the config dir `~/.config/popopx` (`%AppData%\POPOPX` on Windows) — both
read from `Platform.desktop.kt:7-16`, which is the generator for these paths. The server-side
filesystem identity moved too — 200 occurrences / 9 files across `docs/SERVER.md`,
`docs/XFTP-SERVER.md`, their `pl`/`fr`/`cs` translations and `docs/CHAT-RELAY.md`:
`/etc/opt/popopx{,-xftp}`, `/var/opt/popopx{,-xftp}`, `/var/lib/tor/popopx-smp`, the
caddy/systemd/docker-compose names — matching what `popopxmq` compiles in as `defaultCfgPath`. The
chat relay's Postgres role and database are `popopx` and `popopx_chat_relay`
(`scripts/relay/.env.example`), and the relay guide's `systemctl`, `Unit=` and executable
references name the `popopx-*` artifacts that guide installs. The commands that fetch a server
still name upstream's artifact (its release binary and the `simplexchat/*-server` image default),
which reads `/etc/opt/simplex`; see `FORK.md`.

### What the user sees

Display copy in every iOS catalogue, Kotlin/Swift string and locale, terminal output and live
documentation says POPOPX. The link namespace the app recognizes and emits is `popopx.chat`
(`.well-known`, universal links, Android `autoVerify`) — **ruled as this fork's link domain on
2026-11-13, with `popopx.im` as the relay domain.** The domain is registered and a site answers on
it, but its TLS certificate names only `popopxchat.com` and nothing is published under
`.well-known`, so link previews and profile/domain resolution remain inert until that box serves a
matching certificate and the two association files.

Flux is **not offered as a server operator** (ruled 2026-11-13). Removed: the preset operator record,
the v6.2 "Network decentralization" what's-new entry, the operator description cards, the routing
example that named Flux, the `*.simplexonflux.com` universal links (iOS entitlements) and intent-filter
hosts (Android), the `Flux` iterations in the CI scripts, the three Flux logo assets, and every locale
unit whose text named the second operator (56 carrier files). Kept, with the reason at each site: the
wire tag `"flux"` (`OperatorTag`/`OTFlux` — it decodes stored rows and the published SDK enums), and
the six `smp://…@smpN.simplexonflux.com` host-and-key pairs in `Presets.hs`, which are members of
`allPresetServers` because previously issued short links encode the host they were created on.
`presetDomains` lost `.simplexonflux.com` with the operator.

**The brand artwork is POPOPX's own.** The iOS app icon is the single master
(`apps/ios/Shared/Assets.xcassets/AppIcon.appiconset/1024.png`, purple `#7A2BBE → #3D0A6D`) and every
derived logo, icon, banner, store image and desktop icon is generated from it or redrawn in its palette
(`branding/source-svg/`, `branding/master-logo/`). The last upstream-drawn files in the iOS catalog were
replaced on 2026-11-13: the 3 crowdfunding badge SVGs, the 6 chat-wallpaper sets (18 PNGs) and
`privacy`/`shield` — same names, same pixel sizes, same `Contents.json`, because a wallpaper preset name
is a persisted value and the images are force-unwrapped by name. The wallpapers stay alpha tiles (the
Swift side supplies the background colour), now in purple instead of black. The 376 iOS snapshot baselines
were re-rendered after that: 246 differ from upstream's renders, 130 are byte-equal because those scenes
carry no brand content. What is left of upstream's artwork is measured in
[`ASSETS_LICENSE-POPOPX.md`](./ASSETS_LICENSE-POPOPX.md): UI glyphs that are not brand marks, third-party
logos, and the documentation/site images whose bulk removal is still unruled.

### Interfaces that other code reads

The FFI library is `libpopopx` (a dual lookup for `libsimplex*` is retained); the Node/Python/Rust
SDK mirrors, the MCP tool outputs (`popopx_name`) and the `.popopx-mcp` data directory moved with
them; the SMP dependency is `github.com/popopx-chat/popopxmq`, and so did the names this fork's CI publishes into its own releases (`popopx-chat-*`, `popopx-desktop-*`) with the four readers of the same value: the desktop updater's `githubAssetName` literals, its GitHub API repository, and the doc and website URLs.
The user-facing download links that named an APK asset now point at the Google Play listing (this fork
publishes no APK), and `{{ release }}` — which was never defined in `website/src`, so every desktop and
CLI link on `/downloads` rendered as a relative 404 — is now the `release` member of the site's
`globalConfig`, read as `{% cfg 'release' %}`. See `FORK.md` items 4 and 5.
The libs release assets (`popopx-chat-libs-<os>-<arch>.zip`, `popopx-chat-nodejs-<platform>.node`) and
the repository they are fetched from moved in the same shape — publisher, runtime downloader and the
pinned digest dictionary as one unit, because a half-move downloads upstream's binary and calls it a
success (`FORK.md` item 6).
References to the SMP dependency itself moved second: 144 of the 446 `simplexmq` occurrences became
`popopxmq` — contributor and operator docs, the iOS product/spec layer, the website nav item, and the
`popopxmq` commit link in the iOS version screen (it pointed our own commit at upstream's repository, so
the settings screen 404ed on every build). A reference moved only where the thing resolves in the fork:
the fork renamed `protocol/simplex-messaging.md` → `protocol/popopx-messaging.md` and
`src/Simplex/**` → `src/Popopx/**`, and it has one branch, `master`, so `stable` ref segments moved with
the path. The three test harnesses that download `smp-server`/`xftp-server` now take them from
`popopx-chat/popopxmq`, which publishes no releases: those suites fail with a 404 until it does, by
ruling, rather than testing our core against a server built from another source (`FORK.md` item 7).
The site's own location moved too: `siteLocation` (`website/.eleventy.js`, read by 19 `og:url`/`og:image`
sites as `{% cfg 'siteLocation' %}`; there is no environment override) and `website/markdown_pages.js`,
which declares the same string a second time, plus the two blog feeds' `metadata.url` — all
`https://popopx.chat` → `https://popopx.chat`, because `website/src/CNAME` already read `popopx.chat`.
`onionLocation` next to it stayed upstream's. The rest of the site's own declarations followed in the same
pass — 142 further occurrences in 19 files, because several templates and scripts hardcode the host instead
of reading `cfg`: the generated sitemap `<loc>`, `robots.njk`'s `Sitemap:` line, the llms indexes and
`_data/llms_facts.json` sources, the badge images and store links in `js/channel-preview.jsc`,
`js/directory.jsc`, and both arms of `isCurrentSite` in `js/simplex-lib.jsc` (its `www.simplex.chat` alias
became `www.popopx.chat`, since the predicate asks "is this our own page"). 36 occurrences stayed, and
they are not self-declarations: 31 in `website/langs/*.json` and 2 in `src/_includes/blog_previews/` are
translated display copy and upstream's published announcements whose *labels* still name upstream's app,
and 3 are `…/contact#/?…smp%3A…` links carrying SimpleX Chat Ltd's encoded SMP address — moving only the
host would hand that address out from our page. Those contacts are now **`mailto:chat@popopx.chat`** (the
`/connect-team` redirect target, the two llms links with their label, and 21 translated contact strings);
the 10 upstream *service* subdomains in the site (`directory.`, `app.` with its F-Droid signing
fingerprint, `badges.`, `git.`, `api.`) and the 2 occurrences inside upstream's own 2022 announcement
stayed, so no `https://simplex.chat` remains in the website except those.
The same host then moved everywhere a client or a user follows it: **378 of the 680 remaining occurrences
outside `website/**`, 300 lines / 83 files** — iOS onboarding and chat-item strings, Kotlin onboarding,
the Flatpak AppStream URLs, the badge/directory/support-bot packages, `README.md`, `docs/guide`, `docs/FAQ.md`,
the SDK READMEs and 98 `tests/**` mirrors of those same strings. Two live defects came out of it: the
Python SDK generated group share links as `https://simplex.chat/contact#/?v=2&group=…` (our app handing out
an upstream-hosted link for a group our own relay serves) and the badge site's contact footer had moved its
`href` while its visible label and its test assertion still read `simplex.chat/contact`. Held there: 135
occurrences in the 23 generated `POPOPX Localizations/*.xliff` catalogs (Xcode re-emits them from source;
hand-editing guarantees a drift), 42 links carrying another operator's encoded relay address, and 124 in
upstream's published text (`blog/`, `plans/`, `CHANGELOG.md`, `PRIVACY.md`, `docs/lang/`, `docs/protocol/`).
Because `popopx.chat` does not yet serve the certificate or the `.well-known` files, the apps now name a
domain that cannot answer them: universal links and `autoVerify` will not claim until the SAN covers
`popopx.chat` and our Android signing fingerprints replace upstream's three in `assetlinks.json`.
Ruled 2026-11-13 as use-first-and-record; the gap is written up in `FORK.md`.
The npm and PyPI names in the committed manifests are upstream's on purpose: `packages_release.py
test-names` rewrites them, with `npm:` aliases for the cross-package dependencies, from the
repository variables `NPM_SCOPE` and `PYPI_PROJECT` at publish time — see
[`NODE-PACKAGES-POPOPX.md`](./NODE-PACKAGES-POPOPX.md). Environment variables that third
party tooling may set are read under both spellings (`SIMPLEX_ASSETS`/`POPOPX_ASSETS`,
`SIMPLEX_LIBS_DIR`, `SIMPLEX_ADDON_PATH`).

### What was removed from this repository

`docs/` (592), `website/` (585), `blog/` (248) and `plans/` (229) — 1654 files — are deleted: upstream's
protocol and product documentation, its announcements and roadmap notes, and the simplex.chat site
front-end. They are SimpleX Chat Ltd's editorial content about SimpleX Chat, and this fork publishes no
site from this tree (`popopx.chat` is built and published elsewhere). The one fork-authored file inside
them, `docs/TRADEMARK-POPOPX.md`, was moved out first and is now `TRADEMARK-POPOPX.md` at the root, and
the notices that cited upstream's `docs/TRADEMARK.md` now cite it where it lives instead of at a deleted
path. What the removal takes with it: the six `website/src/.well-known/` files, which were never served
from here but were the only copy of the Android/iOS association work in this tree, and
`.github/workflows/web.yml`, which is now inert (its build step runs `./website/web.sh`) and will fail if
a push touches `images/**` or `PRIVACY.md` until it is removed or repointed. `assets/` was deliberately
**not** removed although it was named in the same ruling: it is a gradle build input
(`-Ppopopx.assets.dir`, checked by `verifyPopopxAssets`), so deleting it would change the artwork
compiled into the Android and desktop apps rather than trim a folder. `README.md` still links about twenty
`./docs/**` and `./blog/**` paths, which are now dead; that cleanup is open.

### Deliberately not changed

Upstream GitHub URLs that name something upstream — `CHANGELOG.md`, `PRIVACY.md` and the other surviving
records — copyright and attribution lines,
the asset licence files, the preset operator
that remains (SimpleX Chat) and its relay addresses, the badge service and directory hosts, the names-service
namespace prefix `simplex_domain_v1` (it is a persisted record and a wire value), the upstream
artwork that is still in the repository (566 files, measured in
`ASSETS_LICENSE-POPOPX.md`) and the 210 desktop snapshot baselines. The dependency references that resolve in `popopxmq`
moved instead (`FORK.md` item 7). Full list with the authority for each:
[`FORK.md`](./FORK.md).

## Template for the first real release

Fields that are decided: the publisher is **POPOPX** and the contact is **chat@popopx.chat**. The
angle-bracket fields below are per-release facts that cannot be known until a release is built and
signed, so they are left as template slots, not as open decisions.

```markdown
## vX.Y.Z — <date>

- upstream commit this build starts from: <commit>
- iOS: <App Store id / build number, signing identity and Team ID>
- Android: <applicationId suffix, signing certificate fingerprint, F-Droid or Play channel>
- servers this release presets, and whose terms the user is asked to accept: <list>
- link domain actually serving this release: `popopx.chat` — certificate SANs present
  (`popopx.chat`, `popopxchat.com`, `www.popopxchat.com`), `/.well-known/assetlinks.json` and
  `/.well-known/apple-app-site-association` reachable over HTTPS with no redirect: <yes/no>
- relay domain `popopx.im`: which hosts are listening, and their fingerprints in the presets: <list>
- every upstream-operated host still named in the build (badge contact, notification preset,
  directory, badge embed, TURN) — each replaced or left, with the reason: <list; the checklist and
  the failure mode of each is in FORK.md "Upstream-operated hosts, and how each one fails">
- publisher and contact address shipped in the app and in these files: POPOPX, chat@popopx.chat
```
