# Fork and modification notice

> This file is the "prominent notice of modification" required by
> [AGPL-3.0 §5c](./LICENSE) and AGPL-3.0 §7 attribution note. It is not part of the
> AGPL text and does not modify it.
>
> **Files consolidated 2026-11-25.** `POPOPX-REBRAND-PLAN.md` was deleted, `CHANGELOG-POPOPX.md` became
> [`CHANGELOG.md`](./CHANGELOG.md), and `ASSETS_LICENSE-POPOPX.md` / `AGPL-COMPLIANCE-POPOPX.md` became
> [`ASSETS_LICENSE.md`](./ASSETS_LICENSE.md) and [`AGPL-COMPLIANCE.md`](./AGPL-COMPLIANCE.md). Dated
> sentences below that name an old path record the tree as it stood on their own date; they are not live
> pointers. The one figure that has since moved is re-measured in `CHANGELOG.md`'s header.

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
   (`make-deb-linux.sh:58` → `popopx_${ARCH}.deb`, `desktop/build.gradle.kts:72,81,123,125` →
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
   resolve a release published under these names, because `popopx-chat-libs` had no releases when this was
   written. How many it has now is a query, not a fact to remember: `gh api
   repos/popopx-chat/popopx-chat-libs/releases --jq '.[] | .tag_name + " " + (.assets | length | tostring)'`
   read **three** tags on 2026-11-16 (tip `012ec8373`) — `core-7.1.0.20` with 6 assets, `nodejs-addon-cce06d8`
   with 5, `core-7.1.0.14` with 6. Two of those tags existed when this item was written, one asset each, and
   the gap they left was this script's refusal, which the rule still explains correctly: `release_status`
   (`:251`) answers `published` from the tag alone, while `release_digests` (`:228`) returns nothing unless
   *every* asset of `LIBS_ASSETS` (`:101`, 6 names) / `ADDON_ASSETS` (`:117`, 5) is present, so `download_asset`
   (`:961`) exits "is not published with a digest" and `prepare` cannot pin from a half-published release.
   Measured against those two lists on 2026-11-16 the published sets are complete — the same 6 zip names and
   5 `.node` names, so the refusal no longer fires for these tags and #116 is what closed it. The refusal
   itself is the correct behaviour, not a second bug, and it is what will fire on the next partial release.

7. **References to the SMP dependency** (2026-11-13) — the denominator and the moved count are commands,
   because the tree they were read from moved under them: `git grep -o 'simplexmq' 8e6d62f19^ | wc -l` reads
   **444** and `git show 8e6d62f19 -U0 --format='' | grep '^-' | grep -o 'simplexmq' | wc -l` reads **143**,
   where this item printed 446 and 144. Re-measured on tip `012ec8373` the spelling survives as **24**
   occurrences in **8** files (`git grep -o 'simplexmq' | wc -l`; `-l` for the files): 18 of the 24 are the
   records, the plan and the legal texts that hold upstream's name on purpose, the other 6 are
   `packages/popopx-chat-mcp/**` plus one literal in `src/Popopx/Chat/Remote/Protocol.hs`. This paragraph
   quotes the spelling it counts, so a recount taken after reading it runs higher.
   What the tier moved: the contributor instructions (`docs/CONTRIBUTING.md` and its `pl` translation,
   `docs/contributing/PROJECT.md`, `scripts/ci/README.md`, `scripts/ci/desktop-linux/README.md`), the
   operator and product docs a POPOPX reader follows (`README.md`, `docs/SERVER.md`,
   `docs/XFTP-SERVER.md`, `docs/CLI.md`, `docs/SIMPLEX.md`, `docs/SECURITY.md` and their
   `pl`/`fr`/`cs` translations), the iOS product/spec layer (`apps/ios/product/glossary.md`,
   `apps/ios/product/rules.md`, `apps/ios/spec/architecture.md`), the website's nav item, and one link
   that was simply broken: the settings screen rendered "popopxmq: v… (commit)" hyperlinked into
   **upstream's** commit list, so every build of that screen 404ed on our own version information — the line
   is `:40` at `8e6d62f19^` (`git show 8e6d62f19^:apps/ios/Shared/Views/UserSettings/VersionView.swift`) and
   `:41` on this tip, where the same string names `popopx-chat/popopxmq`. Of the paths just listed every `docs/**` and `website/**` one
   is gone — item 10 deleted those trees the same day — so the surviving readers are `README.md`,
   `scripts/ci/**` and `apps/ios/{product,spec}/**` (`git ls-files docs/ | wc -l` read 0 until item 14
   re-imported `docs/CLI.md`, which is one more reader of the `popopxmq` name); that is why the
   counts above are commands rather than this list.
   A reference moved only where the same thing exists in `popopxmq`, which is not string equality: the
   fork renamed its own files, so `protocol/simplex-messaging.md` is `protocol/popopx-messaging.md` and
   `src/Simplex/**` is `src/Popopx/**`; and because the fork has one branch (`master`, its
   `origin/HEAD`), every `blob/stable/` and `raw/…/stable/` ref segment had to move with the path or the
   link 404s on a file that is there. The `#anchor` links moved only where the fork's README still
   produces that slug (all 8 do). Checked over HTTP: the moved URLs return 200.
   The three test harnesses that download a server for their suites
   (`packages/popopx-chat-mcp/test/e2e/smpServer.ts`, `packages/popopx-chat-nodejs/tests/smpServer.ts`,
   `apps/popopx-calculator-bot/test/smpServer.ts`) were ruled the same day to take it from
   `popopx-chat/popopxmq`. That ruling said so in the present tense when `popopxmq` published **no** releases
   and the suites therefore failed with a 404; `0ae51df42` (2026-11-14) repinned all three to `v7.1.0.17`,
   whose 25 assets exist, so the URLs resolve and the 404-is-our-gap sentence no longer describes anything.
   Each site now says what a 404 means *there*: our own asset went missing - which is not a reason to fall
   back to upstream's binary, and cannot pass silently, because the download is checked against a pinned
   sha256 dictionary at `:12`/`:128` of the mcp harness. That is the intended shape: a harness must not test
   our core against a server built from someone else's source and report a pass, and a digest mismatch is
   loud. The operator
   docs are the opposite case, where the download is an instruction to a third party run against a
   server that has to work today — see "The server artifacts" below.

8. **The site host where a client or a user follows it** (2026-11-13) — the tier moved 378 of the remaining
   `https://simplex.chat` occurrences outside `website/**` to `https://popopx.chat`, and the shape of the work
   is one command wide: `git show d7635b53d -U0 --format=''` adds the new host on **301 lines** in
   **84 files** once `website/**` is excluded, and the denominator it worked from is `git grep -o
   'https://simplex\.chat' d7635b53d^ -- ':!website' | wc -l` = **679** — one below the 680 this item first
   printed. In detail: iOS Swift (`Views/Onboarding`, `Views/Chat/ChatItem`, the snapshot harness's
   markdown fixtures), Kotlin multiplatform onboarding, `scripts/flatpak/com.popopxchat.popopx.metainfo.xml`
   (AppStream `homepage`/`help`/`donations` URLs a store and `appstreamcli` read), `scripts/ios`, the
   badge/directory/support-bot packages, `README.md`, `docs/guide`, `docs/FAQ.md`, the Node/Python SDK
   READMEs and the MCP card fixtures, and 98 occurrences in `tests/**` that mirror those same strings.
   Two of them were live defects: `packages/popopx-chat-python` built group share links as
   `https://simplex.chat/contact#/?v=2&group=…` — our app emitting an upstream-hosted link for a group our
   own relay serves, with the test mirrors agreeing with it — and `apps/popopx-badge-service/web` renders
   a contact footer whose visible label had to move with its `href` (`web/test/main.test.ts:483` asserts
   the label, so the pair moved together).
   Held, 302 occurrences as this tier measured them: 135 in the 23 generated `apps/ios/POPOPX Localizations/*.xliff` catalogs
   (regenerated from source strings by Xcode — hand-editing them guarantees a drift the next build
   undoes), 42 carrying an encoded SMP/XFTP address or key, 124 in upstream's published text (`blog/`,
   `plans/`, `CHANGELOG.md`, `PRIVACY.md`, `docs/lang/`, `docs/protocol/`), 1 more protocol-document match.
   That composition does not survive item 10, which deleted `blog/`, `plans/` and `docs/` the same day, so the
   residue is a command rather than a memory: `git grep -o 'https://simplex\.chat' -- ':!website' | wc -l`
   read **306** when this paragraph was written and reads **162** on tip `012ec8373` — 135 of them still the
   catalogs above, the other 27 in 13 files: 12 in `CHANGELOG.md` and 2 in `PRIVACY.md` (upstream's own
   records, the only survivors of the 124), 4 in these two records quoting the old spelling to explain the
   ruling, 6 in the app strings that reach upstream's moderation article and upstream-hosted contact/group
   examples (`ChatTypes.swift`, `CIFileView.kt`, `GroupLinkView.swift`, both `UserAddressView`s,
   `ContactConnectionInfoView.kt`), and 1 each in `README.md`, `fastlane/…/full_description.txt` and
   `.github/ISSUE_TEMPLATE/question.yml`. The held *classes* are unchanged — a host a user or a crawler
   follows moves; upstream's own text, an upstream payload and a regenerated catalog do not — so the number
   fell because the files left, not because a hold was overridden, and a recount taken on a later tip moves
   whenever these records rewrite the sentence that quotes the spelling. The same command on the
   parent of `d7635b53d` reads 679, which is the denominator this item moves 378 of; the bare and
   subdomain forms (`simplex.chat`, `directory.simplex.chat`, `chat.simplex.app`) are a separate, **nested**
   count — without the `https://` it reads 298 here against 956 at `d7635b53d^`, and it contains every
   occurrence above, so the 582 first printed beside them is neither additive nor reproducible by that
   command.
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
    at the root; every citation of it in `NOTICE`, `README.md`, `AGPL-COMPLIANCE.md` and
    `ASSETS_LICENSE.md` follows. `assets/` was deliberately NOT removed with them: it is a gradle
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

    **Two upstream documents came back, deliberately** (2026-11-13; re-measured 2026-11-17): the site
    repository publishes them as `https://popopx.chat/docs/simplex.html` and
    `https://popopx.chat/security/`, both answering 200, from `docs/SIMPLEX.md` and `docs/SECURITY.md` as
    they were at the import commit `db0768c21` (blobs `e24275d6` and `73c050c1`). They are no longer
    verbatim: `SECURITY.md` differs by 4 lines — the two Trail of Bits links made absolute when the blog
    left this fork, the report address moved to **chat@popopx.chat**, and the sentence pointing at SimpleX
    Chat Ltd's OpenPGP key replaced by "POPOPX publishes no encryption key for this address" — and
    `SIMPLEX.md` by 2, both its whitepaper link naming `stable` where upstream's text says `master`. The
    last two of the first group are assertions about *this* build: left upstream's, a security report would
    have gone to SimpleX Chat Ltd and the page would claim a key we do not hold. Everything else in them is
    upstream's, including both assessments, and `docs/UPSTREAM-DISCLAIMER.md` says which parts are. What an
    earlier note here called "not self-contained" has also gone the other way: the build rewrites the
    language row's `/docs/lang/fr/SIMPLEX.md` targets to `/docs/lang/fr/simplex.html`, which publish.
    Re-derive with `diff <(git -C <fork> show db0768c21:docs/SECURITY.md) <site>/docs/SECURITY.md`. This does
    not change item 10: its 1654 deleted files stay deleted, and nothing in this repository deploys them.

Every modification carries the date of the commit that made it; `git log` is the
authoritative per-file record.

11. **File and artefact names were the last identifier tier** (2026-11-13) — 45 of the 67 tracked paths
    still named "simplex" moved with their readers (13 Kotlin files, 2 desktop snapshot baselines, 4
    desktop launcher artifacts, 2 build-reproduction scripts + 2 CI readers, 2 support-bot test mocks,
    22 artwork files with their `branding/source-svg/` mirrors); 20 of the 67 were held and 2 were deleted. The
    held set is a command, not a memory: `git ls-files | grep -i simplex | wc -l` reads **18** on tip
    `012ec8373`, and all 18 are installed package paths — 16 under `packages/popopx-chat-python/src/simplex_chat/`
    plus `packages/popopx-chat-nodejs/cpp/simplex.{cc,h}` — so the hold is intact and the two that fell away
    fell to a later tier rather than to drift: `5bddc33ae` moved the SDK facade
    `packages/popopx-chat-nodejs/src/simplex.{d.ts,js}` to `popopx.{d.ts,js}` the day after this item was
    written (`packages_release.py test-names` owns the 18 that remain); the 2 deleted were
