# POPOPX Chat — AGPL-3.0 compliance record

Ruling 6: "要求符合 AGPL3.0，按照 AGPL3.0 修复" — the residue listed under the third-party heading
(`simplexChatCore` 37 occurrences, `simplex-chat-nodejs-*` 17, `simplex-chat-libs` 100, 322 tracked
paths whose name contains "simplex") has to be dealt with as AGPL-3.0 actually requires. This file is
that reading, clause by clause, with the evidence in this checkout. It is a working compliance record,
not legal advice.

> **Re-measured 2026-11-13**, because those four figures are claims about this tree and the tree moved
> since (`docs/ website/ blog/ plans/` left in `9996634ee`, the libs asset family moved in `3591a7eba`):
> `simplexChatCore` **32 occurrences / 15 files**, `simplex-chat-nodejs` **23** (of which 4 are the
> `simplex-chat-nodejs-<platform>` asset name), `simplex-chat-libs` **6** (2 asset names), tracked paths
> whose *name* contains "simplex" **67**. Reproduce with `git grep -Io -- '<term>' | wc -l` and
> `git ls-files | grep -ic simplex`. §2 now reads the new numbers — and the 67 has itself moved: the
> naming-residue pass later the same day took it to **20**, every one of them a `packages/**` installed name.
>
> **Re-measured 2026-11-15** — the tree moved twice more (the libs asset family, the blog/crowdfunding
> deletions, and `POPOPX-REBRAND-PLAN.md` itself entering the index as `73f453f6b`): `simplexChatCore`
> **34 / 16** before this pass and **20 / 13** after it (§2 explains which half moved),
> `simplex-chat-nodejs` **20 / 6**, `simplex-chat-libs` **10 / 5**, tracked paths whose *name* contains
> "simplex" still **20**, all `packages/**`. The `simplex-chat-libs` figure rose 6 → 10 without anything
> being renamed back: the four added occurrences are two quoted CI download-log lines in
> `packages/popopx-chat-mcp/PLAN.md`, one sentence of the plan file, and this callout — records of a
> destination and GitHub URLs, not readers of a name. `git grep -Io -- '<term>' | wc -l` counts occurrences,
> `git grep -c` counts lines, and `PLAN.md:239-240` put two on one line.

## 1. What AGPL-3.0 requires of this fork, and where it is satisfied

| clause | obligation | state |
|---|---|---|
| §4 | do not propagate the work with the legal notices removed | **broken, then repaired 2026-11-15** — `LICENSE` (AGPL-3.0 text) and `NOTICE` were never touched, and the `Copyright (C) 2026 SimpleX Chat Ltd` lines and the `author`/`maintainer`/`copyright` fields of `popopx-chat.cabal` were deliberately kept (R5, `7794b67cc`). But deleting `docs/` in `9996634ee` also deleted `docs/dependencies/licences/**`: the **149 licence texts of our own dependencies**, propagated away with them for two days. They are re-installed byte-for-byte at `licences/third-party/{haskell,apps}/` and `NOTICE` now points at them — see §6 below |
| §5a | keep the source-form notices intact | **was FALSE, repaired 2026-11-15** — this row previously claimed "this codebase carries no per-file copyright headers, so there is nothing per-file to preserve". It does: upstream's per-file headers are in 297 source files, and the brand pass had rewritten the *holder* in each of them. See §5 below |
| §5c | prominent notice of modification, with dates | **satisfied** — `FORK.md` states the fork is non-official and modified, names upstream, records the import commit `db0768c21` and its date (2026-11-11), and points at this repository as the complete corresponding source |
| §6 | offer the Complete Corresponding Source to network users | **satisfied by construction** — the whole fork is the CCS, published at `github.com/popopx-chat/popopx-chat`, build scripts included (`cabal.project`, `flake.nix`, `apps/ios`, `apps/multiplatform`). If this fork ever *runs* a service on top of the code (badge service, directory service, an operator), §13's remote-network clause applies to that service's modified code too |
| §7 | additional terms: the §7(b)/(c) attribution notices may not be removed | **satisfied** — see §4 above; upstream's trademark policy is cited at the pinned blob `simplex-chat@db0768c21:docs/TRADEMARK.md` — the citation convention recorded in `FORK.md`, adopted because `docs/` left this fork on 2026-11-13 — and the three `ASSETS_LICENSE.md` notices are kept |
| §10 | you may accept the licence on behalf of downstream recipients | no action |
| §13 | AGPL's copyleft over a network service | applies to any service this fork operates; nothing is operated yet (`FORK.md`, "No service is operated") |

