# POPOPX Chat — AGPL-3.0 compliance record

Ruling 6: "要求符合 AGPL3.0，按照 AGPL3.0 修复" — the residue listed under the third-party heading
(`simplexChatCore` 37 occurrences, `simplex-chat-nodejs-*` 17, `simplex-chat-libs` 100, 322 tracked
paths whose name contains "simplex") has to be dealt with as AGPL-3.0 actually requires. This file is
that reading, clause by clause, with the evidence in this checkout. It is a working compliance record,
not legal advice.

## 1. What AGPL-3.0 requires of this fork, and where it is satisfied

| clause | obligation | state |
|---|---|---|
| §4 | do not propagate the work with the legal notices removed | **satisfied** — `LICENSE` (AGPL-3.0 text) and `NOTICE` are untouched; the `Copyright (C) 2026 SimpleX Chat Ltd` lines and the `author`/`maintainer`/`copyright` fields of `popopx-chat.cabal` were deliberately kept (R5, `7794b67cc`) |
| §5a | keep the source-form notices intact | **satisfied** — this codebase carries no per-file copyright headers, so there is nothing per-file to preserve |
| §5c | prominent notice of modification, with dates | **satisfied** — `FORK.md` states the fork is non-official and modified, names upstream, records the import commit `db0768c21` and its date (2026-11-11), and points at this repository as the complete corresponding source |
| §6 | offer the Complete Corresponding Source to network users | **satisfied by construction** — the whole fork is the CCS, published at `github.com/popopx-chat/popopx-chat`, build scripts included (`cabal.project`, `flake.nix`, `apps/ios`, `apps/multiplatform`). If this fork ever *runs* a service on top of the code (badge service, directory service, an operator), §13's remote-network clause applies to that service's modified code too |
| §7 | additional terms: the §7(b)/(c) attribution notices may not be removed | **satisfied** — see §4 above; `docs/TRADEMARK.md` is upstream's trademark policy and is kept |
| §10 | you may accept the licence on behalf of downstream recipients | no action |
| §13 | AGPL's copyleft over a network service | applies to any service this fork operates; nothing is operated yet (`FORK.md`, "No service is operated") |

## 2. The named residue is not an AGPL obligation

The three groups listed in the ruling are **names**, and AGPL-3.0 imposes nothing about them:

- **`simplexChatCore`** (37 occ / 18 files) is a Haskell identifier (`src/Popopx/Chat/Core.hs`) that
  also appears as a field name in `packages/popopx-chat-client/types/typescript/package.json`, read
  back by `scripts/ci/packages_release.py:726`. It is one value on two sides of a build boundary.
  Renaming it is a branding change that must move the producer, the field and the reader in one commit
  — the rule that `ding_wire_audit.py` enforces. AGPL neither requires nor forbids it.
- **`simplex-chat-libs`** (100 occ) is the name of *upstream's release artifact repository*. Its role
  here is already replaced: `build.yml` sets `LIBS_REPOSITORY: ${{ github.repository }}-libs`, which
  for this fork resolves to `popopx-chat/popopx-chat-libs`. The remaining spellings are the archive
  filenames inside it (`simplex-chat-libs-<os>-<arch>.zip`, `packages_release.py:104`) and the docs
  that describe them. Those filenames are data produced by whoever hosts the releases; changing our
  side alone changes nothing on the wire.
- **`simplex-chat-nodejs-<platform>.node`** (17 occ) is the add-on artifact name inside those archives
  (`ADDON_ASSETS`, `packages_release.py:119`) — same reasoning: it is a downloaded artifact's name.
- **322 tracked paths containing "simplex"** are, measured, mostly `website/src/img/**` and
  `website/src/js/**` (upstream's site), `plans/**` and `docs/**` prose, blog posts, and the
  moko-resources source paths. Path names of documents that describe upstream are not a licence
  problem; several of them are the licence texts themselves.

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
     rasters (30 `mipmap-*` icon/round/foreground at 48-432, 10 `ntf_*` status-bar silhouettes from
     the transparent POPOPX symbol, `drawable-hdpi/icon.png`, the two 512 playstore images and the
     two 432 shared foregrounds) all resized from `AppIcon/1024.png` (light) and
     `DarkAppIcon/1024.png` (dark), plus `drawable-v24/ic_launcher_foreground.xml` deleted — it named
     upstream's vector and no resource referenced it. Still upstream-valued: the two adaptive
     background colours `icon_background` `#FFFFFF` and `icon_dark_blue_background` `#030749`
     (SimpleX's dark blue) and the 5 `mipmap-anydpi-v26` xml, which only wire foreground to
     background; the foregrounds are full-bleed, so the colours are behind them and invisible.
   - the **376 iOS snapshot baselines** (`apps/ios/POPOPX Snapshots/References/*.png`) and the **210
     desktop snapshot images** under `apps/multiplatform/common/src/desktopTest/snapshots` — these are
     test fixtures of *their* app, and after R4 they no longer match our renders either;
   - `website/src/img/**` (the wordmark images, screenshots, illustrations, `SimpleXExplainedLottie.json`)
     and the 93 tracked files under `assets/**`, if this fork's website ships them.
   The action for each is **replace or remove before distribution**, not rename.
3. **The licence texts stay**, including in folders whose assets we have replaced or removed — §4
   forbids removing notices, and they are the record of what we may not ship. Where an asset was
   replaced, the replacement's own provenance belongs next to it.

## 4. Open items this record does not close

- Whether POPOPX may *ask permission* for the artwork (the licence allows use "with prior written
  permission from SimpleX Chat Ltd") — a business decision, not a code one.
- `docs/TRADEMARK.md` is upstream's policy; the fork's own trademark position is not written yet.
- Any service this fork later operates triggers §13 for that service; nothing is operated now.
