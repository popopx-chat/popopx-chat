# POPOPX Graphic Assets License

Copyright (C) 2026 POPOPX. All rights reserved.

This file covers the graphic assets **this fork created**. It is the counterpart of
[assets/ASSETS_LICENSE.md](assets/ASSETS_LICENSE.md), which is SimpleX Chat Ltd's licence for
upstream's artwork and is kept in this repository unchanged; and of
[TRADEMARK-POPOPX.md](TRADEMARK-POPOPX.md), which covers the names.

AGPL-3.0 covers the source code ([LICENSE](LICENSE)) and does not cover artwork. Nothing in this file
restricts what you may do with the code: you may run it, study it, modify it and redistribute it under
AGPL-3.0. What you may not do is redistribute **our pictures** while you do it.

## What is POPOPX-owned artwork

Any image, icon, illustration, wordmark, logo, screenshot or other visual file in this repository whose
bytes are not a copy of an upstream SimpleX file. Provenance is decided by the bytes, not by the file
name — several of our files still carry an upstream name because that name is a compiled resource
identifier (`MR.images.simplex_address`, `simplex_address_light`), and one of ours is literally named
`popopx_app_icon`.

The set is reproducible against the pristine upstream we imported from (`db0768c21`): a raster or vector
file here is ours if it differs from the blob at the same path upstream, **or at upstream's name for that
path** where this fork renamed it, or if neither exists. The second half of that test is not a refinement:
this fork renamed `packages/simplex-chat-*` to `packages/popopx-chat-*`, and the first version of this file
compared same-path only, so 147 upstream images appeared to have no counterpart and were claimed below as
ours until 2026-11-15. Names move, blob ids do not.

```sh
# our blob id vs upstream's at the brand-restored path; equal means it is upstream's artwork
git ls-files -z -- '*.png' '*.jpg' '*.jpeg' '*.gif' '*.svg' '*.icns' '*.ico' '*.webp' '*.pdf' |
while IFS= read -r -d '' f; do
  u=${f//popopx-chat/simplex-chat}; u=${u//POPOPX/SimpleX}; u=${u//Popopx/Simplex}; u=${u//popopx/simplex}
  [ "$(git rev-parse -q --verify "db0768c21:$u")" = "$(git rev-parse -q --verify "HEAD:$f")" ] || echo "$f"
done
```

Measured 2026-11-13, that set contains at least:

- **iOS** — `apps/ios/Shared/Assets.xcassets/popopx_app_icon.imageset/**` (the app icons), the other
  POPOPX marks in `apps/ios/Shared/Assets.xcassets/**`, and the renders under
  `apps/ios/POPOPX Snapshots/References/**` that differ from upstream's. Measured 2026-11-15: 374 PNGs
  there, 244 ours, **130 byte-identical to upstream and therefore not claimed** (they were the 376/246 pair
  before two scenes left with the crowdfunding feature). Those renders were produced by this repository's
  own snapshot target, and an earlier version of this file argued that "an unchanged PNG is not a copied
  one, every file there was written by our run". That argument is dropped: a file we cannot tell apart from
  upstream's, by the only test anyone can run, is not ours to licence restrictively, and claiming it is the
  over-claim this section exists to avoid. The last upstream-drawn artwork in the catalog went on 2026-11-13
  (ruling 2): the 3 crowdfunding badge SVGs, the 6 wallpaper sets (18 PNGs) and `privacy`/`shield` (6 PNGs)
  are redrawn from the master's palette, at the same names, pixel sizes and `Contents.json` manifests, from
  the sources in `branding/source-svg/ios__*.svg`. 8 files there are still upstream's and are not SimpleX
  marks: the 2 Apple SF Symbol exports (`checkmark.2`, `checkmark.wide`) and the 6 GitHub octocat PNGs.
- **Android** — the 41 launcher/status-bar icons under
  `apps/multiplatform/android/src/main/res/{mipmap*,drawable*}/**`, generated from the iOS masters.
