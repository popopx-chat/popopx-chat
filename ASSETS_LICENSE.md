# POPOPX Graphic Assets License

Copyright (C) 2026 POPOPX. The artwork this fork created is licensed under
**AGPL-3.0-only, or at your option CC0-1.0** — see [The grant](#the-grant) below. The
names are not: they are governed by [TRADEMARK-POPOPX.md](TRADEMARK-POPOPX.md).

This file covers the graphic assets **this fork created**. It is the counterpart of
[assets/ASSETS_LICENSE.md](assets/ASSETS_LICENSE.md), which is SimpleX Chat Ltd's licence for
upstream's artwork and is kept in this repository unchanged; and of
[TRADEMARK-POPOPX.md](TRADEMARK-POPOPX.md), which covers the names.

AGPL-3.0 covers the source code ([LICENSE](LICENSE)). This file used to hold the artwork out of that
grant: it said the code was free and the pictures were not. That position was withdrawn on 2026-11-16,
because a work cannot be conveyed as a whole under AGPL-3.0 while one of its own parts carries a term
forbidding redistribution — AGPL-3.0 section 10 calls that a further restriction, and section 12 does
not let us cure it by disclosing it. The artwork this fork created is therefore free in the same way
the code is, and the control that AGPL never reached — the names — stays where it belongs, in
[TRADEMARK-POPOPX.md](TRADEMARK-POPOPX.md).

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
- **Packages** — the 2 screenshots under `packages/popopx-chat-mcp/images/**` (`approval.png`, `prompts.png`),
  redrawn on 2026-11-15 as vector mockups of the POPOPX agent chat from
  `branding/source-svg/packages__popopx-chat-mcp__images__*.src.svg`, at the same names and pixel size
  (742x1489). The 11 call glyphs under `packages/popopx-chat-webrtc/src/desktop/images/**` are not: all 13
  files were listed here as ours "with no upstream counterpart", but they are byte-identical to the same
  files under `packages/simplex-chat-*` — only the directory moved, so the glyphs belong to the group below.
- **Test fixtures** — `tests/fixtures/logo.jpg` (200x200) and `logo-large-rgba.png` (1630x466), SimpleX's own
  logo bytes used as Haskell test inputs until 2026-11-15. They could not move before a Haskell run: the
  transferred-size assertion in `Forward.hs:850` and `Files.hs:190` reads the fixture's byte length, and
  `ImageTests.hs:103` and `:262` require RGBA8 with transparency and a preserved aspect. Both moved together,
  the assertion now reading `5.9 KiB / 6074 bytes`, and the tests that read them pass. The replacements are our own
  marks: the app icon at 200x200 (the same drawing as `popopx_app_icon.imageset`) and the POPOPX wordmark banner,
  rendered from `branding/source-svg/tests__fixtures__logo-large-rgba.png.src.svg`.

## What is NOT ours, and what that means for you

Measured 2026-11-15 against the staged tree on top of `174d520fc` with the recipe above — comparing each tracked
image with the blob at its path *or at upstream's name for that path* in `db0768c21`, after `docs/`, `website/`,
`blog/` and `plans/` left this fork (see `FORK.md` item 10), after the file-name pass, after the last upstream
drawings that were compiled into an app went (`2a967acb0` redrew 29 illustrations, `b6a3ee009` redrew 6 icons), after
CI re-rendered the desktop baselines against those files, and after the 4 images this file still carried as open
items — the 2 `packages/popopx-chat-mcp` screenshots and the 2 `tests/fixtures` logos — were replaced:
of **1565** image files (`.png .jpg .jpeg .gif .svg .icns .ico .webp .pdf`), **647** are still
byte-identical to upstream's and are SimpleX Chat Ltd's,
under [assets/ASSETS_LICENSE.md](assets/ASSETS_LICENSE.md) — which is *stricter* than this file in one respect
and *looser* in another: it permits them in an unmodified SimpleX Chat distribution (which a fork is
not), and it forbids modification. The earlier figures in this section are not comparable: **545** was measured
with a same-path-only recipe, **690** was measured before the 29 illustrations went, **661** before the 6
icons went, **655** before the 4 re-rendered baselines went and **651** before the 4 open items went; the artwork
commits also added their own vector masters, which is why the tracked total moved 1527 → 1556 → 1562 → 1565 (the
last step is the 3 `.src.svg` masters of these 4 replacements).
The groups:

- `apps/multiplatform/**` 490 — 251 moko `ic_*` UI glyphs, 186 desktop snapshot baselines, 42 empty 24x24
  placeholder vectors under `resources/assets/default/MR/images/**` (they exist so moko generates the
  `MR.images.*` identifier when `-Ppopopx.assets.dir` is absent; they carry no drawing, so there was never
  upstream artwork in them), and 11 `ic_*` call glyphs under `resources/assets/www/desktop/images/**`. It was
  529 until `2a967acb0`: the 29 that left are `decentralized` and `decentralized_light` @1x–@4x, `privacy` and
  `shield` @1x–@4x, the 6 `wallpaper_*@4x` tiles and the 3 `badge_*.svg` — the last brand artwork compiled
  into the desktop and Android apps. Then 6 more left in `b6a3ee009`: `ic_double_check.svg`,
  `ic_radiowaves_up_forward_{1,2,3,4}_bar.svg` and `ic_heart@4x.png`, and 4 more in `23e22c439`: the
  `ChatInfoView`/`GroupChatInfoView` baselines at `-light`/`-dark-font-100`, which stopped being upstream's bytes
  once those two scenes rendered the replaced tick pair. No name left in this group is a brand
  mark;
- `apps/ios/POPOPX Snapshots/References/**` 130 — unchanged renders of scenes that carry no brand artwork,
  counted here as upstream's for the reason given in the section above;
- 273 files sit in the three glyph buckets above and in `packages/**` (251 moko `ic_*`, the 11 www/desktop call
  glyphs, the 11 webrtc call glyphs), and **272 of them are Google Material
  Symbols, not SimpleX drawings**: 270 carry Material's own `viewBox` (`0 96 960 960` or `0 -960 960 960`), and
  `ic_chevron_right_2.svg` / `ic_work_filled_padded.svg` are Material's `chevron_right` and `work` path data on
  the unshifted `0 0 960 960` grid and a padded 1240 canvas. Upstream's asset licence cannot claim a drawing it
  did not make, so these are held and attributed here rather than redrawn. `ic_github.svg` is GitHub's octocat,
  held for the same reason as the octocat PNGs below. It was 275 until the 2 `simplex-chat-mcp` screenshots left;
  the remaining 6 were **not** Material geometry and were
  upstream's own drawing — `b6a3ee009` replaced them, which corrects `2a967acb0`'s claim that all 257 `ic_*`
  were Google's;
- `packages/**` 11 — the `simplex-chat-webrtc` call glyphs, at our directory names. The 2 `simplex-chat-mcp`
  screenshots that used to join them (`images/approval.png`, `images/prompts.png`) were renders of upstream's UI —
  artwork, not glyphs — and were redrawn 2026-11-15, so only the glyphs are left here;
- `apps/ios/Shared/Assets.xcassets/**` 8 — 2 Apple SF Symbol exports (`checkmark.2`, `checkmark.wide`) and the 6 GitHub octocat
  PNGs. Neither is a SimpleX mark: the symbols are Apple's own glyphs and the octocats are third-party art
  the app must keep to render the "star on GitHub" rows. `SharedAssets.xcassets/agent.imageset/agent.svg`
  was the ninth until it was redrawn in the same pass (`fc7a0470c`), because a glyph that ships inside the
  app is not documentation artwork and had no reason to stay upstream's;
- `tests/fixtures/**` 5 (3 images and 2 PDFs) and root `images/**` 3 — fixtures and the third-party audit logos (kuketz,
  trail-of-bits, whonix). It was 7: the two fixtures that were SimpleX's own logo bytes used as Haskell test inputs,
  `logo.jpg` (200x200) and `logo-large-rgba.png` (1630x466), were replaced 2026-11-15. They could not move without a
  Haskell run because the transfer moves an assertion on the exact size (`Forward.hs:850` and `Files.hs:190` mirrored
  `31.3 KiB / 32080 bytes`) and the structural tests around the PNG (`ImageTests.hs:103` and `:262` require RGBA8 with
  transparency and a preserved aspect); the size mirror moved with the bytes and all 10 examples that read the two
  fixtures were run green.

The other **918** are POPOPX's own bytes: 563 differ from the file at the corresponding upstream path, and
355 have no counterpart there at all. The 905 documentation and site images that were in this count before went with the content directories; with them present the
same *same-path* measurement gave 2089 tracked and 1471 identical; under the recipe above it was higher still, because 905 of those files were documentation and site images.
- ~~**the two build-input sets**~~ **replaced 2026-11-13 (ruling C2)**.
  `assets/multiplatform/resources/MR/images/**` is now 80 POPOPX renders (40 names × @2x/@3x, each at its
  original pixel size) drawn from vector masters in `branding/source-svg/`, and 12 files that no code
  referenced were deleted (`own_stake*`, `simplex_address*`). The names stay because they are compiled
  `MR.images.<name>` identifiers; the bytes are ours, and `cmp` against upstream returns nothing for all
  80. That last test was not sufficient, though: 72 of the 80 were ours in *bytes* only and still carried the
  pre-brand blue palette, so they were re-rendered onto the master purple on 2026-11-15 (`174d520fc`) — provenance
  by blob identity says whose file it is, not which brand it shows. The companion set `apps/multiplatform/common/src/commonMain/resources/assets/default/MR/images/**`
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

## The grant

The artwork this fork created — the set the recipe above measures, and nothing else — is licensed
under **AGPL-3.0-only**, the same terms as the code, or, **at your option, CC0-1.0**.

> This work is free software: you can redistribute it and/or modify it under the terms of the GNU
> Affero General Public License as published by the Free Software Foundation, version 3 only.

CC0-1.0: we waive our copyright and related rights in these files to the greatest extent permitted
by law; the operative text is
[creativecommons.org/publicdomain/zero/1.0/legalcode](https://creativecommons.org/publicdomain/zero/1.0/legalcode).

Two grants rather than one plain CC0, for one reason: a picture anyone may copy is still *our* mark,
and CC0 waives copyright but never a trade mark. Take the copyleft grant and the artwork travels with
the work it belongs to, which is what stops someone shipping our drawings inside a build they will not
give anyone the source of. Take CC0 and the artwork carries no obligation at all, which is what a
translated document, a distribution manifest or a packaging recipe needs when it cannot carry one.
Questions: **chat@popopx.chat** — asking is no longer required to use any of it.

## Not a licence of anything upstream's

This file can grant only what we made. The image files measured byte-identical to upstream in
[What is NOT ours](#what-is-not-ours-and-what-that-means-for-you) are SimpleX Chat Ltd's artwork under
[assets/ASSETS_LICENSE.md](assets/ASSETS_LICENSE.md), whose terms nothing in this repository reaches or
changes — including the one that withholds them from a distribution that is not unmodified SimpleX Chat.
That exposure is ours to carry, not ours to relicense, and it is recorded here rather than resolved.

## Names

[TRADEMARK-POPOPX.md](TRADEMARK-POPOPX.md) governs POPOPX, Popopx and the wordmark as marks. Neither
grant above is a trade mark licence: you may copy these bytes, and you may not present them as our
product, our endorsement, or our application.

## Why the strict version was withdrawn

The ruling this file used to record was 双轨制 — the code free, the brand and the artwork proprietary,
on the Firefox/WordPress/SimpleX model, on the reasoning that since AGPL cannot stop a fork taking the
code the deterrent has to sit on the part AGPL does not reach. That reasoning was sound about the names
and wrong about the artwork. A fork conveys one work, pictures included: the icons are embedded in the
binaries and the vectors that draw them are shipped as the corresponding source a server owes its users
under AGPL section 13. Holding one of those parts back under a permission requirement is a further
restriction on the rights section 11 grants, which section 10 forbids and section 12 does not let us
keep by disclosing. The names were never at risk from this: trade mark law is outside the license, and
still says what it said.

This file is a licensing position, not legal advice.
