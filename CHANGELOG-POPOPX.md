# POPOPX Chat — release history of this fork

> This file records **this fork**. [`CHANGELOG.md`](./CHANGELOG.md) is upstream's release history and
> is kept unmodified; the versions below are the fork's own state, not upstream releases.

## Unreleased — as of 2026-11-13 (109 commits after the import point `db0768c21`)

Forked from `github.com/simplex-chat/simplex-chat` at `db0768c21` (2026-11-11), code version
`7.1.2.0` (`v7.1.2`). No POPOPX binaries have been published from this repository yet: the store
links, the APK/F-Droid artifacts and the website are all still upstream's or absent, so there is no
"installed version" of this fork to upgrade or downgrade.

Everything below is a **name and identity** change. Nothing in this list alters the protocol, the
cryptography or the wire format.

### File and artefact names — 45 paths moved, 22 held (2026-11-13)

The residue left after the copy, wire and asset tiers was **names**: 67 tracked paths were still spelled
"simplex". None of them could be renamed as documentation, because each is a build input, an installed
path, a generated artifact key or a resolved module — so all 45 that moved went with their readers in one
pass:

- **13 Kotlin files**, each named after the symbol it declares — `PopopxApp.kt`, `PopopxService.kt` (and
  its `platform/` expect/actual pair), `PopopxAPI.kt`, `POPOPXInfo.kt` (+ `.android`/`.desktop`),
  `PopopxNameView.kt`, `SetPopopxDomainView.kt`, `SupportPOPOPXBanner.kt`, `BadgesSupportPopopxView.kt`.
  Four of them were already orphans: the identifiers inside had moved weeks earlier and nothing outside
  the file named them. 339 path citations in this fork's own code maps
  (`apps/multiplatform/{CODE.md,product/**,spec/**}`) moved with the files.
- **2 desktop snapshot baselines**: `SimpleXInfo.PreviewSimpleXInfo-*.png` →
  `POPOPXInfo.PreviewPOPOPXInfo-*.png`. The name is generated (`SnapshotTest.kt:180`
  `"${scene.name}-$theme-font-$scale.png"`), so those two files had been orphaned by the display-copy tier
  and were pointing at nothing.
- **4 desktop launcher artifacts** — `distribute/SimpleX.desktop` and `distribute/simplex.{png,ico,icns}`
  became `popopx.desktop` and `popopx.{png,ico,icns}`, together with their three `iconFile.set(…)` sites
  in `apps/multiplatform/desktop/build.gradle.kts:68,73,82` and the `cp` in
  `scripts/desktop/make-appimage-linux.sh:41`. These are build inputs: a half-move is a desktop bundle
  that silently ships the default icon.
- **2 build-reproduction scripts** and both readers (`.github/workflows/reproduce-schedule.yml`,
  `scripts/ci/android/release-apk.sh`).
- **2 support-bot test mocks**. Their **alias keys stayed** (`"simplex-chat"`, `"@simplex-chat/types"` in
  `vitest.config.ts`): those are the npm names `package.json` installs, so they belong to the published
  packages, not to us. Only the mock paths moved.
- **22 artwork files** — `media-logos/**` and `images/**` together with their `branding/source-svg/`
  mirrors, whose names are the output path with `/` written as `__`, so a half-move would break the
  convention that generated them. All 24 files in this set are POPOPX bytes; only the names were upstream's.

**Deleted, not renamed.** `branding/source-svg/moko__ic_simplex_{dark,light}@4x.svg` are byte-identical to
their already-renamed counterparts `moko__ic_popopx_*@4x.svg` (same md5, `2fb6e266…` and `8e284b07…`) and
nothing reads them, so a rename could only have collided with the file it was meant to become; deletion is
the only move that removes the name.

**Held, with reasons.** 20 paths in `packages/**` (the Node `simplex.{cc,h,js,d.ts}` and the Python module
`src/simplex_chat/**`) — `packages_release.py test-names` rewrites the published names from `NPM_SCOPE`
and `PYPI_PROJECT`, and an installed distribution name is not prose. That is the whole residue: **67 → 20**
paths named "simplex", 45 renamed with their readers and 2 deleted.

This pass also repaired a **compile break on `master`**: the display-copy tier `82130779f` renamed Kotlin
declarations and left 10 import lines naming the old symbols, which made CI's
`:common:compileKotlinDesktop` fail (unresolved `SimpleXTheme` ×7, `SimpleXLinkQRCode` ×2, `SimpleXInfo`
×1). It survived because Kotlin is not compiled on the machines used for this fork's static verification.
`tools/r7/kt_import_gate.py` now replays kotlinc's import resolution over every brand-derived import —
10 findings against `f5a7fd984`, 0 against this tree.

