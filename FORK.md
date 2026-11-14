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
   decision, not a wire one. The three places that then still named upstream's APK were
   `docs/REPRODUCE.md` (it verifies *their* signed build), `scripts/ci/android/release-apk.sh` with
   `.github/workflows/android-emu.yml:490` (the emulator smoke test installs that same upstream APK), and
   `plans/website-file-page-implementation.md:167` (a historical plan). Only the emulator test is left:
   `docs/**` and `plans/**` went with the upstream editorial tree (`9996634ee`), and reproducing a build
   is described under "Obtaining the source".
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

10. **Upstream's editorial content was removed** (2026-11-13, `9996634ee`) — `docs/` (592), `website/`
    (585), `blog/` (248) and `plans/` (229) are deleted, 1654 files: SimpleX Chat Ltd's protocol and
    product documentation, announcements, roadmap notes and the simplex.chat site front-end. None of it
    describes POPOPX, and the fork's own notices already disclaimed it. The one fork-authored file that
    lived inside them, `docs/TRADEMARK-POPOPX.md`, was moved out first and is now `TRADEMARK-POPOPX.md`
    at the root; every citation of it in `NOTICE`, `README.md`, `AGPL-COMPLIANCE-POPOPX.md` and
    `ASSETS_LICENSE-POPOPX.md` follows. `assets/` was deliberately NOT removed with them: it is a gradle
    build input (`-Ppopopx.assets.dir`, verified by `verifyPopopxAssets`), so deleting it would change
    the artwork compiled into the Android and desktop apps rather than trim prose.

    Two things died with it and neither is a branding question. `.github/workflows/web.yml` was deleted
    the same day — its build step ran `./website/web.sh` and its Deploy step was gated to
    `github.repository == 'simplex-chat/simplex-chat'`, so from this fork it could only ever have gone red —
    and the five members of the `website` CI scope moved with it (`build.yml` PR paths, `SCOPE_CHANGES` in
    `scripts/ci/packages_release.py`, `scripts/ci/scope-tests.sh`, its test, `scripts/ci/README.md`). The
    six `website/src/.well-known/` files were this tree's only copy of the Android/iOS association work;
    they were never served from here, and the work now belongs to the site's own repository (see "Link
    claims are inert").

    **One upstream document came back, deliberately** (2026-11-13): `docs/SIMPLEX.md` and
    `docs/SECURITY.md` are published in the fork's site directory as
    `popopx.chat/docs/{SIMPLEX,SECURITY}.md`, byte-for-byte from `db0768c21` (`cmp`-verified; blobs
    `e24275d6` and `73c050c1`), so that `PRIVACY-POPOPX.md` can point at the protocol design and at the
    audit history instead of at a path this repository deleted. Serving them unchanged is the point — an
    edited copy would be our claim about someone else's security process — which is why they sit next to
    `docs/UPSTREAM-DISCLAIMER.md`, which says in three lines what they are not: not POPOPX's policy, not
    our report address (`SECURITY.md` routes issues to `chat@simplex.chat` and names SimpleX Chat Ltd's
    OpenPGP key fingerprint), and not self-contained (its `/docs/lang/…` and `../blog/…` links resolve on
    simplex.chat, not here). POPOPX's own contact — `chat@popopx.chat`, and "no security policy published"
    — is stated beside them in `PRIVACY-POPOPX.md`, not inside them. This does not change item 10: the
    remaining ~1650 files stay removed, and nothing in this repository deploys the site directory, so the
    two paths are inert until `popopx.chat` serves them like the `.well-known` files above.

Every modification carries the date of the commit that made it; `git log` is the
authoritative per-file record.

11. **File and artefact names were the last identifier tier** (2026-11-13) — 45 of the 67 tracked paths
    still named "simplex" moved with their readers (13 Kotlin files, 2 desktop snapshot baselines, 4
    desktop launcher artifacts, 2 build-reproduction scripts + 2 CI readers, 2 support-bot test mocks,
    22 artwork files with their `branding/source-svg/` mirrors); 20 of the 67 are held and 2 were deleted: the held 20 are installed package paths
(`packages_release.py test-names` owns those names); the 2 deleted were
`branding/source-svg/moko__ic_simplex_{dark,light}@4x.svg`, byte-identical duplicates of their
already-renamed counterparts and read by nothing, so a rename could only have collided with the file
each was meant to become That pass also repaired a compile break this fork shipped with:
    the display-copy tier `82130779f` renamed Kotlin declarations and left their 10 imports behind, so
    `:common:compileKotlinDesktop` failed in CI and no desktop artifact could be produced. Nothing on
    this machine compiles Kotlin, which is why it took a CI run to find it; `kt_import_gate.py` in the
    tooling directory is the standing gate for that class.