`branding/source-svg/moko__ic_simplex_{dark,light}@4x.svg`, byte-identical duplicates of their
already-renamed counterparts and read by nothing, so a rename could only have collided with the file
each was meant to become. That pass also repaired a compile break this fork shipped with:
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

13. **The link scheme's stale mirrors, and the repository the relay image is built from** (2026-11-16, rulings
    `simplex:/ 更新为 popopx:/` and 执行 A1+A2+A4+A6 + #112 A + #113 仅 tools.ts 两处) - five live texts still said
    `simplex:/` although the app has emitted and parsed only `popopx:/` since `05dd5a73c` (`82ac26bec`). One of
    the five was not prose: `scripts/relay/entrypoint.py:40` decides which token in the relay's own output *is*
    the address, so with the old prefix it never matched, `/out/relay-address.txt` was never written, and every
    start repeated the one-shot capture and logged `relay address not captured; will retry next start`. Checking
    which prefix that scan should take meant reading the build, and the build was broken on its own:
    `scripts/relay/Dockerfile` fetched `github.com/simplex-chat/simplex-chat` at `88df79d1e` - an upstream commit
    whose tree declares `executable simplex-chat` in `simplex-chat.cabal` - while asking cabal for
    `exe:popopx-chat`, because `5fd42d793` renamed the executable and the `COPY` target and left the remote and
    `CHAT_REF` untouched. The relay image has therefore been unbuildable since 2026-11-12, and
    `docker-compose.yaml:8` defaulted `CHAT_REF` to the same commit, so neither path worked. Both now name this
    repository and are pinned by `a51c59355` — the commit that made the repair, which an earlier revision of
    this sentence mistook for the pin itself. The pin is read, not
    remembered: `grep -n 'CHAT_REF' scripts/relay/Dockerfile` shows `967cd6e88ae1e88eaa4078ecc4fa9aa07f4fe317`
    at `:6`, and `docker-compose.yaml:8` defaults to the same SHA. Stated
    as statically verified, because that is all it was: no `docker build` was run here, and the checks were that
    `executable popopx-chat` and `flag client_postgres` are declared at that commit, that
    `scripts/cabal.project.local.linux` exists there, and that all ten switches `entrypoint.py` passes are
    parsed there. The pin was first read from the locally recorded `origin/master` because neither egress path
    reached GitHub; it was confirmed against the remote the same day, when direct egress answered
    `967cd6e88ae1e88eaa4078ecc4fa9aa07f4fe317 refs/heads/master`, so at that moment the pin was the live master tip.
    It has not been the tip since the next push, and this sentence now gives the command instead of a SHA:
    measured 2026-11-16 on tip `012ec8373`, `git rev-list --count 967cd6e88..HEAD` reads **16** and
    `git rev-list --count origin/master..HEAD` reads **0** — the branch is pushed, so the gap is a two-command
    fact in any clone rather than something to trust here. An earlier revision of this paragraph named
    `d591bc28e` and "twelve commits ahead", which was true for the few hours between two pushes; that is the
    trap, not the number. The pin is an ancestor that still
    fetches and still declares everything the entrypoint reads, and bumping it to a CI-validated commit stays a
    deployment decision - whoever advances a deployment moves `Dockerfile:6` and `docker-compose.yaml:8` together.

    The naming tier that ran after it moved the phrase "SimpleX link", 59 of its 64 occurrences — both numbers
    are commands on the commits, not memory: `git grep -o 'SimpleX link' f2a262472^ | wc -l` reads **64**, and
    `for c in f2a262472 5932bccee bb6a7c4ca a77fe94dd 57b8a0bb3; do git show $c -U0 --format='' | grep '^-'; done | grep -o 'SimpleX link' | wc -l`
    reads **59**. The residue is smaller than 64 − 59 because three of those five were this fork's own record
    quoting the phrase to explain the ruling: `git grep -o 'SimpleX link' a77fe94dd` lists 5, and the same
    command with `':!CHANGELOG.md'` added leaves the 2 that are genuinely held — `CHANGELOG.md:205` and
    `scripts/flatpak/com.popopxchat.popopx.metainfo.xml:344`, both upstream release notes this fork does not
    author (today the whole family reads 10 in 4 files, 8 of them records quoting it). The five commits:
    `f2a262472` the
    directory service's group notice with its three verbatim test mirrors and five hspec titles, `5932bccee` the
    MCP server's schema text and the sentence it throws, `bb6a7c4ca` the generated bot-API and SDK docs,
    `a77fe94dd` the two clients' product and spec documents, `57b8a0bb3` the name-format examples and the field
    name the plan still called `simplex_name`. Two mechanisms outlived this tier:
    - an hspec title is a CI selector, but the selector lives in a pull request body, not in a file -
      `scripts/ci/run-tests.sh:15` turns each `ci-tests` line into one `-m` argument - so titles naming this
      app's feature move, and no title in `tests/**` now names an upstream service. The comment that
      asserted otherwise at `tests/Test.hs:80` was itself a stale mirror: it claimed four "SimpleX
      &lt;service&gt;" titles below it were kept deliberately, while `968907a2d` had already renamed all four
      on 2026-11-15, so the comment now states the mechanism instead of the count that had gone stale -
      the kind of note that only surfaces when a tier has to ask what pins a title;
    - `testGenerate` in `tests/APIDocs.hs:153` writes the generated file *before* asserting the new text against
      the old, so one `-m` run on `Bot API docs` is both the generator and the comparator. It read 2 failures
      while the stale lines were being rewritten and 17 of 17 after, which is the proof that the outputs match
      their producers; no generated line was typed by hand, and `typedoc` was re-run rather than editing
      `docs/api.Class.ChatApi.md`.

14. **One upstream document came back** (2026-11-16, ruling 将上游 stable 的这份文档 fork 过来) —
    `popopxmq`'s relay pages carry a footer row linking the terminal manual at `docs/CLI.md`, which item 10
    deleted here, so the manual was re-imported from upstream's `stable` and sanitized rather than left
    pointing outside this fork. The same four-case rule as item 2 moved **47** occurrences over **31** lines;
    **10** remain and all are deliberate — 4 in the provenance block this item added above the title (it names
    upstream on purpose) and 6 in the three `docs/lang/{fr,cs,pl}/CLI.md` links, which now point back to
    upstream `stable` because this fork republishes only the English text. Values the copy asserted were taken
    from their producers, not from the sweep: the executable `popopx-chat` (`install.sh:5` `APP_NAME`, written
    to `~/.local/bin`), the data directory `~/.popopx` and the prefix `popopx_v1` (`Terminal/Main.hs:26,27`),
    the databases `popopx_v1_chat.db` / `popopx_v1_agent.db` (`Options/SQLite.hs:35,73,78` joining prefix and
    suffix) — which also corrects the imported claim that `-d alice` creates `alice_v1_chat.db`: `-d` replaces
    the whole prefix, so it creates `alice_chat.db`. Six links that were wrong upstream are wrong no longer:
    `overview-tjr.md#encryption-primitives-used` and `agent-protocol.md#connection-request` named headings that
    do not exist in `popopxmq` (now `protocol/security.md#encryption-primitives` and
    `#accept-and-reject-connection-requests`), `src/Simplex/Chat/Options.hs#L42` predates the presets moving to
    `src/Popopx/Chat/Terminal.hs#L47`, `tree/stable` and the two `git checkout stable` named a branch this fork
    does not have, and the `curl -o- …/simplex-chat/stable/install.sh | bash` pair now reads
    `raw.githubusercontent.com/popopx-chat/popopx-chat/master/install.sh` (3519 bytes at `master`). Two
    table-of-contents rows anchored to sections the file does not contain — `#access-chat-history`, whose
    section upstream deleted, and `…-via-tor-beta`, which never matched the heading — were fixed, so all 15
    in-page anchors resolve. The sentence "Three default SMP servers are hosted on Linode" now reads "operated
    by the upstream project": the presets at `Terminal.hs:47-49` are `smp{4,5,6}.simplex.im` and this fork runs
    no server, which is the rule under "Upstream-operated hosts" below.
    What this item does **not** touch: `install.sh:43` still tests `$HOME/.simplex/simplex.agent.db`, and that
    is not residue. The block is the v0-to-v1 upgrade guard — it looks for a *legacy upstream* database at
    upstream's pre-v1 location and warns before installing with a clean one, so renaming the path there turns
    the guard into a no-op that never fires. It is the same class of hold as the `simplex_xor_md5_combine`
    function name in `popopxmq`.

15. **This fork's own artwork was relicensed; the names and upstream's art were not** (2026-11-16) —
    `ASSETS_LICENSE.md` now licenses the images whose bytes this fork wrote under
    **AGPL-3.0-only, or at the recipient's option CC0-1.0**, and the 双轨制 ruling it
    replaced — code free, brand *and artwork* proprietary, on the Firefox/WordPress/SimpleX model — is
    withdrawn. The reason is not generosity, it is that the old position could not be held: a fork
    conveys one work, pictures included, because the icons are embedded in the binaries and the vector
    masters that draw them are the corresponding source a server owes its users under §13, so keeping
    one part of that work behind a permission requirement is a further restriction on the rights §11
    grants. §10 forbids adding such a restriction, and §12 ("No Surrender of Others' Freedom") does not
    let us keep one by writing it down: it says a contradicting condition excuses nobody from the
    licence's own terms, and that anyone who cannot satisfy both at once may not convey at all. The
    names are untouched, because trade mark law is outside the copyright licence altogether:
    `TRADEMARK-POPOPX.md` still binds a fork in full, and taking our wordmark bytes under CC0 licenses
    the drawing, never the mark, so a downstream build may not present them as identifying our product
    or our approval. Upstream's artwork is untouched for
    the opposite reason — this fork has nothing to grant: the files the recipe measures
    byte-identical to `db0768c21` stay SimpleX Chat Ltd's under `assets/ASSETS_LICENSE.md`, whose term
    withholding them from a distribution that is not unmodified SimpleX Chat no document here reaches,
    so the standing advice that a fork must not carry them is unchanged. What *is* changed is the second
    half of that advice: a fork is still compelled to rebrand, still cannot carry upstream's drawings,
    and is no longer compelled by this repository's copyright to redraw ours. Updated in the same pass,
    each carrying the date and what it used to say: `ASSETS_LICENSE.md` (the grant itself, first),
    `NOTICE`, `README.md` (top blockquote and §License), `TRADEMARK-POPOPX.md`,
    `AGPL-COMPLIANCE.md` §4 as a dated correction rather than a deletion, this file's
    §"Trademarks and artwork", `branding/source-svg/README.md` and `CHANGELOG.md`.

