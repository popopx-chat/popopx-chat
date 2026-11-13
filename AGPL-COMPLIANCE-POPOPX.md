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
> naming-residue pass later the same day took it to **22**, all of them `packages/**` installed names.

## 1. What AGPL-3.0 requires of this fork, and where it is satisfied

| clause | obligation | state |
|---|---|---|
| §4 | do not propagate the work with the legal notices removed | **satisfied** — `LICENSE` (AGPL-3.0 text) and `NOTICE` are untouched; the `Copyright (C) 2026 SimpleX Chat Ltd` lines and the `author`/`maintainer`/`copyright` fields of `popopx-chat.cabal` were deliberately kept (R5, `7794b67cc`) |
| §5a | keep the source-form notices intact | **satisfied** — this codebase carries no per-file copyright headers, so there is nothing per-file to preserve |
| §5c | prominent notice of modification, with dates | **satisfied** — `FORK.md` states the fork is non-official and modified, names upstream, records the import commit `db0768c21` and its date (2026-11-11), and points at this repository as the complete corresponding source |
| §6 | offer the Complete Corresponding Source to network users | **satisfied by construction** — the whole fork is the CCS, published at `github.com/popopx-chat/popopx-chat`, build scripts included (`cabal.project`, `flake.nix`, `apps/ios`, `apps/multiplatform`). If this fork ever *runs* a service on top of the code (badge service, directory service, an operator), §13's remote-network clause applies to that service's modified code too |
| §7 | additional terms: the §7(b)/(c) attribution notices may not be removed | **satisfied** — see §4 above; upstream's trademark policy is cited at the pinned blob `simplex-chat@db0768c21:docs/TRADEMARK.md` — the citation convention recorded in `FORK.md`, adopted because `docs/` left this fork on 2026-11-13 — and the three `ASSETS_LICENSE.md` notices are kept |
| §10 | you may accept the licence on behalf of downstream recipients | no action |
| §13 | AGPL's copyleft over a network service | applies to any service this fork operates; nothing is operated yet (`FORK.md`, "No service is operated") |

## 2. The named residue is not an AGPL obligation

The three groups listed in the ruling are **names**, and AGPL-3.0 imposes nothing about them:

- **`simplexChatCore`** (37 occ / 18 files at ruling 6, **32 occ / 15 files** measured 2026-11-13) is a
  Haskell identifier (`src/Popopx/Chat/Core.hs`) that also appears as a field name in
  `packages/popopx-chat-client/types/typescript/package.json`, read
  back by `scripts/ci/packages_release.py:726`. It is one value on two sides of a build boundary.
  Renaming it is a branding change that must move the producer, the field and the reader in one commit
  — the rule that `ding_wire_audit.py` enforces. AGPL neither requires nor forbids it.
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
  repository (`ADDON_ASSETS`, `packages_release.py:119`); a half-moved pair would have pinned one family
  from our releases and downloaded the other from upstream's.