- **Desktop / multiplatform** — `ic_popopx` and the other files under
  `apps/multiplatform/common/src/**/MR/images/**` that differ from upstream, the 29 illustrations under
  `apps/multiplatform/common/src/commonMain/moko-resources/images/**` redrawn on 2026-11-15 (`2a967acb0`) and
  the 6 icons redrawn the same day (`b6a3ee009`), all from `branding/source-svg/moko__*.src.svg`.
- **Packages** — nothing. The 13 files under `packages/**` (`popopx-chat-mcp/images/approval.png` and
  `prompts.png`, and the 11 call glyphs under `popopx-chat-webrtc/src/desktop/images/**`) were listed here
  as ours "with no upstream counterpart". They are byte-identical to the same files under
  `packages/simplex-chat-*`: only the directory moved, so they belong to the group below.

## What is NOT ours, and what that means for you

Measured 2026-11-15 on `b6a3ee009` with the recipe above — comparing each tracked image with the blob at its
path *or at upstream's name for that path* in `db0768c21`, after `docs/`, `website/`, `blog/` and `plans/` left
this fork (see `FORK.md` item 10), after the file-name pass, after the desktop baselines were re-rendered by CI,
and after the last upstream drawings went (`2a967acb0` redrew 29 illustrations, `b6a3ee009` redrew 6 icons): of
**1562** image files (`.png .jpg .jpeg .gif .svg .icns .ico .webp .pdf`), **655** are still byte-identical to
upstream's and are SimpleX Chat Ltd's,
under [assets/ASSETS_LICENSE.md](assets/ASSETS_LICENSE.md) — which is *stricter* than this file in one respect
and *looser* in another: it permits them in an unmodified SimpleX Chat distribution (which a fork is
not), and it forbids modification. The earlier figures in this section are not comparable: **545** was measured
with a same-path-only recipe, **690** was measured before the 29 illustrations went and **661** before the 6
icons went; each of those two commits also added its own vector masters, which is why the tracked total moved
1527 → 1556 → 1562.
The groups:

- `apps/multiplatform/**` 494 — 251 moko `ic_*` UI glyphs, 190 desktop snapshot baselines, 42 empty 24x24
  placeholder vectors under `resources/assets/default/MR/images/**` (they exist so moko generates the
  `MR.images.*` identifier when `-Ppopopx.assets.dir` is absent; they carry no drawing, so there was never
  upstream artwork in them), and 11 `ic_*` call glyphs under `resources/assets/www/desktop/images/**`. It was
  529 until `2a967acb0`: the 29 that left are `decentralized` and `decentralized_light` @1x–@4x, `privacy` and
  `shield` @1x–@4x, the 6 `wallpaper_*@4x` tiles and the 3 `badge_*.svg` — the last brand artwork compiled
  into the desktop and Android apps. Then 6 more left in `b6a3ee009`: `ic_double_check.svg`,
  `ic_radiowaves_up_forward_{1,2,3,4}_bar.svg` and `ic_heart@4x.png`. No name left in this group is a brand
  mark;
- `apps/ios/POPOPX Snapshots/References/**` 130 — unchanged renders of scenes that carry no brand artwork,
  counted here as upstream's for the reason given in the section above;
- 275 files sit in the three glyph buckets above and in `packages/**`, and **272 of them are Google Material
  Symbols, not SimpleX drawings**: 270 carry Material's own `viewBox` (`0 96 960 960` or `0 -960 960 960`), and
  `ic_chevron_right_2.svg` / `ic_work_filled_padded.svg` are Material's `chevron_right` and `work` path data on
  the unshifted `0 0 960 960` grid and a padded 1240 canvas. Upstream's asset licence cannot claim a drawing it
  did not make, so these are held and attributed here rather than redrawn. `ic_github.svg` is GitHub's octocat,
  held for the same reason as the octocat PNGs below. The remaining 6 were **not** Material geometry and were
  upstream's own drawing — `b6a3ee009` replaced them, which corrects `2a967acb0`'s claim that all 257 `ic_*`
  were Google's;
- `packages/**` 13 — the 11 `simplex-chat-webrtc` call glyphs and the 2 `simplex-chat-mcp` screenshots, at
  our directory names. The two screenshots (`images/approval.png`, `images/prompts.png`) are the exception in
  that line: they are renders of upstream's UI, so they are artwork, not glyphs, and they are open;