## 2. The named residue is not an AGPL obligation

The three groups listed in the ruling are **names**, and AGPL-3.0 imposes nothing about them:

- **`simplexChatCore`** (37 occ / 18 files at ruling 6, 32 / 15 measured 2026-11-13, **34 / 16** measured
  2026-11-15 before this pass) was **two different values sharing one spelling**: a Haskell identifier
  (`src/Popopx/Chat/Core.hs`) and a JSON field name in
  `packages/popopx-chat-client/types/typescript/package.json` read back by
  `scripts/ci/packages_release.py:730`. The field side moved on 2026-11-15 to `popopxChatCore` — 14
  occurrences / 3 files, the producer's `write_json` (`:775`), the reader (`:730-731`) and its 9 test
  fixtures moved in one commit, together with the stale version pair it guards (the field said core
  `7.1.0.18` while `popopx-chat.cabal:8` said `7.1.2.0`; both now read `7.1.2.0`, and the README line
  `POPOPX Chat core: 7.1.2.0` that `TYPES_README_CORE` requires matches them). The **remaining 20 / 13**
  are the other value: 14 occurrences in `src` and `apps` Haskell code — 3 sites in the definition
  `src/Popopx/Chat/Core.hs` and 11 across its 8 callers (the CLI `Terminal.hs` / `Terminal/Main.hs`, the
  server `apps/popopx-chat/Server.hs` and the four service/bot entries) — 1 call in
  `tests/Bots/BroadcastTests.hs`, 1 sentence in `apps/popopx-badge-service/web/README.md`, and 4 lines
  recording this split in this file and in `CHANGELOG-POPOPX.md`. Renaming an exported library identifier
  changes the API for anything importing `Popopx.Chat.Core` from this fork, so it was kept out of the
  scripting commit and given its own pass
  with `cabal build` over the library and all eight executables as the gate. AGPL neither requires nor
  forbids either move.

  **That pass ran on 2026-11-15 (ruling A+D 执行)**: after it, the only mentions of the old spelling left in
  the tree were 6, in these two record files (4 here, 2 in `CHANGELOG-POPOPX.md`) - no code, resource or
  script reads `simplexChatCore`, and raising that count again is a documentation act rather than a missed reader.
  `popopxChatCore` is **33 occurrences / 16 files**: 13 of them the JSON field (`scripts/ci/test_packages_release.py` 9, `scripts/ci/packages_release.py` 3, `package.json` 1) and 15
  the Haskell identifiers this pass moved (9 files), the rest being the test call, the badge-service README
  sentence and these records. The gate caught a census error before it could ship: `apps/**/*.hs` held 23
  further occurrences that a `src`/`tests` count misses, and `cabal build all` named the three modules that
  failed until they were included. String literals were not touched, per the standing Haskell ruling, so
  `server_operator_tag = 'simplex'` and its peers survive.
- **`simplex-chat-libs`** (100 occurrences at ruling 6, **6** measured 2026-11-13 — 2 of them the
  `-<platform>` asset filename inside a quoted download log) moved to `popopx-chat-libs` on 2026-11-13
  (FORK.md item 6). The reasoning here
  used to be that the name belongs to whoever hosts the releases, so renaming our side changes nothing on
  the wire — that became false when the repository was forked: `build.yml` already resolved
  `LIBS_REPOSITORY: ${{ github.repository }}-libs` to it, and the download source is therefore ours to
  name. What was left was the archive filenames, which are read back at install time by
  `packages/popopx-chat-nodejs/src/libs.ts` and `packages/popopx-chat-python/src/simplex_chat/_native.py`
  and keyed into the pinned digest dictionaries, so they are a two-ended value rather than prose — the
  reason they could not move as documentation.