12. **The crowdfunding funnel is deleted** (restored 2026-11-13, deleted 2026-11-14 by the ruling 删除众筹) — it
    had been made symmetric by restoring the iOS view with copy naming the round as SimpleX Chat Ltd's. The later
    ruling is that this fork does not promote the round at all, so the attribution went with the funnel rather than
    surviving as a label: `GetStakeBanner.swift` and `views/chatlist/GetStakeBanner.kt`, the banner-slot arms on both
    platforms, the settings sections, the persisted banner preferences, the What's-new `FeatureView` entries with the
    helpers that only they called (`crowdfundingAvailable()`, `CrowdfundingLayout`, `getStakeSlides`,
    `fullScreenOnClick`, `Modifier.pinchZoom()`), the 16 slide artwork files and every string that advertised it are
    gone. What **stays** is the `investor` badge *type*: `BadgeType.investor` and its wire tag are emitted by
    `src/Popopx/Chat/Badges.hs` for badges the badge service has already issued, so removing them would falsify
    history instead of promoting anything. The deletion went in four commits: commit 1 the funnel, commit 2 the badge
    layer's promotion (`BadgeInvestorOffer` on both platforms, `BadgeLevel.investorOffer`, `WEFUNDER_URL`, the 3
    `badges_investor_offer_*` keys, the name-sale footnote, and `badge_invested` reworded from an investment claim to
    "%s has the POPOPX investor badge."), commit 3 the badge service's invest panel (`apps/popopx-badge-service/web`:
    `src/crowdfunding.ts` whole, `investPanel`/`investSentence`/`withInvest` and the `perk` field of 5 screens' options,
    the Wefunder wordmark's path data, the `.invest` CSS, the worker's `PRECACHE` entry and the regenerated
    `public/index.html` shell + its content-derived build hash), commit 4 the docs mirrors (both
    `apps/*/spec/client/chat-list.md` section 10s retitled to **Chat List Banners** — they also carried the surviving
    banner chain, dismissal prefs and card chrome, so they were trimmed rather than deleted — and the `CODE.md` /
    `impact.md` / `product/**` / Source Files rows retargeted to `SupportPOPOPXBanner.*`). The follow-up that kept the
    capabilities (ruling 功能保留) repaired the badge-web brand pin, whose master paths were one directory level shallow
    for the **compiled** test location — so the byte-for-byte guard had never actually run — widened `embed.ts`
    `trustedHost` to `popopx.chat`/`*.popopx.chat` while keeping `simplex.chat`, which required a `npm run build` because
    the build hash covers the module bytes, and deleted the MCP README's funding section, the support bot's livestream
    line and the Android CI brief's card instruction. `apps/popopx-badge-service/web` is now **525 tests / 0 failures**. The
    type keeps its name, its wire tag and its images. `CHANGELOG.md`, this file and the flatpak `<release>` notes keep
    the round as record, and the blog URL slugs that contain the word "crowdfunding" are upstream's post addresses,
    not a funnel.
    The one hazard the delete created, and its repair: the two platforms declared the shared banner chrome in
    **different** files — iOS in `SupportPOPOPXBanner.swift`, Kotlin in the doomed `GetStakeBanner.kt` — so removing the
    Kotlin file left `commonMain` calling symbols that no longer existed, and no gate on this machine could see it (the
    Swift build was green because iOS had no such asymmetry, the badge-web suite has no Kotlin, and Android is static
    verification only). The three declarations, `Modifier.bannerCard`, `BannerDismissButton` and `gradientBrush`, now
    live in `apps/multiplatform/…/views/badges/SupportPOPOPXBanner.kt`, the file that owns them, as they always did on
    iOS. Lesson for the next delete: read the doomed file's *other* exports, not only the symbols the plan named.
    Maintenance hazard, found the hard way: `apps/ios/POPOPX.xcodeproj` uses classic groups (0
    `PBXFileSystemSynchronizedRootGroup`), so a Swift file needs four `project.pbxproj` entries — build file, file
    reference, group child, Sources phase — and a scripted edit that *replaces* its anchor line instead of inserting
    after it removes a source file from the target while its Sources entry dangles. The module then fails with
    cross-file `cannot find type` errors that name nothing the script touched. After any `project.pbxproj` edit,
    `git diff --numstat` on that file must read `N 0`.

## What was deliberately NOT changed

- **Copyright and attribution.** The `author` / `maintainer` / `copyright` fields of
  `popopx-chat.cabal`, the three `Copyright (C) 2026 SimpleX Chat Ltd` asset-licence lines
  and the ~78 company-name references in the privacy, licence and legal texts are retained
  verbatim, as AGPL-3.0 §7 requires (and §4 forbids removing). This codebase carries no
  per-file copyright headers, so there is nothing else to preserve.