- `apps/ios/Shared/Assets.xcassets/**` 8 — 2 Apple SF Symbol exports (`checkmark.2`, `checkmark.wide`) and the 6 GitHub octocat
  PNGs. Neither is a SimpleX mark: the symbols are Apple's own glyphs and the octocats are third-party art
  the app must keep to render the "star on GitHub" rows. `SharedAssets.xcassets/agent.imageset/agent.svg`
  was the ninth until it was redrawn in the same pass (`fc7a0470c`), because a glyph that ships inside the
  app is not documentation artwork and had no reason to stay upstream's;
- `tests/fixtures/**` 7 (5 images and 2 PDFs) and root `images/**` 3 — fixtures and the third-party audit logos (kuketz,
  trail-of-bits, whonix). Two fixtures are SimpleX's own logo bytes used as Haskell test inputs, `logo.jpg`
  (200x200) and `logo-large-rgba.png` (1630x466); they are open items, not oversights: replacing them moves an
  assertion on the exact transferred size (`Forward.hs:850` expects `31.3 KiB / 32080 bytes`) and the
  structural tests around the PNG (`ImageTests.hs:103` and `:262` require RGBA8 with transparency and a
  preserved aspect), so they need a Haskell run to land.

The other **907** are POPOPX's own bytes: 555 differ from the file at the corresponding upstream path, and
352 have no counterpart there at all. The 905 documentation and site images that were in this count before went with the content directories; with them present the
same *same-path* measurement gave 2089 tracked and 1471 identical; under the recipe above it was higher still, because 905 of those files were documentation and site images.
- ~~**the two build-input sets**~~ **replaced 2026-11-13 (ruling C2)**.
  `assets/multiplatform/resources/MR/images/**` is now 80 POPOPX renders (40 names × @2x/@3x, each at its
  original pixel size) drawn from vector masters in `branding/source-svg/`, and 12 files that no code
  referenced were deleted (`own_stake*`, `simplex_address*`). The names stay because they are compiled
  `MR.images.<name>` identifiers; the bytes are ours, and `cmp` against upstream returns nothing for all
  80. The companion set `apps/multiplatform/common/src/commonMain/resources/assets/default/MR/images/**`
  (42 vectors) was measured to be **empty 24×24 placeholders** — `<rect width="24" height="24" fill="none"/>`
  — which exist so moko generates the identifier when `-Ppopopx.assets.dir` is absent; they carry no artwork,
  so there is nothing of upstream's to replace in them.
  These were not decoration: every release and CI build passes `-Ppopopx.assets.dir=../../assets`
  (`apps/multiplatform/common/build.gradle.kts:14-37`), so until this landed upstream's illustrations were
  compiled **into** our desktop and Android apps. That blocker is closed for this set, and for the third one
  the same build compiles — the 29 illustrations in
  `apps/multiplatform/common/src/commonMain/moko-resources/images/**`, redrawn 2026-11-15 in `2a967acb0`.

Replaced or removed upstream files keep their licence notices (AGPL-3.0 §4 forbids removing notices, and
the notices are the record of what may not ship).

## Permitted use

- You may view these files, and you may build the application with them.
- Only POPOPX's own distribution channels may ship POPOPX-owned artwork to users.

## Not permitted

Any other use of POPOPX-owned artwork — redistribution, incorporation into another work, use as a
fork's icons, wordmark or marketing imagery, use on a website or in advertising, modified or
unmodified — without prior written permission from POPOPX.

Permission requests: **chat@popopx.chat**.

## Why it is written this strictly

Ruling: 双轨制 — the code stays AGPL-3.0 and free, the brand and the artwork stay proprietary. That is
the Firefox/WordPress/SimpleX structure, and it is the only structure that survives AGPL: a fork may not
be stopped from taking the code, so the deterrent has to sit on the parts AGPL does not reach. A fork
that wants to ship keeps every AGPL right it already had and supplies its own name and its own design;
the cost of that design work is the protection. This is deliberately stricter than upstream's asset
licence, which allows an unmodified distribution — a rebranded fork is by definition not unmodified.

This file is a licensing position, not legal advice.