- **`simplex-chat-nodejs-<platform>.node`** moved with it, being the other asset family of the same
  repository (`ADDON_ASSETS`, `packages_release.py:118`); a half-moved pair would have pinned one family
  from our releases and downloaded the other from upstream's.
- **Tracked paths whose *name* contains "simplex": 322 at ruling 6, 67 on 2026-11-13, 45 renamed and 2 deleted
  the same day, leaving **20**. 250 of the 322 were document and site paths
  (`website/src/{img,js}/**`, `plans/**`, `docs/**`, blog posts) that left with those directories in
  `9996634ee`. The remaining 45 that moved are source and artefact *names*, which is why they could not
  move as documentation — each needed its reader moved in the same commit: 13 Kotlin files, 2 desktop
  snapshot baselines, 4 desktop launcher artifacts, 2 support-bot test mocks, 2 build-reproduction
  scripts (+ their 2 readers in `reproduce-schedule.yml` and `release-apk.sh`) and 22 artwork files
  (`media-logos/**` and `images/**` with their `branding/source-svg/` mirrors, whose names are the output
  path with `/` written as `__`).
  **Corrected against my own earlier description of this tier:** those 13 were *file* names, not
  class-and-file names. Tier 甲 (`82130779f`) had already renamed the identifiers — `PopopxApp`,
  `PopopxService`, `POPOPXInfo`, `PopopxNameView`, `SetPopopxDomainView`, `SupportPOPOPXBanner`,
  `BadgesSupportPopopxView` — so 259 of the 266 `SimpleXAPI` occurrences and 41 of 53 `SimplexService`
  occurrences were path citations in this fork's own code maps (`apps/multiplatform/{CODE.md,product/**,
  spec/**}`), which moved with the files. Four of the 13 files had already lost their name's reader
  entirely: `SimplexNameView`, `SetSimplexNameView`, `SupportSimpleXBanner`,
  `BadgesSupportSimplexView` were referenced nowhere outside themselves.
  Tier 甲 also left **10 Kotlin import lines naming the pre-rename symbol** (`SimpleXTheme` ×7,
  `SimpleXLinkQRCode` ×2, `SimpleXInfo` ×1), which made `:common:compileKotlinDesktop` fail in CI for two
  days; repaired, and `tools/r7/kt_import_gate.py` now replays kotlinc's resolution over every brand
  import (10 hits when run against `f5a7fd984`, 0 against the repair).
  What is **left at 20** is all of one kind: **20** in `packages/**` — the Node `cpp/simplex.{cc,h}` and
  `src/simplex.{js,d.ts}` plus the 16 files of the Python module `src/simplex_chat/**`, whose declared
  distribution name is still `simplex-chat` (`packages/popopx-chat-python/pyproject.toml:6`) — deliberate,
  not missed: `packages_release.py test-names` rewrites the npm/PyPI names from `NPM_SCOPE`/`PYPI_PROJECT`
  at publish time, which is the same two-ended-value rule in a different register.
  The other 2 paths of the 22 were `branding/source-svg/moko__ic_simplex_{dark,light}@4x.svg`, **deleted** after
  this paragraph was written: they are byte-identical (`md5 2fb6e266…`, `8e284b07…`) to the renamed
  `moko__ic_popopx_*@4x.svg`, so a rename would have collided and only a deletion removes the name. Neither
  had a reader.
  Path names of documents that describe upstream were never a licence problem and none of these are one
  either — but none of them may move as documentation either. Trademark ruling #43 owns them, under the
  wire-audit gate. Measured for provenance: all
  24 artwork files are POPOPX bytes (11 differ from the same path in `db0768c21`, 13 have no upstream
  counterpart), so these were our pictures under upstream's filenames — a naming problem, not §3's licence
  problem.

**Conclusion for ruling 6:** the AGPL-compliance action on this residue is *none*. It stays under
branding rulings, where the wire-audit gate decides whether a rename is safe.

## 3. What AGPL does not cover, and what that blocks

The binding constraint on this fork is not AGPL. `assets/ASSETS_LICENSE.md`,
`apps/ios/POPOPX Snapshots/References/ASSETS_LICENSE.md` and
`apps/multiplatform/common/src/desktopTest/snapshots/ASSETS_LICENSE.md` all say the graphic assets —
"illustrations, images, icons, visual designs, and screenshots of the applications, such as the
snapshot images of the tests" — are **proprietary and not licensed under AGPLv3**, permit them only in
an **unmodified** SimpleX Chat distribution, and state that "modification, redistribution, or
incorporation into other works, is not permitted without prior written permission".

A rebranded fork is a modified work. Therefore:

1. **No upstream artwork may be shipped in a POPOPX distribution.** This is why R4 (`070168d15`)
   replaced the iOS marks instead of restyling them, and why the replacements came from a POPOPX
   artwork tree rather than from editing SimpleX's files.
2. **Still blocking a release**, because the licence does not allow them and no POPOPX counterpart
   exists yet:
   - ~~the Android icon layer~~ **replaced 2026-11-12** by art generated from the iOS masters: 45
     rasters (30 `mipmap-*` icon/round/foreground at 48-432, 10 `ntf_*` status-bar icons,
     `drawable-hdpi/icon.png`, the two 512 playstore images and the two 432 shared foregrounds) all
     resized from `AppIcon/1024.png` (light) and `DarkAppIcon/1024.png` (dark), plus
     `drawable-v24/ic_launcher_foreground.xml` deleted — it named upstream's vector and no resource
     referenced it.
     **Corrected 2026-11-13:** the sentence above claimed the `ntf_*` files were "transparent POPOPX
     silhouettes"; measured, they were 24-bit RGB with no alpha channel, where upstream's were
     32-bit RGBA. Android builds the status-bar icon from the alpha channel alone, so an opaque
     square is a solid tinted block there, not a mark. All 10 were redrawn as single-colour
     silhouettes on transparent with the "P" knocked out.
     The adaptive background colour `icon_dark_blue_background` was still SimpleX's navy `#030749`;
     it is now the master's deep purple `#3D0A6D`. `icon_background` stays `#FFFFFF`, and neither
     shows: the foregrounds are full-bleed, so both colours sit behind them. The 5
     `mipmap-anydpi-v26` xml only wire foreground to background and carry no artwork. The resource
     and component *names* still say "dark_blue", which no longer describes anything; they are held
     because `android:name=".MainActivity_dark_blue"` is a component name — the app enables and
     disables these aliases at runtime to swap the launcher icon, and PackageManager keys that state
     on the component name, so renaming it resets the user's chosen icon.
   - ~~the **376 iOS snapshot baselines**~~ **replaced 2026-11-12** with our own renders from the
     "POPOPX Snapshots" target: 264 at `large` plus 56 each at `accessibility-medium` and
     `extra-extra-extra-large`, filenames unchanged. Re-measured 2026-11-15: **374** PNGs are there (two left with the crowdfunding
     views), **130 byte-identical** to upstream's, 242 differing, 2 with no counterpart under any name. The
     clause this entry used to end with — "an unchanged PNG is not a copied one, they were all written by this
     repo's run" — is **withdrawn**. It was the argument `NOTICE` and `ASSETS_LICENSE-POPOPX.md` used to claim
     files that no downstream user can tell apart from upstream's by any test they can run, which is exactly
     the over-claim ruling AGPL-2 exists to remove: those 130 are upstream's for licence purposes, the 244
     are ours.
   - ~~the **210 desktop snapshot images** under `apps/multiplatform/common/src/desktopTest/snapshots`~~
     **replaced 2026-11-13** by CI run `43397744144` on `43d54a9b2`: all 210 filenames were re-installed
     unchanged (0 added, 0 removed) and **20 differ byte-for-byte** from upstream's, across 9 scenes
     (`ChatHelpView`, `ContactConnectionInfoView`, `HelpView`, `NewChatSheet`, `POPOPXInfo`, `QRCode`,
     `SettingsView`, `UserAddressView`, `WhatsNewView`) — the screens that show the brand name, an address
     or a link. The other 190 are identical because those scenes carry no brand artwork — and under the withdrawal
     above they are upstream's, not ours: 190 of these 210 files are now claimed by nobody here.
     The method is recorded because it is the only way this can ever be re-run:
     `desktop-linux.yml` (a `workflow_dispatch` job, never push-triggered) runs
     `chat.popopx.app.SnapshotTest#everyPreviewIsRendered` under `gradle desktopTest` with
     `-Ppopopx.assets.dir=../../assets` and uploads the `desktop-snapshots` artifact. It needs a JDK, Xvfb
     and the dependency downloads, so this Mac can never render them; it also means the artifact only
     exists if `:common:compileTestKotlinDesktop` compiles — a broken test source ships no renders at all.
   - ~~the **29 brand illustrations in the moko resource set**~~ **redrawn 2026-11-15** (`2a967acb0`):
     `apps/multiplatform/common/src/commonMain/moko-resources/images/**` held the last upstream-drawn
     artwork that compiles into the desktop and Android apps — `decentralized` + `decentralized_light`
     @1x–@4x, `privacy` + `shield` @1x–@4x, the 6 `wallpaper_*@4x` tiles and the 3 `badge_*.svg`. Measured
     with the recipe in `ASSETS_LICENSE-POPOPX.md`: 29 non-`ic_*` files were upstream's before, **0 after**.
     Names, pixel sizes, the `*_light` = `logoDarkMode` mapping (`PopopxAPI.kt:4783`) and the badges'
     intrinsic 300x399 are unchanged; the palette is sampled from the iOS app icon and the geometry is the
     iOS set's, so one named picture is one picture on both platforms. Vector masters:
     `branding/source-svg/moko__*.src.svg`.
   - ~~the **`ic_*` glyphs in the same set**, held as "Google Material Symbols, not SimpleX artwork"~~ —
     that blanket claim was measured file by file on the same day and was wrong for 9 of the 257: 248 do carry
     Material's viewBox, 2 are Material's path data on another grid form (`ic_chevron_right_2`,
     `ic_work_filled_padded`), 1 is GitHub's octocat (`ic_github.svg`) — and **6 are upstream's own drawing**:
     `ic_double_check.svg` (receipt ticks, `ChatModel.kt:4207-4309`), the four
     `ic_radiowaves_up_forward_*_bar.svg` (subscription quality, `SubscriptionStatusIcon.kt:19-39`) and
     `ic_heart@4x.png` (reaction glyph, drawn untinted, `ChatItemView.desktop.kt:27`). Replaced in
     `b6a3ee009` at the same names and intrinsic sizes; the heart keeps the measured colour `#E72E31` and was
     matched on apparent size (bbox 196x194 / 26838 opaque px against upstream's 200x198 / 26443), and the
     bars are drawn nested so N bars is an element-wise prefix of N+1, which is what the dim-4/lit-N overlay
     needs. The three named holds are recorded with their reasons in `ASSETS_LICENSE-POPOPX.md`.
   - ~~`website/src/img/**` (the wordmark images, screenshots, illustrations, `SimpleXExplainedLottie.json`)
     and the 93 tracked files under `assets/**`, if this fork's website ships them~~ **closed 2026-11-13,
     both halves**: `website/` left the fork in `9996634ee`, so its images are not shipped by anything here;
     and `assets/**` is now 81 tracked files — 80 under `assets/multiplatform/resources/MR/images/**`
     (replaced by POPOPX renders, ruling C2) plus the licence text. Measured against `db0768c21`, of the 95
     tracked files under `assets/**` and root `images/**` exactly **4** still carry upstream's bytes:
     `assets/ASSETS_LICENSE.md` (a notice, kept per §4) and the 3 third-party audit logos
     `images/{kuketz-blog,trail-of-bits,whonix-logo}.jpg` — not SimpleX marks, and they are what
     `README.md:26` links. The other 91 are ours, and each of the 91 differs from an upstream file at the same
     path or at the brand-restored one — none of them is "new", which is what the old same-path recipe
     reported for 8 of them.
   The action for each is **replace or remove before distribution**, not rename.

**Ruling C2 (2026-11-13)** promotes the *build-input* sets above everything else, because they are not
documentation: `assets/multiplatform/resources/MR/images/**` (80 rasters, 40 names × @2x/@3x, down from 92 when the 12 unreferenced names went) is fed to
the app by `-Ppopopx.assets.dir=../../assets`, which every desktop/Android build and CI job passes
(`desktop-linux.yml:251,277`, `build.yml:1649`, `android-emu.yml:276`, `scripts/{desktop,android}/*`), so
upstream's illustrations compile into a POPOPX-branded app. They are being redrawn from POPOPX masters;
the 40 logical images behind the 80 replaced rasters are listed in `ASSETS_LICENSE-POPOPX.md`, which also records
that the file *names* stay (they are compiled `MR.images.*` resource identifiers) while the bytes change.
The companion directory `apps/multiplatform/common/src/commonMain/resources/assets/default/MR/images/**`
(42 vectors) needs nothing: measured, every one of them is a 24x24 empty placeholder
(`<rect width="24" height="24" fill="none"/>`) that exists only so moko generates the identifier when the
property is absent — upstream's artwork was never in that directory, only its names.
3. **The licence texts stay**, including in folders whose assets we have replaced or removed — §4
   forbids removing notices, and they are the record of what we may not ship. Where an asset was
   replaced, the replacement's own provenance belongs next to it.

## 4. Open items this record does not close

- Whether POPOPX may *ask permission* for the artwork (the licence allows use "with prior written
  permission from SimpleX Chat Ltd") — a business decision, not a code one. **Narrowed 2026-11-16:**
  this item was written while this fork's own artwork was held under the same restrictive terms, so it
  covered both sides. It no longer covers ours — `ASSETS_LICENSE-POPOPX.md` §"The grant" releases it
  outright, and there is nothing left for us to license by permission. It is still live for the files
  measured byte-identical to upstream's, whose licence is SimpleX Chat Ltd's to interpret.
- ~~`docs/TRADEMARK.md` is upstream's policy; the fork's own trademark position is not written yet.~~
  **Written 2026-11-13**: `TRADEMARK-POPOPX.md` (marks, asserted as unregistered/common-law) and
  `ASSETS_LICENSE-POPOPX.md` ~~(the artwork this fork created, proprietary, no redistribution without
  written permission)~~ — **corrected 2026-11-16**: that parenthetical described the file as it read on
  the day it was written, and the ruling it recorded is withdrawn. The same file now licenses the
  artwork this fork created under **AGPL-3.0-only, or at the recipient's option CC0-1.0**, because a
  work conveyed as a whole under AGPL-3.0 cannot carry one part of itself forbidding redistribution:
  §10 calls that a further restriction on the rights §11 grants, and §12 does not let us keep it by
  disclosing it. The names are untouched by the change — trade mark is outside the licence — and so is
  upstream's artwork, which that document cannot grant and §3 above still blocks.
  The three `ASSETS_LICENSE.md` files are kept verbatim; upstream's
  `docs/TRADEMARK.md` is not shipped by this fork any more (`docs/` was removed here on 2026-11-13), so
  it is cited at its source URL everywhere this fork refers to it. A downstream fork still inherits both
  brands — recorded in `NOTICE` and in `README.md`'s
  License section.
- Any service this fork later operates triggers §13 for that service; nothing is operated now.
- **The 651 upstream-identical images are still in the distribution** (measured on `23e22c439`; 690 before the
  29 illustrations went, 661 before the 6 icons went, 655 before the 4 re-rendered baselines went). Ruling
  AGPL-2 fixed what this fork *claims*; it did not change what this fork *ships*. Upstream's asset licence
  allows those files only in an
  unmodified SimpleX Chat distribution and forbids modifying them, and this is neither, so the notice now
  tells the truth about ownership while the exposure itself stays open until each one is replaced or
  removed. What is left is no longer brand artwork compiled into the app: 251 moko `ic_*` and 11 www glyphs are
  Google Material geometry (held, attributed), 42 are empty placeholders that carry no drawing, 186 + 130 are
  unchanged snapshot renders of scenes that contain no upstream artwork — regenerating them into something
  different requires changing the UI they depict first — 8 are Apple's SF Symbols and GitHub's octocats, 13 in
  `packages/**` are Material glyphs plus the 2 mcp UI screenshots, and 10 are fixtures and third-party audit
  logos. The only upstream *drawings* still shipped are those 2 mcp screenshots and the 2 logo fixtures, and
  the fixtures need a Haskell run to land (`Forward.hs:850` asserts the transferred size, `ImageTests.hs:103`
  and `:262` assert the PNG's structure).

## 5. Per-file copyright headers (clause §5a) — repaired 2026-11-15

The §5a row above asserted there was nothing per-file to preserve. Measured against the import commit
`db0768c21` that is wrong: upstream ships per-file copyright headers, and an earlier branding pass had
rewritten the *holder* inside them — `Copyright © 2022 SimpleX Chat.` became `Copyright © 2022 POPOPX
Chat.` on files whose bytes are upstream's. That is not preserving a notice; it is an authorship claim
over someone else's file, which AGPL-3.0 §5b forbids propagating.

Repaired as **297 files**: `.swift` 222, `.strings` 69, `.h` 4, `.m` 2. Each header now reads upstream's
line, taken **verbatim from that file's blob at `db0768c21`** (not from a template — the eight distinct
literals differ by year and comment style), with one fork line added directly underneath:

```
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//  Modifications Copyright © 2026 POPOPX Chat.
```

Two findings worth keeping:

- **193 → 222, not by accident.** Classifying a file as "fork-authored" because its path is absent at the
  root commit is false here: the branding pass renamed paths (`SimpleXAPI.swift` → `POPOPXAPI.swift`), so
  the blob is upstream's under a different name. Matching rename-aware (`git diff -M`) and by basename
  recovered 29 more files, all of them upstream's.
- **Displayed values are the opposite case and were left alone.** 62 `NSHumanReadableCopyright` values in
  the compiled `InfoPlist.strings` (`POPOPX NSE` 17, `POPOPX SE` 11, catalogs 34) and the 54 `.xcloc`
  catalog entries carrying the same string still say POPOPX Chat, on purpose. That value is shown as the
  copyright *of the bundle the user has installed*; restoring upstream's name there would attribute our
  product to SimpleX Chat Ltd — the misattribution this fork's whole naming policy exists to avoid, and a
  visible SimpleX mark, which `TRADEMARK-POPOPX.md` rules out. Upstream's attribution belongs in the legal
  documents (`NOTICE`, `LICENSE`), not in our About panel.

So the split is by **silent vs visible**: a header nobody reads carries upstream's notice; a string the
user reads describes what we ship. A later brand sweep must not "fix" the upstream holder lines back to
POPOPX — they are the repair, not residue.

## 6. The third-party licence texts (clause §4) — re-installed 2026-11-15

Ruling: delete `docs/`, `website/`, `blog/`, `plans/` — executed in `9996634ee`. That delete was not only
content: `docs/dependencies/licences/**` held the licence text of **149** packages this fork builds against
(139 Haskell dependencies under `haskell/<name-version>/`, 10 bundled native libraries under
`apps/<library>/`, 4633 lines, 241774 bytes). Propagating the work without its dependency notices is what
§4 forbids, and for two days this repository did exactly that while still shipping the built products the
notices cover.

They are back, byte-for-byte, at a path that is not `docs/` — `licences/third-party/{haskell,apps}/` — because
the ruling that removed `docs/` is not undone by restoring a compliance artifact into it. `NOTICE` now names
the directory and its contents.

Two things were verified rather than assumed:

- **Equality.** Every staged blob id was compared with the id at `docs/dependencies/licences/…` in
  `db0768c21`: 149 checked, 0 mismatches. Nothing was rewritten, resaved or "tidied".
- **Currency.** A licence text can also be wrong by being *stale* — it may cover a dependency version we no
  longer use. The cabal file was compared line by line with the import commit's after restoring the brand
  words in it, and the only three differing lines are `homepage`, `author` and `copyright`, all deliberately
  left upstream. So the dependency set is the one these texts were collected for, and the set is neither
  over- nor under-inclusive because of this fork's work.

A gap this does not close: the texts came from upstream's capture, and if this fork ever *adds* a
dependency, nothing here checks that its licence text is added too. That check would belong in CI, and the
fork has no gate for it.