16. **The dependency's branded key-derivation labels were reverted, and the dependency then reverted
    that revert; a labelled build is a build that does not talk to the network** (2026-11-17; the brand is
    back at the commit this repository pins now, so read the counts below as measurements of `cb9e1aa3`
    rather than of `13df615d`) — `popopxmq` carried ten HKDF and BBS domain separators
    spelled `POPOPX…`: two in `Messaging/Crypto.hs` (`sbcInit`, `sbcHkdf` — every SMP frame after the
    handshake, because `Messaging/Transport.hs:846 blockEncryption` runs it on the server side and the
    client side), four in `Messaging/Crypto/Ratchet.hs` (`pqX3dh` ×2, `rootKdf`, `chainKdf` — the
    end-to-end ratchet, so peer-to-peer as well as client-to-server), two in
    `Messaging/Crypto/ShortLink.hs` (`contactShortLinkKdf`, `invShortLinkKdf` — the keys inside links
    already handed to other people), `serviceReqBinding` in `Messaging/Agent.hs:1824`, recomputed by
    the receiving agent before it verifies a signature, and `entitlementBBSHeader` in
    `Messaging/Crypto/Entitlement.hs:92`, the header a badge issuer signs over. A domain separator is
    an input each peer hashes on its own side, so renaming it changes nothing you can see and breaks
    the derivation on the other side. Measured on built bytes rather than on source, before reverting:
    our CLI (2 branded / 0 upstream) against a relay built here (self-reporting
    `v7.1.0.17 / 01278a2`) gives `NEW` then `IDS +mAO 6G80` — queue created, subscribed, invitation
    link handed back — and the *same* CLI against upstream's relay binary (`0 branded / 2 upstream`)
    sends `NEW`, waits 7 s and reports `BROKER {brokerErr=TIMEOUT}` while that relay logs **no** line
    about the connection — it never parsed the block. Run from the other side it inverts: the published
    `-libs` core (upstream's bytes, 0 branded / 2 upstream) times out against a relay we build and
    succeeds against upstream's. Both relays self-report `SMP server v7.1.0.17` and differ only by the
    commit hash they print, so this was never a version gap; each cell bound a fresh random loopback
    port, so no two cells share an address either.
    This is the mechanism under the `BROKER TIMEOUT` family of 2026-11-15 and 2026-11-16, and it
    corrects the verdict recorded in the task list at the time — *"the preset relay's, not our wire"*:
    it is our wire, on the label side. It also explains a test that was green and red for the same
    reason: the e2e harness builds its own relay, so it pairs a branded client with a branded relay and
    passes, while the leg that fetches the published core pairs an unbranded client with that same
    branded relay and fails. Nothing in either repository could have caught this, and that is the
    finding worth keeping: every test derives **both** ends from the same source tree, so a labelled
    build is internally self-consistent and stays green — an absent guard, not a passing one. The ten
    values were upstream's exact bytes in `popopxmq` commit
    `cb9e1aa3cbd8bd2fdb932243ffb9c554b3826bae` = tag `popopx-pin-5`, each derivation site carrying a
    comment saying the literal is a protocol constant. The past tense is a correction, not a style
    choice: `b5bc7577`, an ancestor of the commit this repository now pins, put the `POPOPX` spellings
    back under the ruling that POPOPX is a new system rather than an interoperating upstream client, so
    the same gate re-run at `13df615df7892532b4e83f92d529b96c3d788dea` reads **10 branded / 0 upstream**
    and re-run at `cb9e1aa3` still reads **0** — the two numbers simply changed places. In `src` that commit is 10 deleted lines and 17
    added ones, and the 17 breaks down exactly as the ten rewritten literals plus eight one-line
    comments, one of those comments sitting at the end of a literal line rather than alone
    (`git -C ../popopxmq show cb9e1aa3 -- src | grep '^+' | grep -c '"SimpleX'` → 10, and the same pipe
    with `grep -c -- '-- '` → 8, one line in both counts), and nothing else
    (`git -C ../popopxmq show --numstat --format='' cb9e1aa3 -- src | awk '{a+=$1;d+=$2} END{print a" "d}')`
    → `17 10`) — and that commit also corrects the documents in
    the dependency that had recorded the branded values (`NOTICE`, `protocol/crypto-registry.md`,
    `protocol/agent-protocol.md`, `protocol/xrcp.md`, `protocol/pqdr.md` and two `plans/`), so the spec
    and the code describe the same bytes again. Both gates are scoped to the dependency's `src`, and the
    scoping is load-bearing: the same command without `-- src` counts **33** upstream occurrences
    because 23 of them sit in prose — six files, the four `protocol/*.md` specs and the two `plans/`
    documents, while `NOTICE` names them without the quotes this pattern needs. Within `src` the second
    gate is the positive control that the first is measuring something:

    ```sh
    git -C ../popopxmq grep -o '"POPOPX\(SbChainInit\|SbChain\|X3DH\|VerifyCode\|RootRatchet\|ChainRatchet\|ContactLink\|InvLink\|Service\| badges v1\)"' -- src | wc -l   # 0
    git -C ../popopxmq grep -o '"SimpleX\(SbChainInit\|SbChain\|X3DH\|VerifyCode\|RootRatchet\|ChainRatchet\|ContactLink\|InvLink\|Service\| badges v1\)"' -- src | wc -l   # 10
    ```

    Still branded, and correctly so, because nothing outside our own build reads them: the two
    `POPOPX XFTP … v` strings, printed only by `--version`
    (`src/Popopx/FileTransfer/{Client,Server}/Main.hs`, mirrored by `tests/CLITests.hs:255`), the
    `.popopx` name TLD, and the `adminPopopx`/`complaintsPopopx` keys this server serves. The keys were
    measured again before writing this: they are emitted by `Server/Web.hs:273,280` and read by
    `apps/common/Web/static/index.html:272,290` — a page the same server serves, so both ends of the
    field name are bytes from one build.
    What this item did **not** do at the time was move the pin: `cabal.project:24` named
    `25d7213d…`, because a pin to a commit that has not been pushed would resolve for nobody.
    That constraint is discharged and the pin has moved since: `popopx-pin-5` was pushed, `b5bc7577`
    reverted its revert, and `cabal.project:24` with `scripts/nix/sha256map.nix:2` now read
    `13df615d…` = `popopx-pin-7`, so the labels this paragraph says were inherited are branded again by
    the dependency itself. What did **not** follow the pin is the built half — the archives measured in
    the next sentences were installed through pin-4 (mtimes 2026-11-13, two days before pin-5 exists),
    and pin-6 and pin-7 both moved the store's UDF name, which is the drift that shows there.
    CI is a different story, told below, because the
    test that is red there does not read the pin at all. Measured on the two installed
    slices, `apps/ios/Libraries/ios/libHSpopopx-chat-7.1.2.0-2pJp6QhAZjZInPLhny3S4B-ghc9.6.3.a` and
    `…/sim/…same name…`, both **2 branded / 0 upstream** — so what an App Store build would carry is
    the broken side, not the working one. That count is `grep -a -o -E 'POPOPXSbChain' ARCHIVE | wc -l`,
    a raw-byte read, because `strings` reports 0 on the simulator slice: it aborts on `Mobile.o`
    (`malformed object (linker optimization hint … overlaps section relocation entries)`) and skips the
    member carrying the literal, so a `strings`-based gate would call that archive clean. Two things
    make this whole measurement re-derivable rather than a story about a deleted build. The *after*
    state is on this machine now: the relay built from `../popopxmq` self-reports
    `SMP server v7.1.0.17 / cb9e1aa` and reads **0 branded / 2 upstream**, and the relay taken from
    upstream's own build reads the same **0 / 2** while reporting `71179c4` — those two differ only by
    the hash they print, which is why this was never a version gap. The *before* state survives as
    bytes, not as a tree: the branded client is kept at `/tmp/ppx-before/popopx-chat-branded`
    (195,600,984 bytes, **2 branded / 0 upstream** by the same raw-byte read). Building a client against
    a dependency commit that has not been pushed takes more than this repository's documented
    `cabal.project.local` `packages:` stanza, and that is worth writing down because every route short
    of this one *succeeds*: `packages: . ../popopxmq` is shadowed by the `source-repository-package`
    entry (measured — `Up to date`, 0 recompiled modules, binary still 2 branded), and repointing that
    entry at `/Users/elliot/popopx-chat/popopxmq` with `tag: cb9e1aa3…` does fetch the right commit —
    the log shows `From /Users/elliot/popopx-chat/popopxmq … HEAD is now at cb9e1aa3` and 149
    `Compiling Popopx.Messaging` lines — yet still links the branded objects, because cabal unpacks the
    fetched repository into `dist-newstyle/src/<name>-<version>` and reuses that directory whenever the
    *version* is unchanged (the reused one was a September-dated checkout of `5b881a70`, branded). Both
    `dist-newstyle/src/popopxmq-7.1.0.17` and
    `dist-newstyle/build/aarch64-osx/ghc-9.6.3/popopxmq-7.1.0.17` have to go — measured both ways: with
    only the build directory cleared, `Popopx/Messaging/Crypto.o` came out 2 branded / 0 upstream at
    08:12, and with the extraction directory cleared too it came out **0 branded / 2 upstream** at 08:21.
    A clean CI run cannot hit this, so the trap is local-only — and what proves it either way is the
    raw-byte read on `…/popopxmq-7.1.0.17/build/Popopx/Messaging/Crypto.o`, never the log's `Linking`
    line.

    Acceptance, measured 2026-11-17 on loopback ports only. The broken pair, re-run with the bytes this
    item replaced: the preserved branded client against upstream's own relay
    (`/private/tmp/up-relay/smp-server`, **0 branded / 2 upstream**, self-reporting
    `SMP server v7.1.0.17 / 71179c4`) writes `A (1) --> localhost:63967 : NEW` at 08:09:21 and
    `BROKER {brokerErr = TIMEOUT}` seven seconds later, and that relay's 915-byte log has no line about
    the queue — no error, just silence. That is the whole reason this class of rename is dangerous: the
    client cannot tell a domain-separator mismatch from a dead server. The working pair puts the other
    end on bytes this fork does not produce at all — the published native backend's
    `libHSsmplxmq-7.1.0.16-a258938b-ghc9.6.3.dylib`, upstream's package name and **0 branded /
    2 upstream** — against the relay built from `cb9e1aa`, which self-reports
    `SMP server v7.1.0.17 / cb9e1aa`; with the store log on it records
    `CREATE rid=… queue_mode=C link_id=…`, so the queue was created and the end-to-end link established
    (`/private/tmp/relay-matrix/logs/smp-server-store.log`, 21,451 bytes). That relay binary is not kept
    on this machine, so its label count is quoted from its own self-reported commit rather than from the
    file. Harnesses: `/tmp/smp-exp/run2.sh <client> <relay> <tag>` for the CLI pair (store log off),
    `/tmp/relay-matrix/run.js` with `SMP_SERVER=` and `POPOPX_LIBS_DIR=` for the node pair. The third
    cell is the one that decides it, because it is the pairing no test in either repository can make:
    the CLI rebuilt from the reverted tree — `…/popopx-chat-7.1.2.0/x/popopx-chat/build/popopx-chat`,
    relinked 08:32:33 and reading **0 branded / 2 upstream** — against the *same* upstream relay binary
    as the broken cell (`71179c4`), which answers `NEW` with `IDS kkHo BbBV` in the same second on port
    65229 where the branded build of the same CLI spent 7 s timing out. Bytes in, bytes out, both ends
    from different trees, and nothing on either side had to be branded for it to work.

    The order in which the built artifacts have to be put back, because none of them is rebuilt by the
    dependency commit itself. Its first two steps are done and its premise is not: `cb9e1aa3` and
    `popopx-pin-5` were pushed, `b5bc7577` then restored the brand on top of them, and `cabal.project:24`
    moved twice — the second time onto `13df615d…` = `popopx-pin-7`, skipping `popopx-pin-6` (`4cc1b9d4`),
    which renamed the XOR-aggregation UDF by adding a 126-line migration
    `src/Popopx/Messaging/Agent/Store/SQLite/Migrations/M20261117_xor_udf_rename.hs` that pin-7 deletes
    36 minutes later in favour of renaming it in place and dropping the old SQL name entirely. Pin-6's
    own push run `44027639184` concluded `failure` before pin-7 landed, and a pin to pin-6 would record a
    migration its successor removes. What is still outstanding is the second half of the order — rebuild
    everything that reads the pin: the two installed iOS slices named above, the `-libs` bundle and the
    desktop artifacts CI publishes — and clear both
    `dist-newstyle` directories named above on any machine with a warm cache, which is what turns "I
    rebuilt it" back into a claim about bytes. Re-measured after the re-pin, the drift is in the store and
    in the call key, not in the ten labels: on each of `apps/ios/Libraries/{ios,sim,mac}/*.a`,
    `grep -a -o -E simplex_xor_md5_combine ARCHIVE | wc -l` reads **8** with
    `popopx_xor_md5_combine` **0** and `SimpleXCallMediaKey` **1**, while
    `grep -a -o -E '(POPOPX|SimpleX)(SbChainInit|SbChain|X3DH|VerifyCode|RootRatchet|ChainRatchet|ContactLink|InvLink)' ARCHIVE | grep -c POPOPX`
    reads **8** on `ios` and `sim` — pin-4 branded, pin-7 re-branded, so the two agree by accident — and
    **0** on the upstream-named `libHSsimplex-chat-…` archive under `mac/`, which reads **8** on the
    `SimpleX` counterpart. None of this is visible to `git status`: `apps/ios/.gitignore:67` ignores
    `Libraries/` and `:75` ignores `build/`, so a clean status says nothing at all about built bytes. The staleness runs in both directions: when
    `cabal.project` went back to `25d7213d…` at the end of this work, the extraction directory was
    deleted again on purpose, because it then held the *reverted* tree while the pin said branded, and a
    build left running against it would have produced a client whose bytes contradict its own pin.

    Measured again at 16:2x on 2026-11-17, after the re-pin, and the two readings of "did the pin take
    effect" disagree, so both are recorded here rather than reconciled. The link side says yes: `cabal build`
    and `cabal build popopx-chat-test` both exit 0, and all seven executables they produce — the six under
    `x/` (16:08) and `t/popopx-chat-test` (16:26) — read `grep -a -o -E popopx_xor_md5_combine EXE | wc -l`
    = **7** with `simplex_xor_md5_combine` **0**, next to the C symbol `_popopx_xor_md5_combine`, while the
    same recipe on the test binary reads `POPOPXCallMediaKey` **1** and `SimpleXCallMediaKey` **1**, which
    are the two guards of `callMediaKey`. No source file in this repository spells that UDF — `git grep -l
    popopx_xor_md5_combine` lists only these two documents — and the fetched tree is
    `13df615df7892532b4e83f92d529b96c3d788dea` ("Rename the XOR UDF in place and drop the old SQL name
    entirely"), so the link consumed pin-7 bytes. The dependency's own archives say no:
    `find dist-newstyle ../popopxmq -name 'libHSpopopxmq*' -type f` returns four files and all four read
    `popopx_xor_md5_combine` **0**, with the old name **8** in each `.a` and **11** in each `.dylib`, newest
    mtime 08:25:33 — before the 15:56 fetch of pin-7. This item's remedy for exactly that pairing is to
    clear the two `dist-newstyle` trees, and it was deliberately not run in this session: deleting build
    products is held as a red line here, and `popopxmq` and its build state are being worked on by another
    process as of this entry, so the discrepancy is left to that work instead of settled from this side.
    What this session does prove is the client half, and it proves it from binaries that carry the change:
    `-m "POPOPX chat protocol"` 82 examples / 0 failures, `-m "WebRTC crypto"` 4 / 0, and
    `-m "webrtc calls api"` 3 / 0 including `negotiate call between current and v1 clients`, each selected
    separately under `--fail-on=empty` so that an empty selection cannot pass as green.

    The gate this pin was taken at, stated as measured: the dependency's all-platform push run
    `44037250044` concluded `cancelled`, and its own `build.yml:21` reads
    `cancel-in-progress: ${{ github.event_name != 'push' }}`, so on a push nothing cancels itself — the
    cancel was manual, and the commit that superseded it is `4c8bdb7e`, a re-pin of the XFTP test server.
    Two legs had finished green before the cancel (`ubuntu-22.04-aarch64` and `ubuntu-24.04-aarch64`, both
    GHC 9.6.3), and PR run `44036381631` at the same commit adds `ubuntu-24.04-x86-64, GHC 9.6.3`. That is
    three compile legs green at `13df615d`. What reached no conclusion is the rest of that run's x86-64
    matrix — `ubuntu-22.04-x86-64` at GHC 8.10.7 and at 9.6.3, and its own `ubuntu-24.04-x86-64` leg, all
    `cancelled` rather than failed — plus one unexpanded matrix leg reporting `skipped`. No leg builds
    `aarch64-darwin`, so the macOS build named above is the only evidence here for what these bytes do on
    this platform.

    Premise (a) of the pin-4 → pin-7 crossing, ruled on 2026-11-17: an existing agent store does not survive
    this span, and no existing agent store needs to. It is recorded as a premise and not as a migration task
    because POPOPX is a new system with no user databases in the wild — the same ground the dependency stands
    on for its own separators, and a statement about deployments rather than about published artifacts, since
    `v7.1.2-popopx.1`'s desktop assets were built through pin-4. The reason it has to be written down is that
    this rename is not confined to code a binary re-runs. `git diff --stat 25d7213d..13df615d --
    src/Popopx/Messaging/Agent/Store/SQLite.hs src/Popopx/Messaging/Agent/Store/SQLite/` is exactly three files
    and 11 insertions against 11 deletions, every one of them the same string — and four of those lines are
    `CREATE TRIGGER` bodies, duplicated between `Migrations/M20260411_service_certs.hs:37,49,61,73` and the
    schema dump `Migrations/agent_schema.sql:656,667,678,689`, for `tr_rcv_queue_insert`,
    `tr_rcv_queue_delete`, `tr_rcv_queue_update_add` and `tr_rcv_queue_update_remove`. SQLite keeps trigger
    bodies as text in `sqlite_master`, so a store created through pin-4 carries
    `service_queue_ids_hash = simplex_xor_md5_combine(...)` inside its own schema while pin-7 registers only
    `popopx_xor_md5_combine` (`Store/SQLite.hs:131`, with the C export and import beside it at `:137,139`).
    Nothing rewrites that text on the way up, and that is the sharp part: the registered migration ids and the
    `Migrations/` file list are identical at the two pins — `git diff 25d7213d..13df615d --
    src/Popopx/Messaging/Agent/Store/SQLite/Migrations.hs` is empty — so no migration re-runs, and the store
    opens without complaint. The failure is deferred to the first write that fires one of those triggers,
    `no such function: simplex_xor_md5_combine`, and it lands on `rcv_queues` rather than anywhere near the
    pin. So a local store from the pin-4 era is deleted and rebuilt, not carried. If one is ever found worth
    keeping, what it needs is a migration that recreates those four triggers under the new name — a re-pin
    changes nothing already written into `sqlite_master`.

    The fourth end, and the reason this item does not make CI green: `build.yml`'s `Test changed scopes`
    runs the mcp e2e, and that e2e takes *both* of its ends from published release assets, not from the
    tree under test. `smpServer.ts:10` pins `serverRelease = "v7.1.0.17"` and `:123` downloads
    `https://github.com/popopx-chat/popopxmq/releases/download/v7.1.0.17/<name>-ubuntu-22_04-<arch>`,
    while the client end downloads `popopx-chat-libs-linux-x86_64.zip` from the `-libs` tag
    `core-7.1.0.20`; both fetches are in the log of run 43982143632, job 133701122623. No local artifact
    reaches it, because the override is exported only when the locally built libs exist and the release
    lane that builds them is off. The bytes of those published files, read on this machine: the zip's
    `libHSsimplexmq-7.1.0.16-25c1c0e9…-ghc9.6.3.so` is **0 branded / 2 upstream**, upstream's package name
    included, while `smp-server-ubuntu-22_04-x86-64` is **2 branded / 0 upstream** — as is
    `xftp-server-ubuntu-22_04-x86-64`, two of that release's 25 assets sampled, each matching the sha256
    pinned at `smpServer.ts:14,16` byte for byte (`554fffe2…`, `bfa1cba3…`). Upstream publishes no
    `v7.1.0.17` release at all (`gh api repos/simplex-chat/simplexmq/releases/tags/v7.1.0.17` is a 404),
    so those binaries were built by us, from the branded tree. That is the same split sitting in our own
    published artifacts — unbranded client against branded relay — and the run answers it the way the
    loopback cells do: `Test Suites: 2 failed, 2 total`, `Tests: 11 failed, 2 passed`, and all 11
    failures carry `{"type":"BROKER","brokerErr":{"type":"TIMEOUT"}}` against a `localhost` address.
    Closing it needs a publish, not a rebuild: republish the relay binaries from the reverted tree and
    move `smpServer.ts:10` together with its four digests, or stop the e2e fetching a published relay at
    all. "We reverted the labels" and "CI is green" are therefore two claims, and only the first is
    settled by `cb9e1aa3`.

## What was deliberately NOT changed

- **Copyright and attribution.** `author: simplex.chat` and `copyright: 2020-22 simplex.chat` in
  `popopx-chat.cabal:11,13` are verbatim from `db0768c21`; `maintainer:` is **not** — it reads
  `chat@popopx.chat` (`:12`) because item 9 moved the contact, so this item's earlier "the `author` /
  `maintainer` / `copyright` fields are retained verbatim" was true of two of the three. The three
  `Copyright (C) 2026 SimpleX Chat Ltd` asset-licence lines are retained (they are the three
  `ASSETS_LICENSE.md`: `assets/`, `apps/ios/POPOPX Snapshots/References/` and the desktop snapshot baselines,
  and `git grep -c 'Copyright (C) 2026 SimpleX Chat Ltd'` reads one in each), and so are the company-name
  references in the privacy, licence and legal texts — that count is a command:
  `git grep -o 'SimpleX Chat Ltd' -- PRIVACY.md PRIVACY-POPOPX.md LICENSE NOTICE TRADEMARK-POPOPX.md
  AGPL-COMPLIANCE.md ASSETS_LICENSE.md assets/ASSETS_LICENSE.md | wc -l` reads **58** (41 of
  them in `PRIVACY.md`, and 0 in `LICENSE`, which names the licence rather than the licensee), and
  repo-wide **134**; the "~78" first printed here does not reproduce under either. AGPL-3.0 §7 requires the
  retention (and §4 forbids removing it). It used to add "this codebase carries no
  per-file copyright headers, so there is nothing else to preserve" - that is false, and since 2026-11-15 the
  headers are preserved: `git grep -l 'Modifications Copyright © 2026 POPOPX Chat' | wc -l` reads **299** on
  tip `012ec8373` — 222 Swift, 69 `.strings`, 4 `.h`, 2 `.m`, and 2 `.md` that are records quoting the line
  (`AGPL-COMPLIANCE.md` and this file), which is why this item printed 297 (222+69+4+2) and why a
  recount taken after reading this sentence runs higher. All 299 also carry upstream's holder line above the
  POPOPX one (`Copyright © <year> SimpleX Chat. All rights reserved.`), which is what the rule preserves. The
  user-visible copyright strings are 62 `NSHumanReadableCopyright` keys in `.strings` and 32 in the `.xliff`
  catalogs — `git grep -o 'NSHumanReadableCopyright' -- '*.strings' '*.xliff' | wc -l` reads **94** here and
  read 94 at `e3652ffc5` too, so the "116 (62 `.strings`, 54 catalog entries)" this item printed does not
  reproduce and the stable facts are the 62 files and the rule: those strings stay POPOPX on purpose, because
  that string names the bundle we ship. See `AGPL-COMPLIANCE.md` §5.
- **Upstream GitHub URLs**, and the dependency references that are not ours to claim — *this bullet
  describes the state before 2026-11-13: the `docs/**`, `plans/**`, `blog/**` and `website/**` paths named
  below were removed by item 10 above, so what remains of this class is the `CHANGELOG.md` /
  `PRIVACY.md` records, the upstream URLs quoted inside surviving texts, and the `dist-newstyle/**`
  paths that captured commands quote. They are kept here because they are the record of why each
  identifier was held at the time.*
  **Citation convention adopted 2026-11-13, corrected 2026-11-17:** when a surviving file must still point at
  one of those deleted upstream documents, it cites the pinned upstream blob
  `https://github.com/simplex-chat/simplex-chat/blob/f8776692dfedc27dc3e723231b2ca11e02bedd06/<path>`. That
  commit is upstream's, and its tree is byte-identical to this fork's own root commit — `git rev-parse
  db0768c21^{tree} f8776692dfedc27dc3e723231b2ca11e02bedd06^{tree}` prints `a038752ebaf9ede903a7e48d912847bca1589ca8`
  twice. That is why `db0768c21` stays valid as a *prose* pointer (`simplex-chat@db0768c21`, resolvable with
  `git show db0768c21:<path>` in this repository) but must not appear in a URL: the commit exists only here,
  and every `blob/db0768c21` link answered 404 when re-measured on 2026-11-17, while the same path under the
  upstream SHA answered 200. A branch name (`stable`, `master`) was rejected because it drifts — all six
  cited paths open on both branches today, but the pinned SHA is the text this fork actually imported.
  The exception is the badge service's own RPC protocol:
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
  *obtain* a server did not — and because item 10 deleted `docs/` the same day (the one file under `docs/` on
  this tip is the terminal manual item 14 re-imported, not an operator document, so `git ls-files docs/ | wc -l`
  reads 1 and none of the paths this bullet names is in the tree), the citation is anchored to the import commit where it is still checkable rather than
  to a path in this tree: `git show db0768c21:docs/SERVER.md` puts the upstream release download at `:293`
  (`curl -L …/simplexmq/releases/latest/download/smp-server-ubuntu-20_04-x86-64`) and at `:854`, and the two
  compose blocks at its `:417` and `:483` default to `image: ${SIMPLEX_IMAGE:-simplexchat/smp-server:latest}`,
  whose `defaultCfgPath` really is `/etc/opt/simplex`. The hold itself is unchanged and is now a rule about
  whichever operator text we serve, not a live line in this repository; a self-hoster must therefore build the
  server from `popopxmq` (or set `SIMPLEX_IMAGE` to a POPOPX-built image); with upstream's artifact the
  mounted path and the path the process reads disagree, and the keys land in the container layer.
- **Cryptographic pre-images** (HKDF info parameters, badge hash inputs, SQLite FFI symbol
  names). Renaming these would silently break key derivation instead of failing to compile.
  This hold was written for the app repository and *violated in the dependency*: the ten HKDF and BBS
  labels were branded there, which is why they were reverted on 2026-11-17 — item 16 in
  §"What was changed" carries the measurement and the two gates.
- **Anything naming an upstream thing**: upstream operator addresses, the `simplex:` address
  format as understood on the public network, upstream social accounts. An identifier that
  names something belonging to upstream keeps upstream's name, or it stops resolving.
  Measured again on 2026-11-16 for the last two spelling families, with the measuring command in the
  sentence: `git grep -l 'simplex:/' -- ':!FORK.md' ':!CHANGELOG.md'` reads **four** files and four
  occurrences - `POPOPX-REBRAND-PLAN.md` (the question asked *about* it),
  `CHANGELOG.md`, `PRIVACY.md` (upstream's sentence about replacing the initial part of an old
  link) and `.github/ISSUE_TEMPLATE/question.yml`, where it sits inside a working upstream
  invitation URL; none of the four is code, which is why the hold reads as complete. The same command with no
  exclusions reads 13 occurrences in 6 tracked files - the surplus is this file and `CHANGELOG.md`
  spelling the old prefix inside the rulings that keep it, and this sentence quotes it again, so a recount
  taken after reading it runs higher than 13. Take the exclusion form as the answer to "where does it still
  survive", and the bare form as the answer to "how much of the tree is record". And `@directory.simplex` (17 occurrences across the MCP package's `PLAN.md`,
  `spec/flows.md`, `REFERENCE.md`, `TESTING.md`), `#ridgeline.simplex`, `#agents.simplex` and the
  peer name "SimpleX Directory" stay upstream's spelling, because those documents describe
  connecting to services SimpleX Chat Ltd operates and reach them by their upstream relay
  address (`REFERENCE.md:88`). What moved in the same lines was only what this build spells:
  `data PopopxTLD = TLDPopopx | TLDTesting | TLDWeb` and its parser (`popopxmq`
  `PopopxName.hs:54,121`) accept no `.simplex` name, so a row that documents the *shape* of a
  name target now reads `.popopx` while a *destination* keeps the name it has upstream.
- **The recorded migration name `20260603_simplex_name`** (`src/Popopx/Chat/Store/SQLite/Migrations.hs:347`,
  `src/Popopx/Chat/Store/Postgres/Migrations.hs:100`, mirrored in `tests/SchemaDump.hs:149` and
  `tests/PostgresSchemaDump.hs:85`). A database that has applied it stores that string and matches
  migrations against it, so renaming it does not rename a label - it makes an existing database
  disagree with the build. The Haskell symbols beside it (`m20260603_simplex_name`, in modules
  already named `M20260603_popopx_name`) were left with the string for the same reason: the pair is
  one fact, and the safe half to rename is the one nothing reads.
- **The domains** (`simplex.chat`, `simplex.im`) and the associated-domains / universal-link
  entries, until POPOPX owns and operates its own.

## Trademarks and artwork — outside the AGPL grant, and inside it

Clause-by-clause compliance record, including what the asset licence blocks before a release:
[`AGPL-COMPLIANCE.md`](./AGPL-COMPLIANCE.md).

Two things in this repository are **not** licensed to you by anything here, and a text substitution
does not change that: the **names**, in both projects, because a trade mark is not conveyed by a
copyright licence, and **upstream's artwork**, because this fork never held it to grant. What this fork
drew is a third thing, and since 2026-11-16 it is inside the grant — AGPL-3.0-only, or CC0-1.0 at the
recipient's option, per [`ASSETS_LICENSE.md`](./ASSETS_LICENSE.md) and item 15 above.

- **Trademarks.** "SimpleX", "SimpleX Chat" and the associated logos are trademarks of
  SimpleX Chat Ltd; see [their `docs/TRADEMARK.md`](https://github.com/simplex-chat/simplex-chat/blob/stable/docs/TRADEMARK.md)
  for the policy, which
  forbids using the mark in a fork's name or branding. POPOPX is used instead for that
  reason. This fork makes no claim of affiliation.
- **Application graphics.** The illustrations, icons, visual designs and test-snapshot
  screenshots we imported were proprietary and all rights reserved per
  [`assets/ASSETS_LICENSE.md`](./assets/ASSETS_LICENSE.md), which permits only distribution
  of the **unmodified** application. That permission does not extend to a rebranded fork, so the
  application graphics have been redrawn as POPOPX work product — the icons, the brand kit, the
  moko build-input illustrations, and (2026-11-13) the last upstream files in the iOS catalog: the
  crowdfunding badges, the chat wallpapers, `privacy` and `shield`. Any regenerated snapshot
  baselines are POPOPX Chat work product. What remains of upstream's artwork is documentation and
  website imagery, measured in [`ASSETS_LICENSE.md`](./ASSETS_LICENSE.md).
  The redraw was compelled by upstream's licence, and that compulsion is unchanged; what changed on
  2026-11-16 is our half of the result, now licensed (AGPL-3.0-only, or CC0-1.0 at your option). So a
  fork is no longer required by this repository's copyright to draw its own pictures — it is still
  required by `TRADEMARK-POPOPX.md` not to present our marks as its own.

## What is still unset

This fork is published by **POPOPX**, contact **chat@popopx.chat** — see
[`PRIVACY-POPOPX.md`](./PRIVACY-POPOPX.md). The two documents that exist because the fork needs its
own statements are [`PRIVACY-POPOPX.md`](./PRIVACY-POPOPX.md) (the companion record: who operates
what, and the measurement behind each claim) and [`PRIVACY.md`](./PRIVACY.md), which since 2026-11-25
is **POPOPX's own** policy rather than upstream's text — that rewrite is `9e1ab7c80`, and the file it
replaced is `git show 056aff908:PRIVACY.md`. The release record is
[`CHANGELOG.md`](./CHANGELOG.md): this fork's history, which on 2026-11-25 was renamed from
`CHANGELOG-POPOPX.md` and replaced upstream's file of that name
(`git show 056aff908:CHANGELOG.md`).

What remains below is not an undecided attribution — it is infrastructure this fork does not have
yet. Before any build of this fork is distributed:

- **No service is operated *by this fork* — except that `popopx.chat` is now in use anyway.** Ruled
  2026-11-13: the domain is used before its infrastructure is complete, and the gap is recorded rather
  than held. Since items 8 and 9 and the website pass, every self-declaration and every live link in the
  site, the app display copy, the SDKs, the Flatpak metainfo and the docs names `popopx.chat`, and the
  contact is `chat@popopx.chat`. One thing is still missing on that host and it is a silent-to-loud
  failure to fix there, not in code: neither `.well-known/apple-app-site-association` nor
  `.well-known/assetlinks.json` is served — both answered 404 again when re-measured 2026-11-15, while the
  TLS name mismatch this bullet used to report was retired the day before (see the certificate item under
  "Link claims are inert" below). So universal
  links and `autoVerify` cannot be claimed by an installed app yet, link unescaping falls back to the
  scheme, and the dependency's served `assetlinks.json` stopped being the mismatched half of the pair on
  2026-11-14 — its fingerprints are ours now (see "the other half of the pair" under the signing identity
  below). It still verifies nothing, for a different reason: this fork publishes no APK. The relay presets and the directory/badge service
  still name infrastructure SimpleX Chat Ltd operates, because a preset needs their key material and
  `popopx.im` relays have none published yet. `chat@popopx.chat` is unverified rather than known dead:
  measured 2026-11-17, no MX record is published for the domain (`dig +short MX popopx.chat` is empty
  while `dig +short A popopx.chat` answers `43.129.4.33` and the site there answers `200`), and the
  host's SMTP behaviour was not measured - an A-record fallback may accept mail. So nothing here claims
  the address is dead, and nothing here promises it is read either.
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
  `CHANGELOG.md`, "The front page stops recruiting, funding or identifying for SimpleX Chat Ltd".
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
  Ruled and executed 2026-11-17 (same pass as the citations above): `README.md:61-68` had claimed
  upstream's two user groups exist for questions "about POPOPX Chat only", `full_description.txt`,
  the desktop `appdata.xml` and the flatpak `metainfo.xml` spoke in the first person about relays this
  fork does not operate ("our servers do not have access", "routed via our servers"), the AppStream
  copy invented a protocol called "POPOPX Messaging Protocol", and `README.md`'s disclaimers carried
  SimpleX Chat Ltd's uptime, no-third-party-access and no-IP-logging claims as this fork's own. Each
  now says whose infrastructure it is and routes POPOPX questions to the issue tracker. Gates, each
  excluding the two records that quote the strings they count - a record otherwise measures itself:
  `git grep -n 'POPOPX Messaging Protocol' -- . ':!FORK.md' ':!CHANGELOG.md'` → 0 (the protocol's name is upstream's),
  `git grep -n 'our servers' -- apps/multiplatform/desktop scripts/flatpak fastlane` → 0,
  `git grep -n '99\.9\|never provided or have been requested\|do not log IP' -- README.md` → 0.
  What remains held is the four `HOLD (task #66)` contact entries above, which move only when POPOPX
  runs a relay and mints its own address.
  `SUPPORT_EMAIL` is already `chat@popopx.chat`, whose delivery is unverified (first bullet) - which is
  why the front page routes the fork's own questions to the GitHub issue tracker instead.
- **`popopx-chat-libs` had published no releases at all until 2026-11-16.** The asset names and the source
  they are fetched from are ours (item 6 above), so nothing in this repository could resolve a
  `core-<version>` release: the fork carries the build inputs and `releases.toml`, and its Releases list was
  empty. The first one has to come from our own CI, and that publish is also what rewrites the pinned digests in
  `release.ts`, `dist/release.js` and `_version.py` — until it does, those dictionaries still record
  upstream's build, under our names. Measured 2026-11-14, that last clause is now arithmetic rather than
  inference: **all 17 pinned digests equal upstream's asset digests byte for byte** — the 11 of
  `release.ts:8-18` are the tags `core-7.1.0.20` (6 zips) and `nodejs-addon-cce06d8` (5 `.node`) of
  `simplex-chat/simplex-chat-libs`, the 6 of `_version.py:10-15` are its tag `core-7.1.0.14` — while
  `popopx-chat/popopx-chat-libs` had 0 releases then (`gh release list`). How many it has is a query, not a
  fact to keep: `gh api repos/popopx-chat/popopx-chat-libs/releases --jq '.[] | .tag_name'` read **three**
  tags on 2026-11-16 (tip `012ec8373`), and `packages_release.py:608` (`libs_repository()`) asks that same
  repository by default, so the 404 this
  sentence described is closed at the host. What 404ed was the **name**: `3591a7eba` renamed the asset keys —
  `git grep -o 'popopx-chat-libs-\|popopx-chat-nodejs-' -- ':!FORK.md' ':!CHANGELOG.md'  | wc -l`
  reads **52** occurrences in 12 files today (44 when first written; the set grew with the mirrors, and this
  paragraph quotes the prefix, so a recount taken after reading it runs higher) —
  `packages_release.py:103-108`+`:118`, the two fetchers `_native.py:92-96`/`libs.ts:68,72`, both pin
  dictionaries, the four test mirrors, `package-tests.sh:49` — and left the digests where they were, which is
  the one-sided-rename class with a third end a commit cannot move — the host holding the bytes. Two facts
  make this a documented gap rather than an outage: nothing is published to npm or PyPI from this fork either
  (next bullet — no `NPM_SCOPE`/`PYPI_*` variables), so only an install from our own tree reaches it; and
  `check-pins` used to be the sentence that would print `core-7.1.0.20 is not published` here (`pin_problems`,
  `packages_release.py:289`); that half was an **absent** guard until 2026-11-17, when `check-pins` gained the
  ledger rule and a scope that runs it (see "The ledger is ours now" below), and what a command showed here is: `packages.yml` runs only on pull requests and has never run on this fork, and
  `python3 scripts/ci/packages_release.py check-pins` dies before its first API call on this machine —
  `ModuleNotFoundError: No module named 'tomllib'` at `packages_release.py:35`, Python 3.9.6, measured
  2026-11-16, with no interpreter ≥ 3.11 installed here.
  That last limitation was worked around rather than accepted, and the suite runs here since: compile the module with
  `__future__.annotations.compiler_flag` (its `X | None` annotations stay lazy only under that import), put the module object into
  `sys.modules` before executing it so `from packages_release import …` resolves to that same object, and stand in for
  `tomllib.loads` over the subset `render_releases()` writes — `[a.b]` headers, optionally quoted, and `"key" = "value"` rows.
  A one-line `loads = lambda s: {}` does not pass: it drops every recorded version and turns 4 tests red, so any count quoted from a
  local run names the stand-in that produced it.
  **The mirror was completed on 2026-11-16** (ruling: upstream's bytes, our names): first the linux pair, one
  asset per tag (`core-7.1.0.20` → `popopx-chat-libs-linux-x86_64.zip`, 47,719,648 B,
  `3080a41272f9ca1b670b0faf9bfc67919d0dc0e82defaebb423e1aae1f327af3`; `nodejs-addon-cce06d8` →
  `popopx-chat-nodejs-linux-x86_64.node`, 163,288 B,
  `fda77e39a5d38b1132a6a04ef9f9cd2c939a429e709f28c81c3777684ba73603` — both digests are the pinned ones,
  checked twice: on the bytes downloaded from upstream before the upload, and again on an anonymous `curl`
  of the `browser_download_url` afterwards), then every remaining name both pin dictionaries carry.
  **No pin was rewritten** - which was the alternative, and the
  unverifiable one: `libs.ts:205-210` throws unless the downloaded bytes hash to the pinned value
  (`actual !== expected`), so rewriting a pin to whatever a download produced would have made the check
  pass for any bytes at all and proved nothing about their origin.
  The content is upstream's own and says so: the archive still holds `libs/libsimplex.so` (64,653,952 B)
  and `libHSsimplexmq-7.1.0.16-…-ghc9.6.3.so` among its 165 `libHS*.so`, and the add-on has 240 `simplex`
  strings against 0 `popopx`, including the mangled symbols of the C++ `simplex::` namespace
  (`_ZN7simplex8Receiver…`) - so each release body states that the bytes are SimpleX Chat Ltd's and that
  the POPOPX file name is a hosting convenience. That is the rule this fork follows for content belonging
  upstream. What the mirror does **not** close: these are upstream's builds, so every pinned digest still
  describes a build this fork did not run, and the fork's own publish lane has still not run (the two
  switches below stay unprovisioned). What it **does** close is the hosting half, and that is a command, not a
  number to remember:
  `gh api repos/popopx-chat/popopx-chat-libs/releases --jq '.[] | .tag_name as $t | .assets[] | $t + " " + .name + " " + .digest'`
  read **17** assets across the three tags on 2026-11-16 (tip `012ec8373`) — `core-7.1.0.20`'s 6 zips are the 6
  of `release.ts:8-13`, `nodejs-addon-cce06d8`'s 5 `.node` are `release.ts:14-18`, `core-7.1.0.14`'s 6 zips are
  `_version.py:10-15` — and comparing those two sets name by name found no pinned asset unhosted, no hosted
  asset unnamed, and **no digest differing from its pin**. So `release_digests` (`:228`), which returns nothing
  unless *every* asset of the tag is present, no longer refuses these tags, and `download`/`prepare` can pin
  from them. That agreement is GitHub's own `sha256:` field per asset, plus `size` compared against upstream's
  same-tag assets (17/17 equal); it is not a local re-hash of 800 MB — though the add-on was re-hashed today,
  `curl -sSL .../nodejs-addon-cce06d8/popopx-chat-nodejs-linux-x86_64.node | shasum -a 256` returning the
  pinned `fda77e39…` and `strings | grep -c` returning **240** `simplex` against **0** `popopx`, so the
  sentence just above it about the add-on still reproduces. The zip half did not (the download of
  47,719,648 B did not complete on this line on 2026-11-16).
  **What the mirror did create is an accounting hazard, and it is in the file, not in the pins:**
  `releases.toml` is read from -libs over the API (`read_releases`, `:645`), not from this working tree
  (`git ls-files | grep -c releases.toml` is 0), and its `[core.master]` section stops at
  `7.1.0.19 = edb783a5…` with **no line for `7.1.0.20`**, so the lane's `latest_libs` (`:273`) cannot select the
  tag our pin names. `core-7.1.0.14` *is* recorded there, but against upstream's commit `5a02b906…`, while our
  tag of that name sits on our own history (`bd78134f…`; `core-7.1.0.20` is at `4d00516afe27fa83d4e532ce5f918e7d1f9576b2`
  and `nodejs-addon-cce06d8` at `616c4549f35237142f6ed793d30769caab8817ce` — all three from
  `gh api repos/popopx-chat/popopx-chat-libs/tags`, with -libs `master` since advanced to `5105d782…`). If
  `release.ts` is ever re-pinned to a build of ours, the mirrored tags stay behind as
  published releases of upstream bytes under a `core/master` version the record never claimed.
  **Ruled 2026-11-14: this is not a naming question and not a separate change — it closes with our first
  published release (#56).** Renaming the keys back to `simplex-chat-*` was rejected, because `build.yml`
  builds and reads a `popopx-chat-libs-<platform>` artifact of its own (`:491`, `:984`, `:1274`, `:1583`, read
  back at `:699` `POPOPX_LIBS_DIR`): one zip would then have two spellings depending on which pipeline asks.
  **The clause that used to hold our own publish off — `github.repository == 'simplex-chat/simplex-chat'` in
  `env.release_branch`, `build.yml:59` — was retargeted to this fork by `4a7f674b1` (2026-11-14).** That made
  the three `if: env.release_branch` steps (`:195` `Library release`, `:224` `Add-on release`, `:255` `Versions
  to publish`) execute on a push to master for the first time, and `Library release` failed every push since:
  `claim-core` compares our generated types against the commit recorded for the highest `core/master` version in
  the -libs `releases.toml`, which was then *upstream's* (`7.1.0.19 = edb783a5…`), and the same inherited file
  records upstream's published `@simplex-chat/types` version - so it exits as if we had released those bytes.
  Both files moved on 2026-11-17; see "The ledger is ours now" two bullets below.
  What keeps the lane inert now is two provisioning switches, each of which exits 0 with a `::notice` while
  unconfigured, so the test matrix runs instead of the job aborting:
  - `secrets.NODEJS_REPO_TOKEN` gates `Library release` and `Add-on release` — a token with release write on
    `popopx-chat-libs`, the name the workflow already uses in twelve steps (`:198`, `:227`, `:249`, `:543`,
    `:712`, `:989`, `:1284`, `:1318`, `:1593`, `:1627`, `:1756`, `:1936`). Everything downstream already keys on
    the outputs they leave empty: `Upload library` and `Build library` on `libs_tag`, the `Add-on` test steps and
    the `releases` job on `addon_draft`, the whole `build-linux-postgres` job on `libs_tag`.
  - `vars.NPM_SCOPE` (with `PYPI_PROJECT`/`PYPI_URL`) gates `Versions to publish`, whose plan is the only thing
    that starts the `publish` and `record` jobs. Left unguarded it would emit `nodejs_version`/`python_version`
    for versions that are genuinely unpublished here, and those jobs would run to a publish that has no
    credential behind it.
  Provisioning the first switch also required moving `packages/popopx-chat-client/types/typescript/package.json`
  out of upstream's published version set, because `claim-core` reads that field as the thing being released.
  That move is done — next bullet.
- **The ledger is ours now; the pins are the last thing that is not (2026-11-17, rulings "2 选(b) 重置成我们自己的空账",
  "3 版本 设置 7.1.0-beta.9.2", "4 删掉", "B 真修").**
  - `popopx-chat-libs/releases.toml` is a comments-only file as of commit `2b5e7046c82a0bc20070500ff50f372fd00095ab`
    (blob `3294f7304928484cb4950a178316227c8f37ae6e`): no `[core.master]` entry, so **nothing** is recorded as published
    by this repository. The inherited history stays retrievable as blob `aa35f4beaf6eee7a84fcad7411ea00c3c9f903ba`
    (23 lines, 1030 B — `[core.master]` reaching `7.1.0.19 = edb783a5…`, plus upstream's `[npm.*]`/`[pypi.*]` tables).
    `record_releases()` rewrites the file from the parsed table, so those comments do not survive the first recorded release.
  - Why the version had to move: the blocker was never the ledger contents. `claim-core` → `types_problem` →
    `npm_released("@simplex-chat/types", "7.1.0-beta.9.1")`, and the registry answers **200** for that exact version
    (upstream's `beta` dist-tag; `7.1.0-beta.9.2` answers **404**), so the step exited as if we had published upstream's
    artifact. `7.1.2.0` in `popopxChatCore` already matched `popopx-chat.cabal:8`, so the version was the only value in reach.
  - What that one line does **not** touch: the dependents keep `^7.1.0-beta.9.1` — 8 occurrences in 5 files before, **7 in 4**
    after the source `package.json:3` moved (`packages/popopx-chat-mcp/package.json:27` with its lock at `:14`/`:1487-1488`/`:4289`,
    `packages/popopx-chat-nodejs/package.json:27`, `packages/popopx-chat-mcp/PLAN.md:129`). Those name the npm artifact
    *upstream* published and `npm ci` resolves from the registry, `^7.1.0-beta.9.1` still accepts the source package, and
    `scope-tests.sh` consumes the types source by path (`npm install … ../popopx-chat-client/types/typescript`), not by version.
  - The guard that was missing: `check-pins` compared the pinned digests against *whatever release hosts the tag*, so a copy
    of someone else's bytes passed it. It now also demands that each pinned `core-<version>` be recorded —
    `recorded_pin_problems()` at `packages_release.py:788`, called from `check_pins()` at `:969` — because only the ledger says
    who built the bytes. `has_recorded_core()` (`:427`) decides how loudly: while the ledger records no core release at all — our state
    until the lane's first one — each unrecorded pin is a `::warning title=Unrecorded pin::` annotation and the scope exits 0; once a
    `core/<branch>` row exists the same pins are fatal. The switch needs no second edit, because arming it is what recording our own
    release means.
    Measured against the live repository it names two problems and no digest mismatch —
    `core-7.1.0.20` (nodejs) and `core-7.1.0.14` (`_version.py:8`, an older mirror the two files disagree about), both `draft=false`.
    The same call against `releases.toml` fetched from `popopx-chat-libs` exits 0 with those two as warnings, and exits 1 naming both
    once a `[core.master]` row is fed to it: that pair is how both modes were proven here.
    The blind spot left is the add-on pin: `record` accepts only `--types/--nodejs/--mcp/--python` and `claim-core` writes only `core/<branch>`,
    so a `nodejs-addon-<hash>` tag has no ledger entry to be judged against and `recorded_pin_problems` passes it by design.
  - The lane that runs it: `check-pins` used to execute only inside `publish`, which starts on a planned package release. It is the
    `libs-pins` scope now (`SCOPE_CHANGES` at `packages_release.py:86`, `scripts/ci/scope-tests.sh:14-16`), so `Test changed scopes`
    runs it for a pull request changing `packages/popopx-chat-nodejs/src/release.ts` or
    `packages/popopx-chat-python/src/simplex_chat/_version.py`; those two globs joined `build.yml`'s `pull_request` paths because
    `test_build_yml_runs_for_the_paths_of_its_builds` requires the list and the tables to be the same set. That gate is pull-request
    only. On a **push** `Check changes` takes its `*)` branch and, when `env.release_branch` is set (`build.yml:61` — this fork's
    `master` and `stable`), runs `packages_release.py scopes` (`build.yml:172`), which prints every key of `SCOPE_CHANGES`
    (`packages_release.py:1072`); `Test changed scopes` (`build.yml:733`) then loops them in one `shell: bash` step, and Actions runs
    that with `-e -o pipefail`. Run `43913834179` at `75ad2ca61` therefore read `SCOPES: badge-web ci-scripts libs-pins mcp` on a push
    touching neither pin file: `badge-web` and `ci-scripts` passed, `libs-pins` exited 1, and `mcp` never started — 0 `BROKER` occurrences
    against the **11** occurrences of the same step on the preceding master push (`43904789237` at `2d4926e6a`, job `133430903589`). The warning
    mode is what keeps the guard from standing in front of the defect beside it, and the push that carried it proved that: run
    `43982143632` at `d361ba1a2` read the same `SCOPES: badge-web ci-scripts libs-pins mcp`, `ci-scripts` printed `Ran 95 tests … OK`,
    `libs-pins` emitted 2 `##[warning]` lines and exited 0, and `mcp` ran to `Tests: 11 failed, 2 passed, 13 total` — the identical
    summary of `43904789237`, so the failure is back where it belongs. Both new tests and
    `test_build_yml_runs_for_the_paths_of_its_builds` are green on the runner (94 at `75ad2ca61`, 95 at `d361ba1a2`) and 95 on this
    machine through the `__future__.annotations` compile and stand-in TOML parser of the `tomllib` paragraph above, which also reaches
    the live `releases.toml`. `macos-latest (iOS)` completed in 7 steps, so the zero-step `cancelled` leg of `43913834179` was not this
    change either.
  - Order of what is left: `secrets.NODEJS_REPO_TOKEN` (the user provisions it) → the lane publishes `core-7.1.2.0` and the add-on and
    records them → both pin files re-derived from GitHub's own asset digests in one commit → only then delete the three mirror releases
    (ruling "4 删掉"), because deleting first would leave the pins naming a 404 with no path back to green.
- **macOS distribution cannot be produced from this machine, and the Team ID in our code has no identity
  here.** Measured 2026-11-14: `security find-identity -v -p codesigning` lists exactly one identity,
  `Apple Development: gang sun (RG6JMG38C8)` — a development certificate for a *different* team than the
  `PDBA6XRBQT` our entitlements, provisioning and `ACCESS_GROUP` name. There is no `Developer ID Application`
  identity at all, so a signed, notarized `.dmg` cannot be built locally; on CI the consequence is already
  handled and was proven in CI — `build.yml:1204-1209` warns and skips when `APPLE_POPOPX_SIGNING_IDENTITY`
  is unset, which it is (`gh secret list` is empty). The practical cost of shipping a tag with no Apple
  secrets is therefore a **missing `popopx-desktop-macos-{aarch64,x86_64}.dmg` in the release**, and
  `Platform.desktop.kt:17-18` points the macOS updater at exactly those two names: the updater on macOS would
  find no asset rather than a wrong one. The identity string's legal-entity part cannot be chosen from the
  brand at all — Apple fixes it to the registered organization of the developer account that owns the
  certificate, so this item needs an Apple Developer Program account, not a naming decision.
- **No registry namespace.** The npm and PyPI names in the committed manifests are upstream's, and
  that is the shape the release tooling expects: `packages_release.py test-names` rewrites the names,
  the repository URL and the cross-package dependencies to `npm:` aliases at publish time from the
  repository variables `NPM_SCOPE` and `PYPI_PROJECT`. Setting those two variables — plus an
  `@popopx-chat` npm org, a `popopx-chat` PyPI project and a `popopx-chat-libs` repository — is the
  fix; hand-editing the manifests would break `unreleased_pins()` and `check-pins` instead.
  The file that recorded the full method, `NODE-PACKAGES-POPOPX.md`, was **not retained** in the
  2026-11-25 history re-initialization, and neither was `scripts/ci/packages_release.py` itself —
  `git ls-files` lists no match for either path, and no workflow in `.github/workflows` runs a
  publish lane, so nothing in this tree executes that renaming today. This item is therefore the
  whole record of the mechanism here; the last states of both files are recoverable from the
  pre-restart objects (`git show b9b44beb3:NODE-PACKAGES-POPOPX.md`, `git show
  db0768c21:scripts/ci/packages_release.py`) if the method ever has to be rebuilt.
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
      lever: publishing `.well-known` needs two static locations added to that nginx. The files themselves
      are authored as of 2026-11-15 in the site directory `/Users/elliot/popopx-chat/popopx.chat/.well-known/`
      (`apple-app-site-association` with `PDBA6XRBQT.com.popopxchat.popopx` and the six link path shapes,
      `assetlinks.json` with `com.popopxchat.popopx` and the single release-certificate fingerprint
      `3A:7F:67:1A…FA:4C:CB`, plus a README naming the source of every value) — they are not in this git
      tree, which holds no copy since `website/` was removed, so copying them into the served root is the
      remaining step. Both still answer `404` until that is done.
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
      left with `website/` (`9996634ee`), so the copies that exist to map are the site directory's (previous
      bullet, written as a plain extensionless file) and the dependency's, which is already named
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
    Measured on tip `012ec8373` (2026-11-16), `git grep -o 'PDBA6XRBQT' | wc -l` reads **17** occurrences in 7
    files — but this paragraph quotes the string it counts, so a recount taken after reading it runs higher.
    The code side is a command of its own,
    `git grep -o 'PDBA6XRBQT' -- ':!FORK.md' ':!CHANGELOG.md'  | wc -l`: **6**
    occurrences in 4 files — `KeyChain.swift:14` (the
    keychain access group), `project.pbxproj:2137` and `:2201` (`DEVELOPMENT_TEAM`),
    `build-desktop-mac.sh:8,10` and `sign-libs-mac.sh:6` (both defaulting to it, both overridable by
    `APPLE_POPOPX_NOTARIZATION_TEAM_ID`) — and the other 11 are the three records naming it (6 lines here,
    3 in `CHANGELOG-POPOPX.md` (now `CHANGELOG.md`), 2 in `POPOPX-REBRAND-PLAN.md` (deleted 2026-11-25)). In the dependency it is 3 files: the AASA,
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
    first signed APK, where Play App Signing's and F-Droid's own fingerprints join this same array. The
    release published 2026-11-15 is #56 and ships no APK, so that deadline moved rather than passed.
    Ship route: popopxmq `25d7213d` = tag `popopx-pin-4` was the pin at the time, our pin moved with it (`cabal.project:24`,
    `scripts/nix/sha256map.nix:2`). The hash came from the command that file's own generator calls
    (`nix-prefetch-git --fetch-submodules`, per `scripts/nix/update-sha256.awk`), and the method was proven
    first by reproducing pin-3's stored
    hash byte-for-byte; `diff -rq` between the two fetched trees is **exactly one file** — this one — so no
    Haskell source moved and the iOS archives stay current. Both halves of that last clause are scoped to the
    pin-3→pin-4 step and neither holds for the pin this repository carries now, `13df615df7892532b4e83f92d529b96c3d788dea`
    = tag `popopx-pin-7` (2026-11-17, recorded hash `04ihl1j1qm4s9sik4c65gh2w78x6k2y8nv8a5jir11i6fm9gir9z`, again
    produced by that generator over all thirteen entries and diffed to one changed line): source did move, 81 files
    and 16 of them under `src`, and the installed archives do not stay current — see item 16 for what each of the
    three reads and why `git status` cannot see any of it. Ordering constraint: that pin is resolvable from
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
    The releases of that repository are a query, not a fact to keep: on 2026-11-16 (tip `012ec8373`)
    `gh api repos/popopx-chat/popopx-chat-libs/releases --jq '.[].tag_name'` read **three** tags —
    `core-7.1.0.20`, `nodejs-addon-cce06d8`, `core-7.1.0.14`, 17 assets between them. Not one of them was
    built or notarized here: all 17 are mirrors of upstream's bytes under our names (see the `-libs` bullet
    under "What is still unset"), which is the sharper way of saying the same thing — the Apple material is
    missing, not merely unrecorded.
  - *The installer was pointed at this repository.* Ruled 2026-11-13: `install.sh` set
    `APP_NAME="simplex-chat"`, and that variable is the **download value**, not a label — `:82`/`:84` compose
    `https://github.com/$APP_NAME/$APP_NAME/releases/$DOWNLOAD/$APP_NAME-$PLATFORM` from it and `:7` names the
    installed binary, so our own script fetched upstream's binary from upstream's releases and installed it as
    `simplex-chat`; the README then told the reader to run `popopx-chat`, which it had not installed. It now
    fetches `popopx-chat-*`, matching what our CI publishes (`build.yml:1020`/`:1027`/`:1431`, and
    `popopx-chat-ubuntu-22_04-x86_64` from the matrix at `:291`/`:292` with the derivation at `:568`), and
    `README.md:216` pipes the script from `popopx-chat/popopx-chat@master` — the only branch this repository
    has. Held: `$HOME/.simplex/simplex.agent.db` at `:43`, upstream's v0 agent database, which names something
    that really is upstream's. Not retargeted here: the Darwin branch at `:20`-`:24` asks for `macos-x86-64`
    only, so Apple Silicon gets the Intel build — a pre-existing upstream gap that is now reachable rather
    than hypothetical, because `popopx-chat-macos-x86-64` is a published asset. What this script composes is
    now verified against the published release (2026-11-15): `releases/latest/download/` answered `200` for
    all seven CLI names - four Ubuntu, both macOS, Windows. The script itself was not executed.
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
  **not** touched: an intent filter takes no wildcard host, so `AndroidManifest.xml:95-110` would have to
  enumerate every relay name we operate — upstream's list is exactly that, `grep -c 'android:host="smp'` on
  the file reads **15** explicit `smpN.simplex.im` rows (smp4–smp12 and smp14–smp19; there is no smp13)
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
  flatpak release URLs. Three of the four that remained were ruled on 2026-11-14 and moved, so **one**
  occurrence is left in code and resources, plus the prose of the two records that describe this decision
  (`CHANGELOG.md`, this file):
  - the metainfo `<screenshots><image>` — ruled **keep** on 2026-11-14 (「它是图片不是链接，不删掉」); it is an
    image reference, not a link, and deleting it would leave AppStream's only screenshot empty;
  - **A5 `contentModerationPostLink` — ruled and executed as a repoint to upstream's live article.** The value
    is one URL, and its set is a command: on tip `012ec8373` (2026-11-16)
    `git grep -o 'contentModerationPostLink' -- ':!FORK.md' ':!CHANGELOG.md' `
    reads **11** occurrences in 6 files, and those 11 are exactly 2 declarations, 2 imports, 7 reads (this
    bullet previously described "a paired value with 8 readers"; re-measured). The unexcluded recount is 15 in
    8 files — the surplus is the records, and this sentence names the symbol again, so read it after measuring,
    not before.
    Only the declarations moved —
    `apps/ios/POPOPXChat/ChatTypes.swift:26` and
    `apps/multiplatform/common/src/commonMain/kotlin/chat/popopx/common/views/chat/item/CIFileView.kt:305`
    now name `simplex.chat`, and every reader, the `how_it_works` label and the alert actions are untouched.
    The article is SimpleX Chat Ltd's, so the host that can serve it is theirs too; this is 「上游的东西沿上游
    名」 applied to a link, not a rename of one side of it. `popopx.chat` has no `/blog` tree, so the alternative
    — leaving our host in the URL — was a clickable 404 in the middle of a moderation explanation;
  - **A6 the fastlane store description — ruled and executed as attribution, not deletion.**
    `fastlane/metadata/android/en-US/full_description.txt:2` keeps the citation and the link but now says the
    November 2022 Trail of Bits assessment covers the upstream project this app is forked from and is not an
    audit of this fork. The audit was of SimpleX Chat v4.2, so presenting it as POPOPX's own would be a
    misattribution, and dropping the link alone would leave an uncited claim. Only `en-US` exists under
    `fastlane/metadata/android/`, and this was the sole holder of that slug in the tree besides
    `README.md:20`, which already named `simplex.chat`.
  - **A6's follow-up, ruled the same day as 品牌更新 and executed as `e338bbcdd`: the rest of that store
    description.** The file called the app, its platform and its relays "SimpleX" — 9 occurrences, now 2: the
    5 app-name uses became POPOPX, the 3 relay phrases became a description of the servers or the protocol's
    name (the preset relays are still upstream's, so the fork cannot call them its own brand), and what is
    left is twice the protocol's proper name, `SimpleX Messaging Protocol`, which is upstream's to keep. The
    other store metadata was already clean: `title.txt`/`short_description.txt` say POPOPX Chat and all nine
    images under `fastlane/…/images/` were redrawn by `9c8df8f09`.
  Everything naming `simplex.chat/blog` is held: that host serves upstream's articles, and the `.xcloc`
  catalogues are not a build input.
- **`popopx.chat/docs` is a ruled hold (2026-11-14: 「先不动，保留」).** The 31 holders this pass counted stay
  although measured 2026-11-14 all 13 distinct `popopx.chat/docs…` paths answer 404 (13/13, no timeouts):
  8 are fixtures in `scripts/ios/test_localizations.py`, 3 each in `PRIVACY-POPOPX.md` and
  `CHANGELOG.md`, 4 in the directory service pair (2 in `Directory/Service.hs`, 2 in its
  `tests/Bots/DirectoryTests.hs` mirror) and 1 each in `FORK.md`, `bots/README.md`, the metainfo
  `<url type="translate">` and the ten in-app help views that carry the same link in iOS and Kotlin
  (`AddContactLearnMore`, `UserAddressLearnMore`, `RTCServers`, `IncognitoView`/`IncognitoHelp`,
  `ProtocolServersView`). Those figures are the tree as this pass measured it; these two records naming the
  URL raises the live count above 31. A later ruling can move the holders as one unit; nothing here claims the
  paths resolve.
- **Store links 404.** Every `market://` / `details?id=com.popopxchat.popopx` / App Store URL in
  this repository names an app record that does not exist yet.
- **Everything that ships an image is either ours or is still upstream's, and the line is drawn by the
  bytes.** Measured 2026-11-15 on `23e22c439` against `db0768c21`, at the same path or at the brand-restored
  one: of **1562** tracked image files, **911** are POPOPX's bytes and **651** are byte-identical to upstream's.
  The marks, app icons and in-app illustrations are ours — the iOS catalog's last upstream files (badges,
  wallpapers, `privacy`, `shield`) were redrawn on 2026-11-13 and the Android launcher set with them, the
  29 illustrations the desktop and Android builds compile were redrawn on 2026-11-15 (`2a967acb0`), and so were
  the 6 icons in the same set that turned out not to be Google's geometry (`b6a3ee009`). The 4 desktop baselines
  of the two scenes that render that replaced tick pair stopped being upstream's bytes when CI re-rendered them
  (`23e22c439`).
  What is still upstream's, licensed only for the *unmodified* application under `assets/ASSETS_LICENSE.md`:
  272 Google Material Symbols glyphs (248 under `moko-resources/images/ic_*`, 11 under
  `resources/assets/www/desktop/images/ic_*`, 11 in `packages/popopx-chat-webrtc/**`, plus 2 that are Material's
  path data on another grid form) — Google's geometry, so attributed rather than redrawn — 42 empty 24x24
  placeholder vectors that carry no drawing, 186 of the 210 desktop snapshot baselines, 130 of the 374 iOS
  renders (renders of scenes that carry no brand artwork are indistinguishable from upstream's, so they are not
  claimed — see `ASSETS_LICENSE.md` §"What is NOT ours"), GitHub's octocat in `ic_github.svg` and 8
  third-party/Apple files in the iOS catalog, the 13 `packages/**` images whose only change is their directory
  name, and 10 fixtures and audit logos. The documentation and website imagery left with `docs/` and
  `website/`, so nothing here ships it.

### Upstream-operated hosts, and how each one fails

These are functional destinations, not branding: every one of them is where a POPOPX-branded build
sends a user. They are held as upstream wrote them, because renaming one only changes *who the
request says it belongs to* — the service itself does not move. Each row moves in the change that
stands up the equivalent POPOPX service, together with its keys. **That change landed for two of these
rows on 2026-11-23** — the notification-servers preset and the ICE/STUN/TURN defaults moved to this
fork's own `popopx.im` dual-stack cluster (`CHANGELOG.md`) — and they are kept below because the
host-and-key coupling, not the hostname, is what makes them fail silently. The badge contact, the badge
service and the directory rows are still upstream-operated.

| what it is | where | failure if the host moved alone |
| --- | --- | --- |
| badge service contact (an SMP relay + its key, in one address) | `src/Popopx/Chat.hs:73` | **silent**: TLS fingerprint mismatch, retried forever |
| notification servers preset (`ntf://<key>@ntf1/2/3.popopx.im,…onion:5226` — this fork's own cluster since 2026-11-23, keys supplied by the operator) | `src/Popopx/Chat/Library/Commands.hs:166-168` | **silent**: same class. This was the one upstream preset still enabled in the client until it moved — the SMP/XFTP presets in `Chat.hs` were emptied, these were not. Kept populated on purpose: the list is a plain `[NtfServer]` (`Controller.hs:275`, and nothing downstream forces `NonEmpty` — in the dependency, `popopxmq:src/Popopx/Messaging/Agent/NtfSubSupervisor.hs:591` `getNtfServer` returns `Nothing` for the empty list at its `:595`, and the call site `popopxmq:src/Popopx/Messaging/Agent.hs:3273` then fails token registration with `PROHIBITED` at `:3284`), so emptying it would be implementable but only costs push, exactly like the relays cost messaging. It moves with them |
| which stored relays count as "presets" | `src/Popopx/Chat.hs:102` `presetDomains = [".simplex.im"]` — `.simplexonflux.com` went with the deleted Flux operator, and `.popopx.im` is **deliberately absent**: adding it would force our port-less preset rows onto 443, where this cluster serves the web site, not SMP (see `CHANGELOG.md`) | **silent**: keyed on the host suffix, so renamed relays stop matching any stored row |
| shared directory listing | the page that read it, `website/src/js/directory.jsc:1` (`/data/`, filter at `:149`), was deleted with `website/` on 2026-11-13; the server half is `apps/popopx-directory-service` and its `src/Directory/Listing.hs:93-96` still records the pair | **silent-empty**: the fetch fails and the page shows no results |
| badge embed allow-list | `apps/popopx-badge-service/web/src/embed.ts:56`, inside `trustedHost` (`:46-57`) | **silent**: the widget refuses an origin outside `simplex.chat`/`.simplex.chat` and renders blank |
| badge purchase deep links | `apps/multiplatform/common/src/commonMain/kotlin/chat/popopx/common/views/badges/BadgeStore.kt:53-54` | **visible**: leaves the app into `badges.simplex.chat` — an upstream-branded page under a POPOPX label |
| ICE/STUN/TURN defaults | `packages/popopx-chat-webrtc/src/call.ts:355` — one entry, `stun:stun1.popopx.im:5349`. Upstream's `turns:turn.simplex.im` line, which carried a username and a literal credential in a public repository, is deleted here along with this fork's own TURN secret; the clients' bundled defaults (`WebRTCClient.swift`, `WebRTC.swift`, `WebRTC.kt`) were changed in the same commit. A `turns` entry can still arrive through the signed-config channel, where the credential is a `cid` reference resolved server-side | **visible**: calls that need a relayed candidate fail; a STUN-only default still connects host-direct and srflx. Used only when the user configured none (`AppSettings.hs:45` `webrtcICEServers`) |

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

Holding those hosts has a second, measurable consequence: they are also a **test** dependency. The MCP
end-to-end suite starts a local SMP and XFTP server (`packages/popopx-chat-mcp/test/e2e/smpServer.ts`)
and registers the local address with `/smp`, which *adds* to the user's server list rather than replacing
it — so the preset relays above stay in the pool. `apiCreateGroupLink` creates its connection inside the
agent (`src/Popopx/Chat/Library/Commands.hs:3387`), which draws a server from that pool, so the
group-link scenarios dial upstream's production relays. Ruled 2026-11-14 (E3) and recorded as a known red
rather than fixed, on these measurements:

- Run `43591293792` (commit `ef6ceac9a`): 12 of 13 e2e tests fail with one core answer, and one of the
  twelve verbatim — `{"type":"errorAgent","agentError":{"type":"BROKER","brokerAddress":"smp://…=@smp12.simplex.im,…","brokerErr":{"type":"TIMEOUT"}}}`.
  Seven distinct relays across the twelve (`smp8/9/10/12/14/17/18`), chosen at random from the pool.
- It is **not** a broken pair. The host+key strings the client dialed are byte-for-byte the pairs in
  upstream's `Presets.hs`, SMP and XFTP alike, so nothing in the rebrand moved one half of a wire value.
  The test files are upstream's too: the only differences are the evidence wrapper added in `ef6ceac9a`
  and the harness server source.
- Not a regression either: `Test changed scopes` has **never** succeeded in this repository — over the
  last 100 runs, 36 skipped, 4 failed, 0 succeeded — and it does not run on a tag push (`release_branch`
  is empty at `build.yml:59`), so no published artifact depends on it.
- Upstream ran the same step green on an mcp-scoped commit in the same hour (their run `43591265929`),
  which is why the residual is attributed to our build rather than to the runner's egress. The open
  hypothesis, unproven: our client is from a newer SMP protocol era than the software those public
  relays answer, so the dial stalls instead of erroring — upstream's client, pinned older, still matches
  them. Testing it is a one-line A/B of the harness server binary.

The fix that belongs to this fork is not a code edit: it lands when this fork operates its own relays and
can author its own pairs, at which point the presets move with them and the suite stops reaching outside
itself. Until then this step is expected red on a `tests=/` dispatch.

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

`.github/workflows/reproduce-schedule.yml` runs the desktop script **on dispatch only**, against this
repository's own latest release: its `schedule: - cron: 0 2 * * *` trigger was dropped on 2026-11-15, because
each run costs about 2.5 h of runner time and is red by construction until the two build paths below are made
to agree. The first verdict is in and it is red: dispatch
`43657558913` (2026-11-15, 2 h 25 m) rebuilt all seven Linux artefacts and **none of them matched**
`v7.1.2-popopx.1`, so `_sha256sums` was never written and the last step failed. For the four CLI
artefacts the reason is visible in the files: the release leg compiles with
`cabal build -j --enable-tests` (`build.yml:471`) and the reproduce leg with `cabal build -j`
(`popopx-chat-reproduce-builds.sh:84`), and this repository tracks no `cabal.project.freeze`, so each
side lets the solver choose dependency versions under different constraints. (`${{ env.ghc_options }}`
on that same line adds `--ghc-options=-O0` only when the event is not a `push`, so a tag build runs
without it - `build.yml:55`.) The toolchain is not the difference: both sides pin the same
`ubuntu:22.04`/`24.04` image digests, GHC 9.6.3 and the `UBUNTU_SNAPSHOT` apt snapshot, and the
packaging scripts set `SOURCE_DATE_EPOCH` and the two deb builders use `dpkg-deb --root-owner-group
--uniform-compression`. The three desktop artefacts are the Kotlin bundle, so they need a second
explanation that is not established here; the candidates are the caches CI restores and the reproduce
leg builds cold, and timestamps inside the packaged jars that the `touch` pass cannot reach. Upstream's
own nightly fails identically - seven consecutive red runs, 2026-11-08 to 2026-11-14 - which is why
this job is a report and not a gate. Before 2026-11-13 the same workflow checked out upstream's tree and
then called a script that exists only in ours, so every run failed for that reason instead.

The first step authenticates with `secrets.GITHUB_TOKEN` and separates "404, nothing published" from
"could not tell". Scheduled run `43668965123` printed `No published release to reproduce - skipping.`
at 02:41:43 and went green in 6 seconds while `v7.1.2-popopx.1` was published, because its anonymous
call from a runner's shared IP returned no `tag_name`; a run that cannot see the release verifies
nothing, so any status other than 200 or 404 now fails the step.

The last step posts the failure to `STATUS_POPOPX_WEBHOOK_URL` with `STATUS_POPOPX_WEBHOOK_USER` and
`STATUS_POPOPX_WEBHOOK_PASS`. None of the three is configured on this repository (`gh secret list`
returned nothing on 2026-11-13), so a reproduction that fails is visible as a red run and nowhere
else.
