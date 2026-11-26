# Cactus Needle 3 — vendored engine archives and the Xcode entries to paste

Nothing in this directory is referenced by `POPOPX.xcodeproj` yet, so the iOS target
builds and links exactly as it did before, with the assistant answering from the
deterministic engine. To switch the real engine on, paste the entries below. They were
read out of `project.pbxproj` on 2026-11-26 at the line numbers given; the file's digest
before any edit is
`45d96b9e23473552f0881795a1fceac032d15eead3f63d749562353df221c371`,
and that number must change only by the lines listed here.

## What is here, and where it came from

| file | bytes | sha256 |
|---|---|---|
| `cactus.h` | 1721 | `9be7eb25b1d89180495d04a0d2c27053f282dac85add50cacc48d73302819d9d` |
| `ios/libcactus.a` | 2013112 | `18fab404a7ffefcea860af9aaeb39ee46b37800ddf2be82a72290ad8427ea3d4` |
| `sim/libcactus.a` | 2070496 | `5b6cfc4c7280026541f84c93ce64d57ebd292abd2ea6f38f850ef53bb3b9f206` |

Re-measure with `shasum -a 256 cactus.h ios/libcactus.a sim/libcactus.a` and sizes with
`wc -c`. Sources, fetched 2026-11-26 through the local proxy:

- `https://huggingface.co/Cactus-Compute/cactus/resolve/main/releases/4.1.4/ios-arm64/libcactus.a`
- `https://huggingface.co/Cactus-Compute/cactus/resolve/main/releases/4.1.4/ios-sim-arm64/libcactus.a`
- `https://huggingface.co/Cactus-Compute/cactus/resolve/main/releases/4.1.4/ios-arm64/cactus.h` (byte-identical to the android and macos headers)
- the weights, `https://huggingface.co/Cactus-Compute/needle3/resolve/main/needle3.cact`, 35335380 bytes,
  `c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38`, live at
  `apps/multiplatform/common/src/commonMain/resources/assets/needle3.cact`

Both the runtime and the weights are Apache-2.0; the text is shipped at
`licences/third-party/apps/cactus/LICENSE` and the notice is in the repository `NOTICE`.

There is no `ios-sim-x86_64` archive: a Rosetta simulator build cannot link this library,
which is why the entries below are per-SDK conditionals rather than plain settings.

## 1. Link the library (four lines, two build configurations)

`LIBRARY_SEARCH_PATHS` is already a per-SDK conditional in both configurations — at
`:2980-2987` (Debug) and `:3035-3042` (Release), each currently holding
`$(inherited)` plus `$(PROJECT_DIR)/Libraries/ios` or `…/Libraries/sim`. Add one element
to each of the four lists, so the device configuration also searches `Vendor/cactus/ios`
and the simulator configuration also searches `Vendor/cactus/sim`:

```
				"LIBRARY_SEARCH_PATHS[sdk=iphoneos*]" = (
					"$(inherited)",
					"$(PROJECT_DIR)/Libraries/ios",
					"$(PROJECT_DIR)/Vendor/cactus/ios",     // ADD
				);
				"LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]" = (
					"$(inherited)",
					"$(PROJECT_DIR)/Libraries/sim",
					"$(PROJECT_DIR)/Vendor/cactus/sim",     // ADD
				);
```

`OTHER_LDFLAGS` is the scalar `"-lc++"` at `:2991` and `:3046`. It must become a list in
both configurations, because `-lcactus` is a second library and appending to a scalar
would silently replace `-lc++` and break the link of the Haskell core:

```
				OTHER_LDFLAGS = (
					"-lc++",
					"-lcactus",
				);
```

## 2. Nothing to paste for the C API (step 1 is the whole activation)

Swift never sees the `cactus_*` functions, so there is no bridging-header edit to make. Swift calls
`PopopxCactusBridge` — declared at `POPOPXChat/objc.h:48`, inside the bridging surface because
`POPOPXChat/POPOPX.h:14` already does `#include <POPOPXChat/objc.h>`, and `POPOPX.h` is the value of
`SWIFT_OBJC_BRIDGING_HEADER` at `:2999` and `:3054`. The `@interface` declares no C functions, so nothing
about the existing bridging surface changes and the app extension targets are unaffected.