- **Upstream GitHub URLs**, and the dependency references that are not ours to claim — *this bullet
  describes the state before 2026-11-13: the `docs/**`, `plans/**`, `blog/**` and `website/**` paths named
  below were removed by item 10 above, so what remains of this class is the `CHANGELOG.md` /
  `PRIVACY.md` records, the upstream URLs quoted inside surviving texts, and the `dist-newstyle/**`
  paths that captured commands quote. They are kept here because they are the record of why each
  identifier was held at the time.*
  **Citation convention adopted 2026-11-13 for that class:** when a surviving file must still point at one of
  those deleted upstream documents, it cites the pinned blob `simplex-chat@db0768c21` (in URLs,
  `https://github.com/simplex-chat/simplex-chat/blob/db0768c21/<path>`) — the commit this fork imported from,
  at which each of the eight cited paths is verified present in this repository's own history. A branch name
  (`stable`, `master`) was not used for these because four of the eight do not exist on `stable` at all, and a
  relative path was not used because the file is gone. The exception is the badge service's own RPC protocol:
  that specification is now **ours** at `apps/popopx-badge-service/protocol/badges-rpc.md`, with the one
  remaining live instruction that named a deleted directory (`apps/ios/CODE.md`, `apps/multiplatform/CODE.md`)
  moved to the fork's own per-app `plans/` folders instead.
  The paths held were: `docs/protocol/**`
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
  contact is `chat@popopx.chat`. One thing is still missing on that host and it is a silent-to-loud
  failure to fix there, not in code: neither `.well-known/apple-app-site-association` nor
  `.well-known/assetlinks.json` is served — both answered 404 again when re-measured 2026-11-14, while the
  TLS name mismatch this bullet used to report was retired the day before (see the certificate item under
  "Link claims are inert" below). So universal
  links and `autoVerify` cannot be claimed by an installed app yet, link unescaping falls back to the
  scheme, and the dependency's served `assetlinks.json` stopped being the mismatched half of the pair on
  2026-11-14 — its fingerprints are ours now (see "the other half of the pair" under the signing identity
  below). It still verifies nothing, for a different reason: this fork publishes no APK. The relay presets and the directory/badge service
  still name infrastructure SimpleX Chat Ltd operates, because a preset needs their key material and
  `popopx.im` relays have none published yet. `chat@popopx.chat` is likewise not reachable until that host
  serves mail or forwards.
- **This fork publishes no Android APK.** `.github/workflows/build.yml` builds and signs nothing for
  Android; `scripts/ci/android/release-apk.sh` downloads **upstream's** release APK and verifies
  SimpleX's signing certificate, which is what the emulator smoke test installs. The gradle output
  names (`popopx-arm64-v8a.apk`, `popopx-armv7a.apk`) are therefore only local artifacts. Ruled
  2026-11-13: the documentation links point at the stores (item 5 above) — but note that our Play
  listing is itself not published yet, so those links 404 *for us* until it is.
