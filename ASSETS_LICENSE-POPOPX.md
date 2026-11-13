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
file here is ours if it differs from the file at the same path upstream, or if no such file exists.

```sh
UP=/path/to/simplex-chat   # an upstream checkout at the imported commit
git ls-files | grep -iE '\.(png|jpg|jpeg|gif|svg|webp|icns|ico)$' | while IFS= read -r f; do
  { [ -f "$UP/$f" ] && cmp -s "$f" "$UP/$f"; } || echo "$f"
done
```

Measured 2026-11-13, that set contains at least:

- **iOS** — `apps/ios/Shared/Assets.xcassets/popopx_app_icon.imageset/**` (the app icons), the other
  POPOPX marks in `apps/ios/Shared/Assets.xcassets/**`, and the 376 renders under
  `apps/ios/POPOPX Snapshots/References/**`. Those renders were produced by this repository's own
  snapshot target; 246 differ from upstream's and 130 are byte-equal to them because those scenes carry
  no brand content — an unchanged PNG is not a copied one, every file there was written by our run.
  The last upstream-drawn artwork in the catalog went on 2026-11-13 (ruling 2): the 3 crowdfunding badge
  SVGs, the 6 wallpaper sets (18 PNGs) and `privacy`/`shield` (6 PNGs) are redrawn from the master's
  palette, at the same names, pixel sizes and `Contents.json` manifests, from the sources in
  `branding/source-svg/ios__*.svg`. 8 files there are still upstream's and are not SimpleX marks: the
  2 Apple SF Symbol exports (`checkmark.2`, `checkmark.wide`) and the 6 GitHub octocat PNGs.
- **Android** — the 41 launcher/status-bar icons under
  `apps/multiplatform/android/src/main/res/{mipmap*,drawable*}/**`, generated from the iOS masters.
- **Desktop / multiplatform** — `ic_popopx` and the other files under
  `apps/multiplatform/common/src/**/MR/images/**` that differ from upstream.
- **Packages** — the 13 files under `packages/**` (`popopx-chat-mcp/images/**`,
  `popopx-chat-webrtc/src/desktop/images/**`) that have no upstream counterpart.

## What is NOT ours, and what that means for you

Measured 2026-11-13 at `9996634ee` (after `docs/`, `website/`, `blog/` and `plans/` left this fork — see
`FORK.md` item 10), comparing each tracked image with the blob at the same path in `db0768c21`: of
**1544** image files, **566** are still byte-identical to upstream's, and they are SimpleX Chat Ltd's,
under [assets/ASSETS_LICENSE.md](assets/ASSETS_LICENSE.md) — which is *stricter* than this file in one respect
and *looser* in another: it permits them in an unmodified SimpleX Chat distribution (which a fork is
not), and it forbids modification. The groups:

- `apps/multiplatform/**` 549 — the moko UI glyphs; every name was checked and none is a brand mark;
- `apps/ios/**` 9 — 2 Apple SF Symbol exports (`checkmark.2`, `checkmark.wide`), the 6 GitHub octocat
  PNGs, and `SharedAssets.xcassets/agent.imageset/agent.svg`, a 24px template-rendered glyph for the
  `.agent` chat type (`ChatTypes.swift:316`). None is a SimpleX mark; the first eight are platform and
  third-party art the app must keep, and `agent.svg` is a generic figure that a re-draw would still be
  the right call on;
- `tests/fixtures/**` 5 and root `images/**` 3 — fixtures and the third-party audit logos (kuketz,
  trail-of-bits, whonix).

The other 978 are POPOPX's own bytes or have no upstream counterpart at that path. The 905 documentation
and site images that were in this count before went with the content directories; with them present the
same measurement gave 2089 tracked and 1471 identical.
- ~~**the two build-input sets**~~ **replaced 2026-11-13 (ruling C2)**.
  `assets/multiplatform/resources/MR/images/**` is now 80 POPOPX renders (40 names × @2x/@3x, each at its
  original pixel size) drawn from vector masters in `branding/source-svg/`, and 12 files that no code
  referenced were deleted (`own_stake*`, `simplex_address*`). The names stay because they are compiled
  `MR.images.<name>` identifiers; the bytes are ours, and `cmp` against upstream returns nothing for all
  80. The companion set `apps/multiplatform/common/src/commonMain/resources/assets/default/MR/images/**`
  (46 vectors) was measured to be **empty 24×24 placeholders** — `<rect width="24" height="24" fill="none"/>`
  — which exist so moko generates the identifier when `POPOPX_ASSETS=false`; they carry no artwork, so
  there is nothing of upstream's to replace in them.
  These were not decoration: every release and CI build passes `-Ppopopx.assets.dir=../../assets`
  (`apps/multiplatform/common/build.gradle.kts:14-37`), so until this landed upstream's illustrations were
  compiled **into** our desktop and Android apps. That blocker is closed for this set.

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