The C prototypes are needed by exactly one file, `POPOPXChat/objc.m`, and only while the flag is on: line
`:40` is `#import "../Vendor/cactus/cactus.h"`, a quoted path relative to `POPOPXChat/`, which resolves to
this directory without a `HEADER_SEARCH_PATHS` entry and without a second copy of the header. It sits below
the `#if defined(POPPX_CACTUS_ENABLED)` guard at `:39`, so in the shipping build clang never opens the path.

To prove both states are real, compile the one file (without the flag is the shipping build, with it is the
activation):

```
xcrun --sdk iphoneos clang -fsyntax-only -fobjc-arc apps/ios/POPOPXChat/objc.m
xcrun --sdk iphoneos clang -fsyntax-only -fobjc-arc -DPOPPX_CACTUS_ENABLED=1 apps/ios/POPOPXChat/objc.m
```

Both were run on 2026-11-26: exit 0, and zero `warning:` or `error:` lines in either — no `-W` suppression
needed, which is also why `objc.h` carries no nullability annotations. `clang -E -DPOPPX_CACTUS_ENABLED=1`
on the same file prints the resolved path `apps/ios/POPOPXChat/../Vendor/cactus/cactus.h`, and moving that
header aside turns the pass red with `objc.m:40:9: fatal error: '../Vendor/cactus/cactus.h' file not found`
— so the green result means this directory's header was opened, not that the include was skipped. A missing
or renamed `cactus.h` is caught here, not by a device link.

## 3. Ship the weights (four lines, or zero)

`needle3.cact` must reach the app bundle for the engine to read it with zero network
download. The clean way is a versioned file reference modelled on an existing one —
`sounds` at `:497` is a *folder* reference, so copy the shape of a plain resource instead,
as `GoogleService-Info.plist` and the `.xcassets` entries do:

```
		AA00000100000000000000C1 /* needle3.cact in Resources */ = {isa = PBXBuildFile; fileRef = AA00000100000000000000C0 /* needle3.cact */; };
		AA00000100000000000000C0 /* needle3.cact */ = {isa = PBXFileReference; lastKnownFileType = file; path = needle3.cact; sourceTree = "<group>"; };
```

plus the two membership lines: `AA00000100000000000000C0 /* needle3.cact */,` inside a
group's `children` list, and `AA00000100000000000000C1 /* needle3.cact in Resources */,`
inside the app target's `resources` build phase (the phase that holds
`5C55A92E283D0FDE00C4E99E /* sounds in Resources */` at `:1974`). The `AA00…C0/C1`
identifiers are placeholders — Xcode will mint real ones if the paste is done in the
GUI, which is the safer route; hand-editing requires two unique 24-character hex ids.

Put the file where the group's `path` resolves. The simplest group to hang it on is the
one that already contains `sounds` (`:1120`), whose `path` makes those entries resolve
under `apps/ios`, so copy the weights to `apps/ios/needle3.cact` first:

```
cp apps/multiplatform/common/src/commonMain/resources/assets/needle3.cact apps/ios/needle3.cact
```

The zero-edit alternative, if the 35 MB is wanted in the bundle before the project file is
touched: drop `needle3.cact` into `apps/ios/sounds/`, which is a folder reference and is
copied wholesale into the bundle at build time, and Swift will find it under
`sounds/needle3.cact`. That works, and it is listed here as the option that needs no paste
at all — its cost is that a model file lives in a directory named for notification sounds,
so `PopopxNeedleAssets` on iOS looks for the resource in both places and prefers
`sounds/` only when the plain bundle path is absent.

## 4. What stays off after the paste

`PopopxNeedleAssets` verifies the digest before handing the bytes to the engine, and the
assistant calls `PopopxDeterministicEngine` unless the engine is explicitly enabled. The
measured reason is in the Kotlin sources and in `NOTICE`: the published base weights routed
1 of the 6 calendar intents this feature defines, and produced no usable Chinese output.
Linking the library makes the real path available; it does not make it the default.