A second class survived the same way: the namespace/link-scheme tier `05dd5a73c` carried its own
shell-level escaping into the replacement text, so seven assertion lines in `AppLinkSchemeTest.kt` read
`windowsSchemeValues(\"popopx\", windowsExe)`. A backslash in code position is a **syntax** error, which
no identifier audit can see — the identifier it looks for is intact. `:common:compileTestKotlinDesktop`
failed, and because that task gates the tests that render them, the run produced **no snapshot artifact
at all**: 34e8b5045 removed the 8 stray backslashes, and `tools/r7/kt_lex_gate.py` (a Kotlin lexer replay,
0 false positives against `db0768c21`) now reports the class.

**The desktop CI harness still addressed the app by its pre-rebrand identity.** The values were moved by
approved tiers; the readers were not, so `scripts/ci/desktop-linux/ui` execed `bin/simplex` from a package
named `popopx`, seeded settings into `$XDG_CONFIG_HOME/simplex` where `Platform.desktop.kt:7` writes
`popopx`, and waited for a window called `SimpleX` while `DesktopApp.kt:130` titles it `POPOPX`;
`smoke-test.sh` OCR-matched a search field whose text became `Search or paste POPOPX link`
(`search_or_paste_popopx_link`) in 6 places. The launcher is now derived from the app directory, and the
two jobs that drive **upstream's** released build pass its config directory and window title explicitly,
so "names an upstream thing keeps upstream's name" still holds there.

**The 210 desktop snapshot baselines were regenerated** by CI run `43397744144`, on the ubuntu runner that
renders them. 20 files changed, and they are the 9 scenes whose pixels carry the brand:
`ChatHelpView`, `ContactConnectionInfoView`, `HelpView`, `NewChatSheet`, `POPOPXInfo`, `QRCode`,
`SettingsView`, `UserAddressView`, `WhatsNewView`. The other 190 are byte-identical to what was committed
before, which is expected rather than suspicious: those scenes contain no brand content, and an unchanged
PNG is not a copied one — every file in the set was written by this run. 18 of the 20 had previously been
identical to upstream's, so they leave the "upstream artwork still in the repository" count
(`ASSETS_LICENSE-POPOPX.md`: 565 → 545). This run also shows what the class above costs: because
`desktopTest` renders the baselines, the artifact only exists if `:common:compileTestKotlinDesktop`
compiles, so a syntax error in one test file ships no baselines at all.

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

**A `@SerialName` is a wire value, and one tier renamed only the Kotlin side of it.** `82130779f` made
`OperatorTag` read `@SerialName("popopx") POPOPX`, while the core still encodes the preset operator as
`"simplex"` (`src/Popopx/Chat/Operators.hs` `textEncode OTSimplex = "simplex"` — the same spelling the
generated Python type carries and `server_operators.server_operator_tag` stores). kotlinx threw on the
`serverOperatorConditions` response, `APISerializer.fallbackResult` reported it as `* serverOperatorConditions`,
the conditions list stayed empty and onboarding's **Accept button was never enabled** — the desktop smoke test
stopped exactly there. No identifier audit can see this class: the string is intact on both sides, only the
two sides disagree. `PopopxAPI.kt` decodes `"simplex"` again, with its two readers, and the entry keeps
upstream's name because it names upstream's operator; the copy shown for that operator stays POPOPX-branded
by ruling. The other five brand-derived tags in the API model were checked against their emitters and match
(`popopx` TLD, `POPOPX` agent error, `popopxName`, `popopxLink`, `popopxLinks`, `popopxDomainNotReady`).
The same run left **7 test mirrors** behind from earlier tiers: 5 still named the Windows ProgId
`SimpleX.simplexchat` after `WINDOWS_PROG_ID_PREFIX` moved to `"POPOPX."`, and 2 case-variant link fixtures
disagreed with their producers in opposite directions — `PopopxChat:/badge/…` had renamed a scheme that is
held as `simplexchat`, while `SimpleX:/a#…` still spelled the connection scheme that moved to `popopx` in
`05dd5a73c`.