- **The bug-report address is ours.** Every holder of `github.com/simplex-chat/simplex-chat/issues`
  moved to our repository on 2026-11-13, once our own tracker existed (`fork:false`, issues enabled) -
  the earlier hold was written as "until our own is set up". Holders: the desktop startup dialog
  (`ISSUES_URL`, which Linux opens and Windows draws as the link text), the `bugtracker` URL in the
  AppImage AppStream and in the flatpak metainfo, the F-Droid fastlane description, the mcp README,
  and `bugs.url` / `[project.urls] Issues` in the package manifests. Moved the same day, in the pass that
  followed (`homepage` / `repository.directory` / `repository.url` of those same manifests, 21 lines in 11
  files - `test-names` leaves all three fields alone, and its alias pair reads only `name` and
  `dependencies`, so moving them cannot desynchronise `unreleased_pins()`). The front page and the store
  metadata then went through the same test: both AppStream `<url type="donation">` elements were
  **deleted** (the element has no label slot, so a store renders upstream's channel as "donate to POPOPX"),
  the donation section keeps upstream's own text and wallets under a heading that names them as theirs, and
  the F-Droid, TestFlight, downloads, release, Reddit and Mastodon badges were removed - see
  `CHANGELOG-POPOPX.md`, "The front page stops recruiting, funding or identifying for SimpleX Chat Ltd".
  Still upstream's on purpose: the flatpak release-tag links, and any link whose target only exists in
  upstream's history. The three holders that pass measured but did not touch - because it grepped badge
  strings instead of the class - are executed now: `README.md`'s "We publish our updates and releases via:"
  over five of their accounts and the "our SimpleX address / we reply within 24 hours / joining our team"
  promises, and `fastlane/metadata/android/en-US/full_description.txt`'s "Follow us on" plus the group link
  that joined **their** user group from our store listing. `src/Popopx/Chat/Help.hs`'s "Follow our updates:"
  block was deleted (and the claim that it reached the iOS archives was retracted - the module is not linked
  into them). What is *held* is the contact itself, at four holders marked `HOLD (task #66)`:
  `popopxTeamURL`, `popopxTeamUri`, `ChatHelp.swift`'s "connect to POPOPX Chat developers." and
  `Help.hs`'s "Connect to POPOPX Chat developers … type /simplex". They name our developers and reach
  SimpleX Chat Ltd's relay, server key and contact hash, and they can only move once POPOPX runs a relay and
  mints its own contact - which is the same condition already written above `adminContactReq`.
  The one entry point of this class that was **deleted** rather than held is "Follow POPOPX Network News"
  (`popopxNewsURL` / `popopxNewsUri` -> `popopx:/c#grcfG3ulVI4…?h=smp18.simplex.im`): the team contact
  self-heals the day POPOPX mints its own address, whereas subscribing this fork's users to another
  company's announcement feed is not a state to re-word into - when POPOPX has its own channel it gets its
  own row. 20 sites in 18 files: both rows, both URL constants, and the key in the 7 moko locale files,
  the 4 `.lproj` catalogs and the 5 `.xcloc` translation units. The `ic_bigtop_updates` image stays - 11
  other call sites read it for channels generally.
  Still awaiting a ruling, found after it: `README.md:64-68` claims upstream's two user groups exist for questions
  "about POPOPX Chat only", and `full_description.txt:21-23` states in the first person that "**our**
  servers do not have access to this information" about relays this fork does not operate.
  `SUPPORT_EMAIL` is already `chat@popopx.chat`, which is itself not yet reachable (first bullet) - which is
  why the front page routes the fork's own questions to the GitHub issue tracker instead.
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
- **Link claims are inert, for several independent reasons.** All of them must clear in the same change. The
  count used to be three; the list grew as the items below were measured, and the certificate reason was
  retired on 2026-11-13.
  - *This tree publishes nothing, and since 2026-11-13 it holds nothing to publish.* The only site build it
    carried was `.github/workflows/web.yml`, whose Deploy step was gated
    `if: github.repository == 'simplex-chat/simplex-chat'`, so this repository never published a site even
    when `website/` was in the tree; `website/src/CNAME` was read by nothing else. Both were removed on
    2026-11-13 — `website/` by item 10 above (`9996634ee`), the workflow with it — and that removal took
    the six `website/src/.well-known/` files, which were this repository's only copy of the association
    work. What answers on these domains is a different deployment, described next.
  - *Measured 2026-11-12, corrected by a closer look on 2026-11-13.* `popopx.chat` is registered
    (Namecheap) and resolves to `43.129.40.33` — identically from 1.1.1.1, 8.8.8.8 and 9.9.9.9, unlike
    `simplex.chat`, which answers a different address per resolver on this network, so these records are real
    and not injected. Something does answer there, and it is **this fork's own site** — `<title>Home - Popopx
    Chat</title>`, `nginx/1.14.1`, `x-powered-by: PHP/7.2.24`, served for `popopx.chat`, `popopxchat.com` and
    `www.popopxchat.com` alike, over plain HTTP as well as HTTPS. Three consequences, none of them fixable in
    this repository:
    - **The deployed site is not built from this repository.** `website/` was upstream's Eleventy build and
      nothing in CI ever published it (there is no `gh-pages` branch either — `git ls-remote --heads origin`
      returns one ref); it was removed on 2026-11-13. So neither the deleted workflow nor a `CNAME` is the
      lever: publishing `.well-known` means adding two static locations to that nginx **and** authoring the
      two files there, because this tree no longer holds them.
    - **The certificate blocker cleared the day this paragraph was written; the paragraph measured the old
      one.** Two Let's Encrypt YR1 certificates are installed, one per name pair: `CN=popopx.chat` with
      `DNS:popopx.chat, DNS:www.popopx.chat` (`notBefore` 2026-11-13 04:04:23Z, `notAfter` 2027-02-11) and
      `CN=popopxchat.com` with `DNS:popopxchat.com, DNS:www.popopxchat.com` (`notBefore` 04:06:37Z). The
      2026-11-13 ruling asked for a single certificate carrying `popopx.chat`, `popopxchat.com` and
      `www.popopxchat.com`; what is deployed covers the same names as two certificates, which is equivalent
      for the verifier. Re-measured 2026-11-14: `https://popopx.chat/`, `https://www.popopx.chat/` and
      `https://popopxchat.com/` all answer `200` with no name mismatch, so the OS link verifier now completes
      TLS and gets to read bytes — which is the next bullet.
    - **The two association files need exact paths and content types**, not just a directory. Apple fetches
      `https://<domain>/.well-known/apple-app-site-association` — no extension, no trailing slash — so the
      server must map that name to the JSON (or redirect, which Apple follows). This tree no longer holds a
      copy to map: the file lived here as `website/src/.well-known/apple-app-site-association/index.json` and
      left with `website/` (`9996634ee`), so the only shipped copy is the dependency's, which is already named
      the way the protocol wants it — `popopxmq/apps/common/Web/static/.well-known/apple-app-site-association`
      — and `src/Popopx/Messaging/Server/Web.hs` special-cases that extensionless name for `application/json`
      in two places (`:122` for the file server, `:232` for the generated response), because the default would
      be `application/octet-stream`. `assetlinks.json` is stricter: exactly one path, `200`,
      `application/json`, no redirect and no HTML error page, and Android reads it before it will verify
      `autoVerify` for `com.popopxchat.popopx`.
    - **Nothing is published under `/.well-known/` on either name** — each returns the PHP application's 404
      HTML page. Re-measured 2026-11-14: `apple-app-site-association`, `assetlinks.json` on `popopx.chat` and
      `assetlinks.json` on `www.popopx.chat` are all `404` while `/` on the same three hosts is `200`, so this
      is a missing location, not a missing certificate. The copies that existed here
      (`website/src/.well-known/`, six files) were never served from this tree either, and left with it on
      2026-11-13. The dependency's copies are served only by a relay, and no relay answers HTTPS at all yet
      (`https://smp1.popopx.im/.well-known/assetlinks.json` failed to connect on the same measurement), so
      nothing is being mis-served either. That is the whole reason the misattribution described under the
      signing identity below is still latent rather than live.
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
  - *The signing identity is ours — ruled 2026-11-14: `PDBA6XRBQT`.* That closes the question this item was
    waiting on, and it turns out to need **no identifier change**: the association work already names us.
    Measured before this edit, `PDBA6XRBQT` is 9 occurrences in 6 files here — `KeyChain.swift:13` (the
    keychain access group), `project.pbxproj:2137` and `:2201` (`DEVELOPMENT_TEAM`),
    `build-desktop-mac.sh:8,10` and `sign-libs-mac.sh:6` (both defaulting to it, both overridable by
    `APPLE_POPOPX_NOTARIZATION_TEAM_ID`), and the two records — and 3 files in the dependency: the AASA,
    `src/Popopx/Messaging/Notifications/Server/Push/APNS.hs:215` (`appTeamId`) and
    `Push/testpush.sh:3` (`TEAM_ID`). The earlier "three places across two files" counted this tree alone, at
    a moment when its own AASA copy was still in it. All of them must agree with whatever certificate actually
    signs the distribution. A wrong one fails silently: keychain sharing and universal links stop working, and
    only on device.
  - *The other half of the pair — closed 2026-11-14 by minting our own Android key (option 1c).* The
    dependency's `apps/common/Web/static/.well-known/assetlinks.json` carried **our** `package_name`
    `com.popopxchat.popopx` with **SimpleX Chat Ltd's three** signing-certificate fingerprints — the copy
    that `website/src/.well-known/assetlinks.json` used to be, and the one that goes live the first time a
    relay serves web. `autoVerify` matches the package name *and* the digest of the certificate that signed
    the installed app, so upstream's three could never verify our package while ours was absent. All three
    are replaced by the one fingerprint of a key pair this fork owns:

        3A:7F:67:1A:8F:21:D3:93:6D:46:78:DE:1D:4F:0E:29:C3:DF:9E:35:2A:CB:26:0D:02:6A:DD:0C:17:FA:4C:CB

    The material lives outside both repositories, in `/Users/elliot/popopx-chat/keys/` (directory 0700, each
    file 0600): `popopx-android-release.key` (PKCS#1 PEM, `Proc-Type: 4,ENCRYPTED`),
    `popopx-android-release.crt`, `popopx-android.password`. No secret is tracked and the password was never
    printed. Subject `/CN=com.popopxchat.popopx/OU=POPOPX Chat Android Release/C=US`, RSA 2048,
    `sha256WithRSAEncryption`, serial `8E22C76424902B78`, no X509v3 extensions, valid 2026-11-14 →
    2054-04-01. The digest was derived twice — `openssl x509 -fingerprint -sha256`, and SHA-256 over the
    certificate's own DER decoded from the PEM body — and both give it. A third route on this machine is a
    trap worth naming: LibreSSL 3.3.6 `openssl x509 -outform der` writes **0 bytes and exits 0**, and the
    digest of that is the empty-input constant `e3b0c442…`, so it "agrees" with itself while proving nothing.
    Converting for gradle keeps this same fingerprint, because it is a property of the certificate and not of
    the container — checked by round-tripping it: `openssl pkcs12 -export -inkey … -in … -name
    popopx-release -out popopx-release.p12`, and the certificate read back out of that container has the
    digest above (this LibreSSL rejects the `file:` scheme on `-passin`/`-passout` with "Error reading
    password from BIO", so pass it as `env:`). Gradle then needs a `signingConfig` reading
    `storeFile`/`storePassword`/`keyAlias = "popopx-release"`. Nothing reads
    it yet — `apps/android/build.gradle.kts` carries no `signingConfig` at all (measured the same day), which
    is the "this fork publishes no APK" item above. **Losing this key pair loses the signature**: an update
    signed with a different certificate is refused, and with Play App Signing the upload key can be rotated
    but this is the digest F-Droid and any sideloaded install trust — back it up off this machine before the
    first release (#56), where Play App Signing's and F-Droid's own fingerprints join this same array.
    Ship route: popopxmq `25d7213d` = tag `popopx-pin-4`, our pin moved with it (`cabal.project:24`,
    `scripts/nix/sha256map.nix:2`). The hash came from the command that file's own generator calls
    (`nix-prefetch-git --fetch-submodules`, per `scripts/nix/update-sha256.awk`), and the method was proven
    first by reproducing pin-3's stored
    hash byte-for-byte; `diff -rq` between the two fetched trees is **exactly one file** — this one — so no
    Haskell source moved and the iOS archives stay current. Ordering constraint: that pin is resolvable from
    GitHub only once the dependency commit and tag are pushed, so **our pin-bump commit must not land
    upstream before theirs**. Two holders of upstream's `3C:52:C4:FD:…:AD:85` are **held**:
    `scripts/ci/android/release-apk.sh:10` and `scripts/popopx-chat-reproduce-builds-android.sh:4` verify
    *upstream's* APK, so for them that digest is the correct value.
    iOS push, by contrast, is already clean: `appName`/`TOPIC` name our
    bundle id, `appTeamId` names our team, and the signing key comes from the `APNS_KEY_FILE`/`APNS_KEY_ID`
    environment, so no upstream push credential is embedded anywhere.
  - *The CI signing scripts no longer name it.* Ruled 2026-11-13: the identity comes from
    `APPLE_POPOPX_SIGNING_IDENTITY` and the team id from `APPLE_POPOPX_NOTARIZATION_TEAM_ID`, so no Apple
    identity for another company is asserted by our build — `build-desktop-mac.sh` and `sign-libs-mac.sh`
    wrote `Developer ID Application: SimpleX Chat Ltd (5NN7GUYB6T)` and `team_id=5NN7GUYB6T` into the desktop
    build, and `prepare-keychain-mac.sh` imported SimpleX Chat Ltd's `.cer`/`.p12`/`.pem` by name. The team id
    is **forced to `PDBA6XRBQT`** (ruled the same day, see the bullet above) and is only the default in these
    two scripts, so a secret can still override it; it is an identifier, not a credential. The identity string
    is not derivable here because it embeds our legal entity name as it appears on the Developer ID certificate.
    With `APPLE_POPOPX_SIGNING_IDENTITY` unset the two macOS desktop steps are skipped and say so, which is the
    whole point of the "block nothing" ruling, and it does not extend to the libraries: notarizing them is not
    optional, because `popopx-chat-libs` releases feed the Node.js add-on and the npm packages, so a release
    tag without Apple material goes red at `Build library` rather than publishing an unnotarized `libsimplex`.
    Measured: that repository has no releases at all yet.
  - *The installer was pointed at this repository.* Ruled 2026-11-13: `install.sh` set
    `APP_NAME="simplex-chat"`, and that variable is the **download value**, not a label — `:82`/`:84` compose
    `https://github.com/$APP_NAME/$APP_NAME/releases/$DOWNLOAD/$APP_NAME-$PLATFORM` from it and `:7` names the
    installed binary, so our own script fetched upstream's binary from upstream's releases and installed it as
    `simplex-chat`; the README then told the reader to run `popopx-chat`, which it had not installed. It now
    fetches `popopx-chat-*`, matching what our CI publishes (`build.yml:1012`/`:1019`/`:1423`, and
    `popopx-chat-ubuntu-22_04-x86_64` from the matrix at `:280`/`:281` with the derivation at `:556`), and
    `README.md:224` pipes the script from `popopx-chat/popopx-chat@master` — the only branch this repository
    has. Held: `$HOME/.simplex/simplex.agent.db` at `:43`, upstream's v0 agent database, which names something
    that really is upstream's. Not retargeted here: the Darwin branch at `:20`-`:24` asks for `macos-x86-64`
    only, so Apple Silicon gets the Intel build — an upstream gap in a path that no release exists to test
    yet. Everything in this item is verified statically; end to end it stays unverifiable until #56 publishes.
- **`popopx.chat` is owned and serving, and is now the ruled link domain.** Ruled 2026-11-13:
  `popopx.chat` for links and the site, `popopx.im` for relays. `website/src/CNAME` had already moved to
  `popopx.chat` before `website/` was removed — nothing read it but `website/.eleventy.js:471`, which
  published it to the site root, so removing it changes nothing that was ever served. What still makes link
  handling inert is one thing, not two: the certificate now covers the domain — measured 2026-11-13, the leaf
  is `CN=popopx.chat` (Let's Encrypt) with `DNS:popopx.chat, DNS:www.popopx.chat` in the SAN — while
  `/.well-known/apple-app-site-association`, `/.well-known/assetlinks.json` and the `www` copy of the first all
  answer 404.
- **Our own relay hosts are now claimed by the iOS app (`*.popopx.im`, 2026-11-14, #33 item 2 executed).**
  `apps/ios/POPOPX (iOS).entitlements` went from 5 to 7 `applinks` rows: `applinks:*.popopx.im` and its
  `?mode=developer` twin, added as the pair `*.simplex.im` already carries (`tools/r7/r33_2_applinks.py`).
  The claim is inert by design — no `*.popopx.im` host serves HTTPS yet (`https://smp1.popopx.im/.well-known/assetlinks.json`
  failed to connect on the same day's measurement) — and it is inert in the direction that cannot
  misattribute anything, because the wildcard names hosts under our own registration.
  `applinks:*.simplex.im` and its developer twin are **held** by the same ruling: they are inert too, since
  those hosts' `apple-app-site-association` names upstream's appID and therefore opens our app for nobody, so
  deleting them would remove a capability from nobody while making the diff harder to review. Android is
  **not** touched: an intent filter takes no wildcard host, so `AndroidManifest.xml:94-109` would have to
  enumerate every relay name we operate — upstream's list is exactly that, 16 explicit `smpN.simplex.im` rows
  plus `popopx.chat` — and the same no-HTTPS measurement leaves it inert there as well. Two things this
  machine cannot verify and does not claim: the entitlement is checked against the provisioning profile when
  the app is archived (`CODE_SIGN_STYLE = Automatic` in all 12 build configurations of
  `POPOPX.xcodeproj/project.pbxproj`, the file referenced from it 4 times), so the Associated Domains
  capability must be registered for team `PDBA6XRBQT` by whoever signs; and `plutil -lint` only proves the
  plist parses.
- **`/blog/` and `/docs/` are not served, so the in-app blog links were deleted, not repointed.** Measured
  2026-11-14: all 27 distinct `popopx.chat/blog/…` URLs the apps carried answer 404 (27/27, no timeouts).
  Ruling 「删除博客链接」: 121 occurrences in 42 files went — the What's-new per-version "read the post"
  links, the transport-isolation description's inline link, the badges "read more in our blog" row and 39
  flatpak release URLs. Four occurrences remain in code and resources, plus the prose of the two records that
  describe this decision (`CHANGELOG-POPOPX.md`, this file):
  - the metainfo `<screenshots><image>` — ruled **keep** on 2026-11-14 (「它是图片不是链接，不删掉」); it is an
    image reference, not a link, and deleting it would leave AppStream's only screenshot empty;
  - the fastlane store description and the two `contentModerationPostLink` holders (a paired value with 8
    readers) — both still **awaiting ruling** (A6 and A5).
  Everything naming `simplex.chat/blog` is held: that host serves upstream's articles, and the `.xcloc`
  catalogues are not a build input.
- **`popopx.chat/docs` is a ruled hold (2026-11-14: 「先不动，保留」).** The 31 holders this pass counted stay
  although measured 2026-11-14 all 13 distinct `popopx.chat/docs…` paths answer 404 (13/13, no timeouts):
  8 are fixtures in `scripts/ios/test_localizations.py`, 3 each in `PRIVACY-POPOPX.md` and
  `CHANGELOG-POPOPX.md`, 4 in the directory service pair (2 in `Directory/Service.hs`, 2 in its
  `tests/Bots/DirectoryTests.hs` mirror) and 1 each in `FORK.md`, `bots/README.md`, the metainfo
  `<url type="translate">` and the ten in-app help views that carry the same link in iOS and Kotlin
  (`AddContactLearnMore`, `UserAddressLearnMore`, `RTCServers`, `IncognitoView`/`IncognitoHelp`,
  `ProtocolServersView`). Those figures are the tree as this pass measured it; these two records naming the
  URL raises the live count above 31. A later ruling can move the holders as one unit; nothing here claims the
  paths resolve.
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
| shared directory listing | the page that read it, `website/src/js/directory.jsc:1` (`/data/`, filter at `:149`), was deleted with `website/` on 2026-11-13; the server half is `apps/popopx-directory-service` and `src/Directory/Listing.hs:94` still records the pair | **silent-empty**: the fetch fails and the page shows no results |
| badge embed allow-list | `apps/popopx-badge-service/web/src/embed.ts:53` | **silent**: the widget refuses an origin outside `simplex.chat`/`.simplex.chat` and renders blank |
| badge purchase deep links | `apps/multiplatform/common/src/commonMain/kotlin/chat/popopx/common/views/badges/BadgeStore.kt:53-54` | **visible**: leaves the app into `badges.simplex.chat` — an upstream-branded page under a POPOPX label |
| ICE/STUN/TURN defaults | `packages/popopx-chat-webrtc/src/call.ts:355-359` (`stun.simplex.im`, `turn.simplex.im`; the TURN line carries a username and a literal credential) | **visible**: calls fail to connect. Used only when the user configured none (`AppSettings.hs:45` `webrtcICEServers`), and the credential is upstream's to revoke |

One entry in that list is not a host+key pair and could be fixed without any infrastructure, so it was:
the discovery document `website/src/.well-known/simplex.json` carried five SimpleX Chat Ltd channels, groups
and contacts (`smp4/smp10/smp18.simplex.im` links titled "SimpleX Network News", "SimpleX Crowdfunding News",
"SimpleX users group", "Ask SimpleX Team", "SimpleX Directory"). The *path* is a protocol value — [upstream
`docs/protocol/web-discovery.md:99` and `:218`](https://github.com/simplex-chat/simplex-chat/blob/stable/docs/protocol/web-discovery.md)
register `simplex.json` as an RFC 8615 URI suffix, and a client follows exactly that name — so the file kept
its name; the *entries* are not a protocol value, and publishing
another operator's identities under our own domain claims them as ours. The three arrays are empty until this
fork operates relays and can author its own addresses. The file itself went with `website/` on 2026-11-13, so
authoring it is now a task on the host that serves the domain, not in this tree.

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

### Reproducing a build

Two scripts check a published release against this repository; neither one is part of building it:

    ./scripts/popopx-chat-reproduce-builds.sh <tag>           # CLI, deb, AppImage (Linux x86_64)
    ./scripts/popopx-chat-reproduce-builds-android.sh <tag>   # APK

Both clone `<tag>` from `github.com/popopx-chat/popopx-chat`, rebuild it inside Docker from
`Dockerfile.build`, download the same file from that release's assets and compare the sha256. They
need `git`, `docker` and `curl`. The desktop script also writes the `cabal.project.local` the build
depends on (`package direct-sqlcipher` with `flags: +openssl`), and on a full match it leaves the
checksums in `<tag>-popopx-chat/_sha256sums`.

The Android script reproduces upstream's APK, not ours: `REPO_NAME`, `REPO`, `SIMPLEX_REPO` and
`SIMPLEX_KEY` (the signing certificate fingerprint) name upstream's artefacts, which is why they keep
upstream's spelling, and this fork publishes no APK. It raises `kernel.pid_max` through sudo or doas,
builds `aarch64` and `armv7a` (override with `ARCHES`), and compares the rebuilt APK once
`apksigcopier` has copied upstream's signature onto it. No workflow calls it; it is run by hand.

`.github/workflows/reproduce-schedule.yml` runs the desktop script nightly at 02:00 and on dispatch,
against this repository's own latest release. This repository has published no release, so the job
prints `No published release to reproduce - skipping.` and finishes green. Before 2026-11-13 the same
workflow checked out upstream's tree and then called `scripts/popopx-chat-reproduce-builds.sh`, a path
that exists only in our tree, so each nightly run failed.

The last step posts the failure to `STATUS_POPOPX_WEBHOOK_URL` with `STATUS_POPOPX_WEBHOOK_USER` and
`STATUS_POPOPX_WEBHOOK_PASS`. None of the three is configured on this repository (`gh secret list`
returned nothing on 2026-11-13), so a reproduction that fails is visible as a red run and nowhere
else.