- **Tracked paths whose *name* contains "simplex": 322 at ruling 6, 67 on 2026-11-13, 22 after the
  naming-residue pass the same day.** 250 of the 322 were document and site paths
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
  What is **left at 22** is all of one kind: **20** in `packages/**` — the Node `cpp/simplex.{cc,h}` and
  `src/simplex.{js,d.ts}` plus the 16 files of the Python module `src/simplex_chat/**`, whose declared
  distribution name is still `simplex-chat` (`packages/popopx-chat-python/pyproject.toml:6`) — deliberate,
  not missed: `packages_release.py test-names` rewrites the npm/PyPI names from `NPM_SCOPE`/`PYPI_PROJECT`
  at publish time, which is the same two-ended-value rule in a different register — plus
  **2** `branding/source-svg/moko__ic_simplex_*@4x.svg` masters held for a deletion ruling, because they
  are byte-identical (`md5 2fb6e266…`, `8e284b07…`) to the renamed `moko__ic_popopx_*@4x.svg` and a rename
  would collide with them.
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
     `extra-extra-extra-large`, filenames unchanged. 198 differ byte-for-byte from upstream's, the
     other 178 are identical because those scenes carry no brand content — an unchanged PNG is not a
     copied one, they were all written by this repo's run.
   - the **210 desktop snapshot images** under `apps/multiplatform/common/src/desktopTest/snapshots` —
     still upstream's as this line was written. Regenerating them needs
     `chat.popopx.app.SnapshotTest#everyPreviewIsRendered` under `gradle desktopTest`, which needs a JDK and
     the dependency downloads this machine has neither of, so the rendering is done by CI:
     `desktop-linux.yml` (a `workflow_dispatch` job, never push-triggered) runs it with
     `-Ppopopx.assets.dir=../../assets` and uploads the `desktop-snapshots` artifact, which is then installed
     into this directory — the method, recorded because it is the only way this item can ever close;
   - ~~`website/src/img/**` (the wordmark images, screenshots, illustrations, `SimpleXExplainedLottie.json`)
     and the 93 tracked files under `assets/**`, if this fork's website ships them~~ **closed 2026-11-13,
     both halves**: `website/` left the fork in `9996634ee`, so its images are not shipped by anything here;
     and `assets/**` is now 89 tracked files — 88 under `assets/multiplatform/resources/MR/images/**`
     (replaced by POPOPX renders, ruling C2) plus the licence text. Measured against `db0768c21`, of the 103
     tracked files under `assets/**` and root `images/**` exactly **4** still carry upstream's bytes:
     `assets/ASSETS_LICENSE.md` (a notice, kept per §4) and the 3 third-party audit logos
     `images/{kuketz-blog,trail-of-bits,whonix-logo}.jpg` — not SimpleX marks, and they are what
     `README.md:26` links. The other 99 are ours (91 differ, 8 have no upstream counterpart).
   The action for each is **replace or remove before distribution**, not rename.

**Ruling C2 (2026-11-13)** promotes the two *build-input* sets above everything else, because they are not
documentation: `assets/multiplatform/resources/MR/images/**` (92 rasters) and
`apps/multiplatform/common/src/commonMain/resources/assets/default/MR/images/**` (46 vectors) are fed to
the app by `-Ppopopx.assets.dir=../../assets`, which every desktop/Android build and CI job passes
(`desktop-linux.yml:251,277`, `build.yml:1649`, `android-emu.yml:276`, `scripts/{desktop,android}/*`), so
upstream's illustrations compile into a POPOPX-branded app. They are being redrawn from POPOPX masters;
the 25 logical images behind the 138 files are listed in `ASSETS_LICENSE-POPOPX.md`, which also records
that the file *names* stay (they are compiled `MR.images.*` resource identifiers) while the bytes change.
3. **The licence texts stay**, including in folders whose assets we have replaced or removed — §4
   forbids removing notices, and they are the record of what we may not ship. Where an asset was
   replaced, the replacement's own provenance belongs next to it.

## 4. Open items this record does not close

- Whether POPOPX may *ask permission* for the artwork (the licence allows use "with prior written
  permission from SimpleX Chat Ltd") — a business decision, not a code one.
- ~~`docs/TRADEMARK.md` is upstream's policy; the fork's own trademark position is not written yet.~~
  **Written 2026-11-13**: `TRADEMARK-POPOPX.md` (marks, asserted as unregistered/common-law) and
  `ASSETS_LICENSE-POPOPX.md` (the artwork this fork created, proprietary, no redistribution without
  written permission). The three `ASSETS_LICENSE.md` files are kept verbatim; upstream's
  `docs/TRADEMARK.md` is not shipped by this fork any more (`docs/` was removed here on 2026-11-13), so
  it is cited at its source URL everywhere this fork refers to it. A downstream fork still inherits both
  brands — recorded in `NOTICE` and in `README.md`'s
  License section.
- Any service this fork later operates triggers §13 for that service; nothing is operated now.