**The class now has a guard that fails if it comes back.** `ServerOperatorsWireTest.kt` decodes the
`conditions` value of a real `serverOperatorConditions` response — taken byte for byte from the failed run's
`app.log` — with the app's own `json`, and asserts both `operatorTag`s read `OperatorTag.SIMPLEX`. Renaming
either side alone turns it red, and the payload is not hand-written, so it cannot drift from the core.
Run `43405919477` on this repository proved both: `:common:desktopTest` was green with
`ServerOperatorsWireTest` listed as 1 test / 0 failures, and the smoke test reported "onboarding reached the
chat list" with `wait "Talk to someone"` resolving on screen — the button that the broken tag had kept
disabled.

**The last desktop launcher line moved with it.** `distribute/popopx.desktop`, which `make-appimage-linux.sh`
installs as `com.popopxchat.popopx.desktop`, still read `Name=SimpleX Chat` and `/opt/simplex/…` although our
package installs the launcher as `/opt/popopx/bin/popopx`. The deb is unaffected either way: `make-deb-linux.sh`
rewrites the desktop entry jpackage generates for it, and only `Name=` survives into the AppImage menu. Held,
with the reason in the file: in `scripts/flatpak/com.popopxchat.popopx.desktop`, `Exec=simplex %U` names the
command the Flatpak manifest declares (that manifest is not here) and `StartupWMClass=simplex-chat` has to match
the class the running app sets, which nothing in this repository controls.

### The reproduce chain was pointed at this repository (2026-11-13)

`.github/workflows/reproduce-schedule.yml` was the mirror image of the desktop-CI finding: a workflow
whose *checkout* names one tree cannot call a *script* renamed in another. It pulled
`simplex-chat/simplex-chat` at the latest upstream tag, then ran `scripts/popopx-chat-reproduce-builds.sh`,
which exists only in our tree; `|| :` swallowed the missing file, the `_sha256sums` test found nothing, and
both scheduled runs (43143049757, 43353616675) went red having compiled nothing. Everything that names
*which build is being proven* moved as one unit: the releases API and the checkout repository,
`repo_name`/`repo` in the script, the three release-asset names (matched against our producers
`build.yml:556`, `:612`, `:638`), the CLI the container builds (`popopx-chat.cabal:607`), the two package
paths (`build-cli-deb.sh:12`, `make-deb-linux.sh:57`), and the sums directory in the workflow, which is now
read out of the script instead of written a second time. One of those was invisible to every token sweep:
`mv release/main/*imple*.AppImage` is a glob, not a word, and would have matched nothing in our build - it
now derives the file the way `build.yml:629` does.

The job is inert until this fork publishes a release (`releases/latest` answers 404), so the first step
detects the empty tag and skips; that is what it does nightly now. Held by the usual rule: the Android
script's `REPO_NAME`/`REPO`/`SIMPLEX_REPO`/`SIMPLEX_KEY`, which name upstream's signed APK, because that is
what it verifies. `FORK.md` §"Reproducing a build" documents how both are run and records that
`STATUS_POPOPX_WEBHOOK_URL/_USER/_PASS` are not configured here, so a red run is the only signal.

### What was removed from this repository

`docs/` (592), `website/` (585), `blog/` (248) and `plans/` (229) — 1654 files — are deleted: upstream's
protocol and product documentation, its announcements and roadmap notes, and the simplex.chat site
front-end. They are SimpleX Chat Ltd's editorial content about SimpleX Chat, and this fork publishes no
site from this tree (`popopx.chat` is built and published elsewhere). The one fork-authored file inside
them, `docs/TRADEMARK-POPOPX.md`, was moved out first and is now `TRADEMARK-POPOPX.md` at the root, and
the notices that cited upstream's `docs/TRADEMARK.md` now cite it where it lives instead of at a deleted
path. What the removal took with it: the six `website/src/.well-known/` files, which were never served
from here but were the only copy of the Android/iOS association work in this tree — serving them now means
authoring them in the site's own repository. `.github/workflows/web.yml` was deleted with them: its build
step ran `./website/web.sh` and its Deploy step was gated to upstream's repository name, so from this
repository it could only ever go red, and the five members of the `website` CI scope went with it
(`build.yml` PR paths, `SCOPE_CHANGES` in `scripts/ci/packages_release.py`, `scripts/ci/scope-tests.sh`,
its test, and the `#### website` section of `scripts/ci/README.md`). `assets/` was deliberately
**not** removed although it was named in the same ruling: it is a gradle build input
(`-Ppopopx.assets.dir`, checked by `verifyPopopxAssets`), so deleting it would change the artwork
compiled into the Android and desktop apps rather than trim a folder.

