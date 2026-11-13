# POPOPX artwork sources

Vector masters for the artwork this fork owns. Everything rendered from here is
covered by `../../ASSETS_LICENSE-POPOPX.md`; the generated rasters next to it in
`assets/multiplatform/resources/MR/images/` keep their upstream **file names**
(they are compiled `MR.images.<name>` resource identifiers) while their **bytes**
are ours — the test is `cmp` against the pristine upstream, not the name.

## Naming: the theme suffix is inverted

Upstream selects these in the callers, and the naming does not match the selection:

| file suffix | shown in | source here |
|---|---|---|
| `<name>@2x.png` | light mode | `<name>_light.svg` |
| `<name>_light@2x.png` | **dark** mode | `<name>_dark.svg` |

Evidence: `ChatListView.kt:424`, `OnboardingCards.kt:184`, `OnboardingLayout.kt:95`
(`if (isDark) …_light else …`). Do not "fix" the suffixes without moving those three
callers in the same commit.

## Brand

Mark: white speech bubble holding a "P" pennant. Palette taken from `PopopxTheme`,
not invented: `#0088FF` `PopopxBlue` (`ui/theme/Color.kt:17`, `Theme.kt:671`),
`#70F0F9` and `#1298A5` (`Theme.kt:715-716`), ink `#062A3A`.

## Regenerate

```sh
python3 /Users/elliot/popopx-chat/tools/r7/poppopx_assets.py   # writes SVGs + /tmp/poppopx_jobs.tsv
/Users/elliot/popopx-chat/tools/r7/svg2png --jobs /tmp/poppopx_jobs.tsv
```

`svg2png` decodes the SVG with `NSImage` and draws it into an exact-size
`NSBitmapImageRep`, so each output keeps the pixel size of the file it replaces.
It reads the size from the target file itself, so a size change upstream shows up
as a changed output rather than a silent crop.
