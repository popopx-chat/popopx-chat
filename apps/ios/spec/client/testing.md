# POPOPX Chat iOS -- Simulator Test Harness

> How to compile-gate and run the on-device regression suite locally, and the measurements that make a "green" run meaningless if you ignore them.
>
> Related specs: [Chat List](chat-list.md) | [Chat View](chat-view.md) | [Compose](compose.md) | [Navigation](navigation.md) | [README](../README.md)

**Source:** [`Tests iOS/Tests_iOS.swift`](../../Tests%20iOS/Tests_iOS.swift)

---

## Table of Contents

1. [Test targets](#1-test-targets)
2. [An app build is not a test build](#2-an-app-build-is-not-a-test-build)
3. [Code signing: the app group gate](#3-code-signing-the-app-group-gate)
4. [Running the regression suite](#4-running-the-regression-suite)
5. [Locator rules proven on device](#5-locator-rules-proven-on-device)
6. [What this suite cannot prove here](#6-what-this-suite-cannot-prove-here)

---

## 1. Test targets

There is **no `POPOPXUITests` target** -- the app has two test bundles, and they are different kinds of animal:

| Target | productType | Holds |
| --- | --- | --- |
| `Tests iOS` | `com.apple.product-type.bundle.ui-testing` | the upstream `Tests_iOS` boilerplate (`testExample`, `testLaunchPerformance`) **and** `PopopxChatRoomRegressionTests` (T0-T4), appended to the same file so nothing new has to be dragged into the project |
| `POPOPX Snapshots` | `com.apple.product-type.bundle.unit-test` | `SnapshotTests.swift`, which constructs app views directly |

Re-derive instead of trusting this table:

```sh
grep -n 'productType\|name = "' POPOPX.xcodeproj/project.pbxproj | grep -A1 -B1 productType
```

Because the regression suite lives in an already-mounted file, adding a case never touches `.pbxproj` (a standing rule for this repo: no script may edit it).

## 2. An app build is not a test build

The normal gate is

```sh
xcodebuild build -project POPOPX.xcodeproj -scheme "POPOPX (iOS)" \
  -destination 'generic/platform=iOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
```

It prints `** BUILD SUCCEEDED **` **without compiling either test bundle**. A parameter added to a shared view's memberwise initializer therefore passed that gate and still broke `POPOPX Snapshots` (the `channelTable:` argument B5 added to `ChatView.ChatItemWithMenu` -- property at [`ChatView.swift#L1819`](../../Shared/Views/Chat/ChatView.swift#L1819), call site at [`#L1039`](../../Shared/Views/Chat/ChatView.swift#L1044)). Before shipping a change to any type the snapshots build:

- run `xcodebuild build-for-testing` (or `test`) with the flags in section 3, and
- `grep` the test directories for call sites of every initializer whose signature moved.

**A CLI compile and run of this bundle is reachable.** The older note that the `POPOPX (iOS)` scheme's test action "contains only `Tests iOS`", with `SnapshotTests` appearing 0 times in a full test log, is withdrawn: it is contradicted by the file itself and by the run below. `POPOPX (iOS).xcscheme` carries two `TestableReference` entries -- lines 31-40 (`BlueprintName = "Tests iOS"`, line 37) and lines 41-50 (`BlueprintName = "POPOPX Snapshots"`, line 47) of
`POPOPX.xcodeproj/xcshareddata/xcschemes/POPOPX (iOS).xcscheme`, and re-derive that with
`grep -n 'TestableReference\|BlueprintName' "POPOPX.xcodeproj/xcshareddata/xcschemes/POPOPX (iOS).xcscheme"`. So section 4's flags plus one `-only-testing` naming the
bundle type-check, install and run it:

```sh
xcodebuild test -project POPOPX.xcodeproj -scheme "POPOPX (iOS)" \
  -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath build/DerivedData \
  -only-testing:'POPOPX Snapshots/PopopxLocationPayloadTests' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

Measured 2026-11-21 on the tree that committed `PopopxLocationPayloadTests`: `** TEST SUCCEEDED **` with, verbatim, `Executed 24 tests, with 0 failures (0 unexpected) in 0.013 (0.021) seconds`. A run that reports
per-method results is itself the proof the bundle was compiled and hosted -- an *incremental* rerun prints no `SwiftCompile` line for `SnapshotTests.swift`, so `touch` the file
(or point `-derivedDataPath` somewhere fresh) when the log has to show the compile invocation.

What is still **not** reachable is the `-target 'POPOPX Snapshots'` route: `-target` forces every generated package project to use `<project>/build` as `SYMROOT`, and the Yams checkout ships a *read-only file* literally named `build`, so the build dies at

```
error: File exists but is not a directory: .../SourcePackages/checkouts/Yams/build/Release-iphonesimulator
```

`BUILD_DIR=` does not propagate to the package projects and `SYMROOT=` additionally corrupts the index-store flags (`failed creating index directory '-I…'`); `-derivedDataPath` is refused unless `-scheme` is passed. So when a signature moves, the cheap pre-check is still to reconcile it against the *declaration order* of the struct's stored properties at both call sites:

```sh
grep -rn "ChatItemWithMenu(" "POPOPX Snapshots/" Shared/   # Swift orders arguments by declaration
```

## 3. Code signing: the app group gate

**Required for any simulator run of `POPOPX (iOS)`:**

```
CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

`CODE_SIGNING_ALLOWED=NO` produces an ad-hoc, linker-signed bundle with **no app-group entitlement**. At launch `getGroupContainerDirectory()` force-unwraps `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` (`POPOPXChat/FileUtils.swift:65`), which returns nil without the entitlement, and the process dies with SIGTRAP before the first frame. Every leg then fails -- including legs that never touch the container -- and the failure reads like a locator bug rather than a build-flag bug. That is the single most expensive trap in this harness.

Do not "fix" it by hand-signing the built app:

```sh
codesign -f -s - --entitlements ... <app>   # leaves $(AppIdentifierPrefix) unexpanded
```

`xcrun simctl launch` then reports `FBSOpenApplicationServiceErrorDomain code 3`. Only `xcodebuild` expands that substitution variable while it resolves `POPOPX (iOS).entitlements`.

To separate "my locator is wrong" from "the product will not launch", install and launch on its own:

```sh
xcrun simctl install <udid> <path-to>.app
xcrun simctl launch <udid> com.popopxchat.popopx
xcrun simctl spawn <udid> launchctl list | grep popopx     # a PID within ~10 s = it lives
ls -t ~/Library/Logs/DiagnosticReports | head              # the .ips names the faulting symbol
```

## 4. Running the regression suite

```sh
xcodebuild test -project POPOPX.xcodeproj -scheme "POPOPX (iOS)" \
  -destination 'platform=iOS Simulator,id=<udid>' \
  -derivedDataPath build/DerivedData \
  -only-testing:'Tests iOS/PopopxChatRoomRegressionTests/testT0ShellAnchorsAndGroupKeepsLegacyComposer' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

- The target name contains a space, so quote the whole `-only-testing:` value; the path is `Target/Class/method`.
- `-derivedDataPath build/DerivedData` keeps `SourcePackages/` warm, so a re-run does not re-resolve the mesh packages.
- XCUITest runs methods **alphabetically**: `testT0…` before `testT4…`. T0 owns the group-chat fixture the other legs read, so a single-leg `-only-testing` of T2 does not reproduce what the full run sees.
- `skipped` is not `passed`. Each leg that cannot reach its precondition `throw XCTSkip`s with the reason, and the reason carries the measured hierarchy (`listShape(lookingFor:)`) so the next run does not have to guess again.

The anchors the suite navigates by (declared in the mounted view files, language-independent):

| Identifier | Declared in |
| --- | --- |
| `popopx.header.identity`, `popopx.header.plus` | `Shared/Navigation/PopopxTelemetryHeader.swift` |
| `popopx.inputBar.textField`, `.sendButton`, `.plusButton` | `Shared/Features/ChatRoom/PopopxInputBar.swift` |
| `popopx.bubble.channel` | `Shared/Features/ChatRoom/PopopxMessageBubble.swift` |
| `popopx.row` | `Shared/Features/Chats/ChatsListView.swift:784` |

## 5. Locator rules proven on device

Each of these produced a false result at least once on this repo:

- **`isHittable` throws on a clipped element** (`Activation point invalid and no suggested hit points based on element frame`). A bulk scan over the tree -- the filter chips, the header row -- dies with an instrument error and takes the case with it. Ask "is it drawn inside the window" instead (`onScreen(_:)`), and only then consider hitting it.
- **`tap()` on an off-screen element routes through `AXScrollToVisible`**, which can fail with `kAXErrorFailure`; a real overflow then surfaces as an unparseable AX error. Measure the frame first and fail with the numbers.
- **A SwiftUI `TextField` arrives with an empty `label`** -- the placeholder is in `value`, so `app.textFields["placeholder"]` finds nothing.
- **`app.sheets` reports 0 while a sheet is visible.** A sheet is not a signal for "am I under a modal"; on iPad it is a separate window (`375x1376@329,0`), which also breaks `coordinate(withNormalizedOffset:)`, since the offsets normalize against the wrong width.
- **`List` rows arrive as full-width `Button`s whose label is a concatenation** -- `B6 Carveout, Chat with admins: on, 19:57, SMP 在线加密` on the 375x812 shell, the same shape with other timestamps (`… 19:28 …`, `… 19:24 …`) on the 402x874 one, both from legs that passed -- and `app.cells` is **0**. The width test (`>= 0.6 * window.width`) is what separates a row from the tab bar, the header pills and the filter chips, all of which are far narrower. Anything comparing a captured label verbatim flakes once the clock crosses a minute: take the first comma-separated segment and re-find by prefix.
- **A modal presented *after* your last tap makes the screen underneath unreachable -- and `app.sheets` still says 0.** Creating a group pops a "This group is missing servers" card a second or two later; the single `tapAny(["Skip"])` that ran before it appeared tapped nothing, so `backToShell()` found no Back button, the edge swipe dragged the card instead of the stack, and the leg waited 20 s for a row that is plainly visible in the screenshot taken at the failure. While that card is up the list stops exposing its rows as buttons at all: `listShape` measured `cells=0`, three `staticText` hits for the title, and the only titled button a 220x32 nav-bar element at `59,56`. Poll for the card's own controls until one answers, then wait until they are gone -- do not read `app.sheets.isEmpty` as "no modal", and do not go hunting for a third row locator under a modal, because none exists.
- **A row that was on screen in the previous snapshot may not be on screen after returning to the list** (scroll position). Re-resolve it; if it cannot be found, record it as `lost` and continue rather than failing the case -- "not on this screen" is not a regression.
- **`value` on an empty SwiftUI `TextField` is the placeholder, not content.** Measured: `fields=['' value='Enter profile name...']` with the field untouched. Guarding "type only if the field is empty" on `!value.isEmpty` therefore never types, the CTA stays `en=0`, and the driver spins all 90 steps. Type unconditionally and gate the step with a flag. Since the 2026-11-19 onboarding rebuild that placeholder is localized (`How you appear to contacts` → 「你在联系人面前的显示名」), so resolve fields by index, never by that sample text.
- **`onScreen()` cannot tell "covered by the keyboard" from "disabled", so the stall dump has to print both.** On the 375x812 profile screen of the pre-rebuild layout `Create profile` sat at y=701 -- under the keyboard while it is up -- and the button reported `en=0` until a name existed; the CTA is now the localized `Next` / 「下一步」 and its coordinates were not re-measured. The page's own `.onTapGesture { hideKeyboard() }` (`Shared/Views/Onboarding/CreateProfile.swift:252`) is the dismissal to use: tap the title, do not guess at coordinates. `axDump()` exists because both of these cost a 2-minute run each to discover.
- **An early `return` when a fixture is missing reads as a green pass.** Fail or skip; never `return`.

## 6. What this suite cannot prove here

T1-T4 (bubble channel badge, attachment-only draft, reply strip, attachment preview strip) all need a 1:1 chat with an **active contact**. Adding a contact is a real SMP handshake against a peer on another device, so on a lone simulator those four legs skip by design and the run reports one passed / four skipped.

What a local run does prove:

- the whole app plus the `Tests iOS` bundle compile -- `POPOPX Snapshots` is *not* in this scheme's test action, so it needs the separate `-target` build in section 2,
- the app launches under the app-group entitlements,
- the shell's top bar keeps every one of its three segments inside the window with a >= 44 pt target on both ends (`assertHeaderFits`), and
- group chats keep the legacy composer, i.e. the B6 carve-out is still a carve-out.

The frames `assertHeaderFits` printed on the tree this doc ships with (verbatim log lines; each frame is `x,y` then `widthxheight`):

```
header fits window=0,0 402x874 popopx.header.identity=24,157 87x74 popopx.header.plus=334,172 44x44
header fits window=0,0 375x812 popopx.header.identity=24,135 73x94 popopx.header.plus=307,160 44x44
keeps the legacy composer (textView 48,743 310x39)   -- 402
keeps the legacy composer (textView 48,681 283x39)   -- 375
```

The mesh transport itself (CoreBluetooth on physical devices) is out of reach of this harness entirely.