`README.md` was repaired in the same pass — 81 lines removed, 25 rewritten, and **0** relative links into
`docs/`, `blog/`, `website/` or `plans/` survive the change (measured). What went: the whole
`News and updates` blog list (15 links) and the `User guide` section, the translated-README row, and the
`popopx.chat` sub-path pointers that 404 on our own host (`/blog/`, `/feed.rss`, `/llms.txt`,
`/llms/agents.md`, `/docs/simplex.md`, `/why.md`). Sentences that carried only a dead pointer were deleted;
sentences that carried information were de-linked; the two protocol references that still have a live
target now name the `protocol/` documents of `popopxmq` (`popopx-messaging.md`, `agent-protocol.md`,
`xftp.md`, `pqdr.md`). Two rewrites are copy, not link surgery, and are listed for review: the FAQ item
whose answer was only a blog link was dropped and its list renumbered, and "Security contact" now says the
fork publishes no security policy yet and points at the in-app team contact (upstream's `docs/SECURITY.md`
describes *their* intake process and is not ours to claim).
`packages/popopx-chat-nodejs/README.md`'s `./docs/*.md` links were left alone — they
are package-relative typedoc files, not the root `docs/`.

The citations the removal left behind were then swept: **26 files / 178 occurrences** named a deleted path
(`README.md` excluded, repaired above). Each was fixed by what it actually refers to, not by one rule. The
badge service's wire protocol had no specification left in the fork, so this fork **wrote one** —
`apps/popopx-badge-service/protocol/badges-rpc.md`, derived from the implementation with a file:line for every
spelling, covering only the RPC layer because the HTTP checkout is already documented in the service README.
Its eight readers were repointed with it (`README.md` ×3, `src/Popopx/Chat/Badges/Ledger.hs:182`,
`src/Popopx/Chat/Library/Commands.hs:6363`, `tests/BadgeTests.hs:949` and `:1072`, and the `#commands` anchor
line 284 uses). Citations to documents that are upstream's and that this fork will never publish
(the `plans/badges-codes/*` designs, `docs/CONTRIBUTING.md`, `docs/rfcs/2026-03-28-group-identity-binding.md`,
`docs/protocol/badges-rpc.schema.json`) now name `simplex-chat@db0768c21` — the commit this fork imported from,
in which each blob is verified to exist here — rather than a branch that can move or a local path that is gone.
Two live instructions were moved into the fork instead: `apps/ios/CODE.md` and `apps/multiplatform/CODE.md`
required plans to be stored in the root `plans/`, and they now require `apps/ios/plans/` and
`apps/multiplatform/plans/`, the convention `apps/popopx-support-bot/plans/` already uses. `CLAUDE.md` was
deleted (its four `@`-imports pointed at three deleted files, nothing referenced it, and the fork does not use
it). `scripts/docs/frame-guide-images.py` was deleted with the directory: it wrote into `docs/guide/images`,
had no CI consumer, and its sibling `scripts/docs/frame-ios-renders.py` is not in this repository. 25 inert
`website/**` patterns and their 7 orphaned comments left `.gitignore` (measured: 0 tracked paths matched them).
The two items that sweep deliberately left for a ruling are ruled and executed. `PRIVACY-POPOPX.md` no
longer cites deleted local paths: upstream's `docs/SIMPLEX.md` and `docs/SECURITY.md` are published
**byte-for-byte** in the fork's site directory — `popopx.chat/docs/SIMPLEX.md` (9356 bytes, blob
`e24275d6`) and `popopx.chat/docs/SECURITY.md` (6633, blob `73c050c1`), each `cmp`-verified against
`db0768c21` — beside `docs/UPSTREAM-DISCLAIMER.md`, which states what they are: upstream's texts, not
POPOPX's, carrying SimpleX Chat Ltd's report address `chat@simplex.chat` and its OpenPGP fingerprint, with
internal links (`/docs/lang/…`, `../blog/…`) that resolve upstream and not here. `PRIVACY-POPOPX.md` cites
those URLs and keeps the fact visible that **POPOPX publishes no security policy of its own** and that a
POPOPX report goes to `chat@popopx.chat`. Nothing in this repository deploys that directory — it is not a
checkout of anything here — so the two paths 404 until the fork's host serves them, the same pending item
as the certificate SAN and the `.well-known` files (`FORK.md`); the citation is therefore also given
against the pinned upstream blob, which is verifiable today.
`AGPL-COMPLIANCE-POPOPX.md` was **re-measured, not relinked** — its four figures are claims about this tree:
`simplexChatCore` 37 → **32 occurrences / 15 files**, `simplex-chat-nodejs` 17 → **23** (4 of them the
`-<platform>` asset name), `simplex-chat-libs` 100 → **6** (2 asset names), "322 tracked paths whose name
contains simplex" → **67**. The last one changed *class*, which is why the file now says so: 250 of the 322
were `website/`, `plans/`, `docs/` and blog paths that the removal took, so what survives is 20 package
paths (the Python module `src/simplex_chat/**`, whose declared name `simplex-chat` is rewritten at publish
time by `packages_release.py test-names`), 21 under `apps/` (13 Kotlin type/file names, the 4 desktop
launcher artifacts wired in `desktop/build.gradle.kts:68,73,82`, 2 snapshot baselines, 2 jest mocks), 24
artwork files and 2 scripts — and those 24 were provenance-checked as well: **all** are POPOPX bytes (11
differ from the same path in `db0768c21`, 13 have no upstream counterpart), i.e. our pictures under
upstream filenames, which is trademark ruling #43 rather than an AGPL item. The §3 blocker naming
`website/src/img/**` and "the 93 tracked files under `assets/**`" closed with measurements: `assets/**` is
now 89 tracked files, and of the 103 tracked files under `assets/**` plus root `images/**` exactly **4**
still carry upstream's bytes — `assets/ASSETS_LICENSE.md` (a notice, kept) and the 3 third-party audit
logos that `README.md:26` links, none of them a SimpleX mark.

**A second class the citation sweep could not see: markdown links.** 17 links in 4 files still pointed
into `docs/` and `blog/` - `PRIVACY.md` ×12, `apps/popopx-directory-service/README.md` ×3,
`bots/README.md` ×1, `media-logos/README.md` ×1. They survived the 26-file sweep because that pass looked
for *citations* (a path named in prose, retargetable at a pinned upstream blob) and these are link
targets, and `PRIVACY.md` was in the held-as-records list. Attributed before touching them: resolving
every relative link in 202 tracked `.md` files against **both** trees gives 17/17 broken here and 0/17
broken upstream, so all 17 are ours to repair, not inherited. Ruled per kind, not per file: **9
de-linked** - the seven terminology links (`/docs/GLOSSARY.md`, `/docs/DIRECTORY.md`), `bots/README.md`'s
"POPOPX Chat CLI" and `media-logos/README.md`'s "blog posts"; the sentence and its claim stay, only the
dead pointer goes. **4 sentences deleted** - the ones whose whole purpose was to point at something *SimpleX
Chat Ltd published* (two Trail of Bits announcements, the iOS push-notification post, the transparency
report), because that promise is not ours to restate without its source; the seventeenth, the
reproduce-builds sentence at `PRIVACY.md:189`, had already gone in `687f7273f`. **3 repointed inside `apps/popopx-directory-service/README.md`** - two to `#building` and
`#2-registering-a-group`, the sections of that same README that actually contain what they promised, and the
third ("see DIRECTORY.md for full details") to nothing, since it sat inside the section it named. Measured
after: **0** links into `docs/` or `blog/` remain, and no `### ` heading was renamed, so the two new anchors
resolve. Re-measured with the same script afterwards: 254 relative links in the 202 tracked `.md` files still
do not resolve, **0** of them into `docs/` or `blog/` - 238 are the generated `packages/*/docs/**` typedoc files
(`../util.ts#L79` targets, identically broken upstream) and 16 are prose citations, 7 of which are equally broken
in the upstream checkout. The remaining 9 are ours and were **not** in this ruling's scope, so they are recorded
rather than touched: 5 in `packages/popopx-chat-mcp/spec/*.md` still say `../../simplex-chat-nodejs/src/…` after
that package's directory moved, 2 in `apps/ios/spec/client/chat-list.md` cite `GetStakeBanner.swift`, deleted with
the operator cards, and 2 are `-?[a-z0-9]` inside a code span - a regex, not a link.

### Deliberately not changed

Upstream GitHub URLs that name something upstream — `CHANGELOG.md`, `PRIVACY.md` and the other surviving
records — copyright and attribution lines,
the asset licence files, the preset operator
that remains (SimpleX Chat) and its relay addresses, the badge service and directory hosts, the names-service
namespace prefix `simplex_domain_v1` (it is a persisted record and a wire value), the upstream
artwork that is still in the repository (545 files, measured in
`ASSETS_LICENSE-POPOPX.md`). The dependency references that resolve in `popopxmq`
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
