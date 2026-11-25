# POPOPX Chat — release history of this fork

> This file is **this fork's** release history. It was `CHANGELOG-POPOPX.md` until 2026-11-25, when it
> replaced upstream's `CHANGELOG.md` (whose last state is `git show 056aff908:CHANGELOG.md`); the
> versions below are the fork's own state, not upstream releases.
>
> **Files consolidated 2026-11-25.** Dated records in this file and in `FORK.md` name paths that no
> longer exist: `POPOPX-REBRAND-PLAN.md` was deleted, `CHANGELOG-POPOPX.md` became this file, and
> `ASSETS_LICENSE-POPOPX.md` / `AGPL-COMPLIANCE-POPOPX.md` lost the suffix. Those mentions are records of
> the state at the date in the sentence, not pointers to chase. Where such a sentence gave a live count,
> this note supersedes it with a measurement taken today: `git grep -o 'simplex:/' -- . | wc -l` = **17**
> occurrences in 6 files (6 here, 3 in `FORK.md`), and the 8 outside the two record files are
> `PopopxAddFriendView.swift` 3, `scripts/ci/check-brand-clean.sh` 2, `PopopxOfflineBridgeTests.swift` 2,
> `PopopxOfflineBridge.swift` 1. That replaces the 2026-11-16 figure of "4 occurrences in 4 files, none of
> them code": the old app-link scheme is now parsed in Swift, so the surplus is load-bearing, not residue.

## Unreleased — the badge link loses its upstream host and the What's New page its retired directory entries, 2026-11-25

- **iOS: `badgePageUrl` is now the technical display site.** `apps/ios/Shared/Views/Badges/BadgeStore.swift:36`
  read upstream's `https://badges.simplex.chat/…`; it now reads `https://popopx.chat`. The two buttons that
  follow it (`BadgesSupportPopopxView.swift:131` "Buy in browser", shown only when
  `badgeBrowserAllowed` says the storefront is the US, and `:140` "Choose your badge", the non-App-Store
  branch) therefore reach no payment page: in-app badge purchase is StoreKit (`badgeProductIds`,
  `PopopxStoreKitManager.swift`) and a link that could land on external token payment is the App Store
  §3.1.1 exposure this removes. A badge-portal URL was tried here first and never committed, so nothing
  shipped that pointed at it.
- **Desktop and Android keep the portal form.** `BadgeStore.kt:53-55` moved from `badges.simplex.chat` to
  `https://popopx.chat?app=true` / `?app=desktop`. The flag is a query parameter here, which is the whole
  difference from upstream's `#/tier?app=` fragment: a fragment never reaches the host, a query does.
- **Measured on the host side, same day** (`curl --noproxy '*'`): `https://popopx.chat`, `?app=true` and
  `?app=desktop` each answer `200` with the same 125,159-byte page; `popopx.chat/badge` answers `404`;
  `node.popopx.chat/badge` answers `200` but serves the Mac Node SPA, whose bundle contains no `/badge`
  route and reads no `app` parameter. So the links reach our own host and not a checkout — the badge
  storefront is still to be deployed. `git grep -In 'badges\.simplex\.chat'` now reads 0 in code and
  resources.
- **What's New no longer advertises the directory service.** The two entries that pointed at it were
  deleted: iOS `apps/ios/Shared/Views/Onboarding/WhatsNewView.swift` (the v5.3 "Discover and join groups"
  and v5.5 "Join group conversations" blocks) and desktop
  `apps/multiplatform/common/src/commonMain/kotlin/chat/popopx/common/views/onboarding/WhatsNewView.kt`
  (the matching `FeatureDescription` blocks). iOS keys a localization on its English literal, so 28 key and
  value lines carrying the upstream directory address went out of the 15 shipped `.lproj` catalogs in the
  same commit; each catalog still passes `plutil -lint`. The four now-unreferenced moko keys were left
  where they are (0 code readers), because deleting a resource across 28-32 locale files is its own ruling.
- **No snapshot baseline moved.** The rendered What's New page is the *last* entry of the array
  (`@State currentVersion = versionDescriptions.count - 1`), and both deletions were mid-array, so neither
  the page nor its neighbour label can change; no baseline file is named for this view. The CI `ios-sim`
  snapshot job is the empirical check.
- **The brand gate gained two extensions.** `*.pbxproj` and `*.entitlements` joined
  `scripts/ci/check-brand-clean.sh`'s `--include` list, in both its greps. The premise that they match
  nothing was wrong — they hit 11 and 2 lines — so each got a path-anchored exemption instead of an edit:
  the `NSHumanReadableCopyright` and `SimpleX-{NSE,SE}` bundle ids and the WebRTC `repositoryURL` in
  `project.pbxproj`, and the `applinks:*.simplex.im` associated-domain entries. `project.pbxproj` was not
  touched, verified by sha256 before and after the builds. The includes are live, not decorative: a planted
  `probe.entitlements` and a planted `Probe.xcodeproj/project.pbxproj` each made the gate exit 1.
- **Census, stated as a scope.** The gate prints **1396** in a working tree and **1358** over tracked files;
  the repo-wide raw scan is **1941 lines / 513 files**. The gap is fully itemised, with the commands, in
  `FORK.md` § “How the brand census is measured” and summarised in `AGPL-COMPLIANCE.md` § 2.
- **The desktop test mirror moved with it.** `commonTest/kotlin/chat/popopx/app/BadgePageUrlTest.kt`
  asserted both URLs end with upstream's `#/tier?app=…` **fragment**, which the query form cannot satisfy.
  It now asserts the query ending *and* that no `#` survives — `endsWith("?app=true")` alone would still be
  true of the fragment form, so the fragment test is the load-bearing half. CI found what a compile check
  cannot: `:common:desktopTest` on `a90dbbaf9` reported **256 tests completed, 2 failed**, exactly these
  two. After the mirror moved, the same suite on this machine reports 256 tests, 0 failures, 0 errors,
  5 skipped, with `BadgePageUrlTest` 2/2.
- **Verification.** `./scripts/ci/check-brand-clean.sh` exit 0 and `./scripts/ci/check-smp-links.sh` exit 0;
  the gate's coverage total is **1358** on a clean checkout — measured three ways (`git grep`, a throwaway
  `git worktree` at this tip, and the CI `Brand compliance` job log) — and 1396 in a working tree.
  `xcodebuild build -scheme "POPOPX (iOS)" -destination generic/platform=iOS` → `** BUILD SUCCEEDED **`,
  0 `error:` and 0 `warning:` in the log, with `strings` on the linked binary reading 0
  `node.popopx.chat` and 0 `badges.simplex.chat`, and CI's `macos-latest (iOS)` job green;
  `./gradlew --no-daemon :common:compileKotlinDesktop` → `BUILD SUCCESSFUL in 1m 25s`, the only warning in
  a touched file being the pre-existing `LocalClipboardManager` deprecation at `WhatsNewView.kt:1010`.

## v1.2.0 — 2026-11-24

**POPOPX adopts independent product versioning,脱离上游 7.1.x 编号体系。**

- 对外产品版本号统一升级为 `1.2.0`（Android `versionName`、Desktop `version_name`）
- 底层 SMP/XFTP 协议握手版本与数据库 Schema 版本保持不变，确保与已部署的 15 节点双栈服务器 100% 兼容
- iOS `MARKETING_VERSION` 由用户在 Xcode Build Settings 中手动更新为 `1.2.0`
- 此版本包含：badgeService 死代码清理、引导页文案更新（无云端账号备份提醒）、POPOPX Relay 1 完整地址配置

## Unreleased — quitting and reopening killed the app: preset rows outside the operator's domains were re-inserted on every start, 2026-11-24

- **The symptom, reported as 闪退.** After onboarding created a user, quitting and reopening the app died
  before the interface appeared: the console printed
  `popopx: SQLite3 returned ErrorConstraint while attempting to perform step: UNIQUE constraint failed: protocol_servers.user_id, protocol_servers.host, protocol_servers.port`
  and the launcher reported `The app terminated with the exit code 1`. The `progName:` prefix is the GHC RTS
  uncaught-exception path, which prints and calls `stg_exit(EXIT_FAILURE)` — so nothing after it runs, which
  is what a user sees as a crash on the splash. A launch before a user exists is clean (the simulator's first
  launch after install exited 0), so this is a second-and-later-launch failure: deleting the app made it
  disappear, reinstalling brought it back once a profile was created.
- **The mechanism is in the preset lists, not in the schema.** `newChatController` (`Chat.hs:146`) runs
  `agentServers` (`:288-295`) through `withTransaction chatStore` at `:163` on every start; `:308` hands each
  group's `updatedUserServers` result to the **unchecked**
  `setUserServers'` (`Store/Profiles.hs:1016`) — the `checkConstraint SEUniqueID` wrapper at `:1013`
  exists but is not what this call site uses, so the constraint violation propagates. Inside the comparison,
  `groupByOperator_` (`Operators.hs:500-517`) files the *stored* rows by `matchingHost` over the operator's
  `serverDomains` and appends a separate operator-less `"custom"` bucket (`:511`), while
  `updatedUserServers` (`:415-437`) compares the operator's **full** preset list against only that group's
  stored rows (`:423-425`), emitting `AUS SDBNew` from `userServer` (`:437`) for any preset row the group
  does not hold. A preset row whose hosts are outside `serverDomains` is therefore never seen in
  the group, comes back as `AUS SDBNew`, and `upsertOrDeleteSrv`'s `DBNewEntity` branch (`Profiles.hs:1024-1027`)
  takes the plain `INSERT` path (`insertProtocolServer`, `:685-694`) for a row the store already holds.
  The store round-trip is symmetric (`getProtocolServers` `:666-683` reads `host`/`port` straight out of the
  columns), so this is not an encoding or key-mismatch: the offered list and the domain list disagree.
- **Which rows: the upstream hosts offered below the domain.** `operatorSimpleXChat.serverDomains` is
  `["popopx.im"]` (`Presets.hs:22`), while HEAD's `simplexChatSMPServers` concatenated
  `enabledSimplexChatSMPServers` (9 rows) **and** `disabledSimplexChatSMPServers` (3 rows on
  `smp4/5/6.simplex.im`) — 12 offered rows, 3 of them unroutable into the operator group, so those 3
  collided on every start. `disabledSimplexChatSMPServers` has no reader outside this file
  (`git grep -n 'disabledSimplexChatSMPServers' -- '*.hs' '*.swift' '*.kt'` answers three sites in
  `Presets.hs` and nothing else: `allPresetServers`, HEAD's offered-list line, its own declaration) and
  `simplexChatSMPServers` has exactly one non-test reader (`Chat.hs:87`), so that concatenation was the
  only route by which those rows reached a user.
- **The fix keeps the offered list where the comparison looks.** `simplexChatSMPServers`
  (`Presets.hs:54-55`) now offers only the 8 `smpN.popopx.im` rows, all covered by `serverDomains`. The
  invariant, its consequence and the exception text are written into the comment above that definition so
  the next row added here is checked against the domain list rather than shipped into a crash. Nothing was
  deleted: `allPresetServers` (`:34-41`) still carries the disabled, legacy and flux hosts, because
  `shortLinkPresetServers = allPresetServers` (`Chat.hs:101`) is what resolves links that were already
  issued on them, and dropping a row does not delete it for users who already have it (`setUserServers'`
  only iterates what it is handed).
- **relay1.popopx.im was in the wrong list, per the ruling**
  「smp://04Mm3i26SSyFmrSe6h8NSXZ7bIGsUAVyQ7o6abUJbLw=@relay1.popopx.im,5ui7syydfqzvyjy6vwuy726rwxdsa5ow4esnfln2lhevduyuamcdvqqd.onion:5227
  这个是应该在 聊天中继服务器（relay）里，不是在 消息服务器（smp）里」.
  The dependency's own cluster record says the same thing, and it is the authority for what the cluster is:
  `NOTICE` lines 367-372 of the pinned source (`dist-newstyle/src/popopxmq-*/NOTICE`) - "the published set is
  fifteen relays - eight SMP (`smp1..8.popopx.im`, no port, because 5223 is the protocol default), **one chat
  relay (`relay1.popopx.im`, `:5227`)**, three file relays (`xftp1/6/8.popopx.im`, `:8443`) and three
  notification relays (`ntf1..3.popopx.im`, `:5226`)" - and that same file puts relay1's host-to-onion pair in
  `extraSMPServerHosts` (`src/Popopx/Messaging/Agent/Protocol.hs:1416`, nine `.popopx.im` pairs in that block,
  which is a dependency file: `git grep -o '\.popopx\.im' -- src/Popopx/Messaging/Agent/Protocol.hs | wc -l`
  answers 0 here — note the `| wc -l`, since `git grep -c` on a path that is not in the index prints nothing
  *and exits 1*). Consistent with it, the row that was removed was the **only port-bearing SMP row** in
  `enabledSimplexChatSMPServers`: 1 of 9 carried `:5227`, the other 8 are port-less and therefore dial 5223.
  Its address is gone from that list.
  Re-measuring the shipped addresses over `src/Popopx/Chat/Operators/Presets.hs` and
  `src/Popopx/Chat/Library/Commands.hs` with the recipe recorded in the 2026-11-23 entry now answers **14**
  `popopx.im` addresses (8 SMP + 3 XFTP + 3 NTF) where that entry recorded 15, and the whole preset table in
  `src` goes from 36 unique addresses to 35 with a symmetric diff of exactly one line — the relay row, nothing
  added. The HEAD side is one command:
  `git show $(git ls-tree -r --name-only HEAD -- src | grep '\.hs$' | sed "s|^|HEAD:|") | grep -hoE '"(smp|xftp|ntf)://[^"]+"' | sort -u`.
  The working-tree side needs the file list piped through a loop rather than into `cat`, because zsh does not
  word-split an unquoted expansion and `cat $files` fails with *File name too long*:
  `git ls-tree -r --name-only HEAD -- src | grep '\.hs$' > /tmp/hs.txt` then
  `while IFS= read -r f; do grep -hoE '"(smp|xftp|ntf)://[^"]+"' "$f"; done < /tmp/hs.txt | sort -u`, and
  `comm -23` / `comm -13` between the two sorted files answer one line and none.
  Two places still name `relay1.popopx.im` as a host, and neither was touched: two comment lines in
  `Presets.hs`, and `apps/multiplatform/android/src/main/AndroidManifest.xml:119`, where the intent filter
  pairs every listed host with the app's own link paths (`/invitation`, `/contact`, `/a`, `/c`, `/g`, `/i`).
  Whether that relay answers those paths on that host is a question about its web front end and is outside
  this fix; iOS needs no equivalent decision because its entitlements list the wildcard `applinks:*.popopx.im`
  (`apps/ios/POPOPX (iOS).entitlements:14`) rather than per-host entries.
- **The relay row cannot be preset from this repository, and that is the open item.** A chat relay is not an
  `smp://` server identity: `presetChatRelay` (`Operators.hs:356-357`, which is `newChatRelay_` `:364-365`)
  builds a `NewUserChatRelay` whose
  address is a `ShortLinkContact`, i.e. `https://<host>/r#<LinkKey>` — that key is minted by the relay
  process when the link is created and is in neither repository. `simplexChatRelays`
  (`Presets.hs:130-131`) therefore
  stays `[]`, and the visible consequence is that the group-relay picker, which lists
  `op.chatRelays` (`apps/ios/Shared/Views/Chat/Group/AddGroupRelayView.swift:96`), shows nothing. **需要你决定:**
  hand over the relay's `/r#` contact address and it becomes a preset row.
- **The regression gate is now a test, not a census.** `tests/OperatorTests.hs` gained
  `"storing every preset server leaves nothing to add on the next start"` inside `updatedServersTest`: it
  feeds `groupByOperator'` exactly what a start would store (every offered SMP and XFTP preset row with ids)
  and asserts that the next start's `updatedUserServers` returns **no** `AUS SDBNew` row — which is precisely
  the value that reaches `insertProtocolServer`. It is run by CI (`build.yml:1255`,
  `cabal test --test-show-details=direct` in `build-macos` on every push to master), so a future row that
  breaks the invariant fails there instead of killing installs. The red side of the same invariant was
  measured statically, not by running this spec against the old table: the offered-list-vs-`serverDomains`
  census answers **12 hosts / 3 outside the domains** (`smp4/5/6.simplex.im`) at HEAD and **8 / 0** here.
  That census is committed as `scripts/ci/preset-domain-invariant.py`, which reads the lists
  `simplexChatSMPServers` names and the `serverDomains` list out of `Presets.hs` and exits non-zero when a
  host falls outside - `python3 scripts/ci/preset-domain-invariant.py HEAD` (exit 1, `outside=['smp4…','smp5…','smp6…']`)
  against `python3 scripts/ci/preset-domain-invariant.py` (exit 0) is the red/green pair, and it needs no
  build. An earlier form of this recipe, a `sed` range over the same file, was published here and is wrong:
  its end address never matches, so it printed the rest of the file instead of the offered list.
  That census is the discriminator; the spec is the keeper. The keeper ran here:
  `cabal test --test-show-details=direct popopx-chat-test --test-options='--match="managing server operators"'`
  answers **19 examples, 0 failures** (`Test suite popopx-chat-test: PASS`, exit 0) with
  `storing every preset server leaves nothing to add on the next start [✔]` named in the output; 19 because
  the file held 18 `it` blocks before this one was added
  (`git show HEAD:tests/OperatorTests.hs | grep -c '^ *it "'` answers 18, the same count on the working tree
  answers 19 — that pair is a file census, not a second test run). The first attempt at this run did **not**
  compile: comparing the rows
  themselves (`filter isNewServer … shouldBe []`) needs `Eq (AUserServer p)`, which does not exist, so the
  assertion is on counts and on the SMP hosts the helper extracted. Unverified: the spec was not executed
  against the pre-fix table (that would be a second full rebuild of the library); the red side rests on the
  census and on the app-level repro.
- **Getting there needed the iOS UI test harness repaired.** Reproducing the abort meant driving onboarding
  to a created user, and `apps/ios/Tests iOS/Tests_iOS.swift` had been left behind by the fork's v2 copy: its
  onboarding walk found nothing to tap and stalled at `POPREG[shell] UNREACHABLE after 90 steps`. Three edits
  (the action probe at `:260-263`, the keyboard release at `:278-281`, the page guard and field prompts at
  `:295-302`) taught it the v2 copy: the first screen's only forward action is `Create encrypted identity`
  (`OnboardingView.swift:94`), the second screen's field is `Anonymous name` with prompt
  `How you appear to contacts` (`:105-106`, `CreateProfile.swift:396-397`) and its bar button is `Next`
  (`:116`) — that button is enabled from the name and the field closes the keyboard through `onSubmit`
  (`CreateProfile.swift:400`), so the walk sends Return rather than tapping a disabled button. This is
  test-side only — no app behaviour was changed to make the walk work, and these are the same helpers the
  existing onboarding tests share. After it the walk reported `POPREG[step 1] tapped 'create-identity'`,
  `step 2 tapped 'profile-name'`, `step 3 tapped 'Next'`, and the user existed.
- **Verified.** (1) **On the real iPhone 15 Pro**, a relaunch after onboarding died in the console with
  `popopx: SQLite3 returned ErrorConstraint while attempting to perform step: UNIQUE constraint failed: protocol_servers.user_id, protocol_servers.host, protocol_servers.port`
  followed by `The app terminated with the exit code 1` — captured with `devicectl device process launch
  --console --terminate-existing`, which is the reported 闪退 reproduced with its own message. (2) The same
  message on a simulator relaunch (`simctl launch --console-pty` after the repaired UI walk had created the
  user), which shows it is the code and not the device. (3) The static invariant census in the gate bullet:
  12 offered hosts / 3 outside `serverDomains` at HEAD, 8 / 0 here. (4) The shipped preset addresses: the
  whole-`src` symmetric diff HEAD→here is exactly one line, the relay row
  (`36 → 35` unique `smp://`/`xftp://`/`ntf://` addresses, `ONLY_IN_HEAD` only, nothing added). (5) The
  installed iOS core slices still carry the old table, measured rather than assumed: all four answer the
  relay key `04Mm3i26…` once each, and 69 / 67 distinct hosts per flavour.
- **Not verified.** The app has not been run with the fixed preset table: the archives above are the ones the
  device build links, so the installed app still crashes until they are rebuilt and relinked, and no fresh
  install → quit → relaunch sequence has been re-run on the device since the fix. No stored-row inspection
  after the fix either. The fix is verified at the level the crash lives in — the list the comparison reads —
  by the census and by the app-level repro of the failure, not by a passing device session.
- **Why the archives are not rebuilt yet, measured on 2026-11-24.** The Nix route is blocked by egress that
  this repository cannot fix: `nix build '.#"aarch64-darwin-ios:lib:simplex-chat"'` dies inside 5 s with
  `Failed to connect to cache.nixos.org:443 over proxy 127.0.0.1`, and `--offline` reaches the same wall from
  the other side (`Cannot build '…cpio.drv' … unable to download 'http://tarballs.nixos.org/…/cpio': …
  over proxy 127.0.0.1:10904`) because the bootstrap closure is no longer in the store - `ls /nix/store |
  grep -E 'pkg-ios|aarch64-apple-ios'` answers **0**, so nothing from the 04:55 build survives to be reused.
  The proxy is not in the client environment (`env | grep -i proxy` = one dead `ALL_PROXY=…:10020`, cleared by
  `unset`; `scutil --proxy` = all `…Enable : 0`; `launchctl getenv HTTP(S)_PROXY` = empty; nothing in
  `/etc/nix/nix.conf`, `/etc/nix/nix.custom.conf` or `~/.config/nix/nix.conf`): it is in the
  **daemon's own launchd environment** - `plutil -p /Library/LaunchDaemons/systems.determinate.nix-daemon.plist`
  lists `http(s)_proxy = http://127.0.0.1:10904` and `ALL_PROXY = socks5h://127.0.0.1:10021`, both stale.
  Direct egress from a normal process works (`curl --noproxy '*' -sS -o /dev/null -w '%{http_code}'
  https://cache.nixos.org/nix-cache-info` = 200), so the substitution would succeed if the daemon were
  restarted without those variables - which is a root-owned system service, so it is **not** something this
  commit does. The route taken instead needs no local egress at all: `ios-sim.yml` builds the core with
  `scripts/ci/ios-sim/build-core.sh` and uploads it under
  `ios-sim-core-${{ hashFiles('src/**', 'cabal.project', 'popopx-chat.cabal', 'scripts/ci/ios-sim/build-core.sh') }}`,
  so pushing the fix changes the artifact name, forces `BUILD_CORE=true`, and the archive can be downloaded
  with `gh run download <run-id> -n ios-sim-core-<hash> --repo popopx-chat/popopx-chat`. That zip is built by
  host `cabal`, not Nix, and it is still safe for a device launch because the reservation is neutralised in
  the app target rather than the library: `apps/ios/POPOPXChat/hs_init.c:18/:33/:50` pass `-M512m` to
  `hs_init_with_rtsopts` in all three entries, so the RTS never takes GHC's darwin default. After installing
  a cabal-built pair, re-run the gates from the 2026-11-24 entry - the relay key `04Mm3i26…` must read **0**
  in all four core slices, `grep -a -o -E 'relay1\.popopx\.im'` likewise, and the host census must be
  re-measured rather than predicted.

## Unreleased — the iOS libraries are built by Nix with the large-address-space reservation compiled out, 2026-11-24

- **The device crash was a GHC *configure*-time choice, not an RTS flag.** A launch on device aborted with
  `memory allocation failed (requested 274878955520 bytes)`. That number is arithmetic, not a tuning value:
  `rts/sm/MBlock.c:660-672 initMBlocks()` sets `size = (W_)1 << 38` = 274,877,906,944 (256 GiB) for aarch64
  under `#if defined(USE_LARGE_ADDRESS_SPACE)`, and `posix/OSMem.c` asks for `len + MBLOCK_SIZE` (1 MiB) on
  top of it. `configure.ac:1065-1102` turns LAS on by default for a 64-bit host with `ghc_host_os=darwin`, so
  a host-`cabal` build inherits the reservation; `my_mmap` failing on darwin prints the message and calls
  `stg_exit(EXIT_FAILURE)` (`posix/OSMem.c:210`), which is why the shrink-and-retry path never runs on iOS.
  The lever is the configure flag `--disable-large-address-space`, which `flake.nix:127` already requests via
  `smallAddressSpace = true` — the two `.drv` files read `configureFlags` containing it
  (`nix show-derivation` on the ghc-9.6.3 and ghc-9.2.8 drv), so the Nix job was the fix and no flag list is.
- **Caution against reading the disassembly as a size.** The old object's `cmp x0,#0 / mov x8,#0x4200000000 /
  csel x20,x8,x0,eq` sequence is the *start address* hint (264 GiB) feeding the `startAddress < minimumAddress`
  check at `posix/OSMem.c:520-523` (`osReserveHeapMemory(void *startAddressPtr, W_ *len)`), not a heap size,
  and `+RTS -M` does not influence the reservation at all.
- **What was built and installed.** `nix build '.#"aarch64-darwin-ios:lib:simplex-chat"' --no-link
  --print-out-paths` answered `/nix/store/q5c2x8acp6w04slbm42cah9zmpj3zc9j-popopx-chat-lib-popopx-chat-7.1.2.0`
  (recorded in `/tmp/nix_ios2.log`), whose `pkg-ios-aarch64-swift-json.zip` held the five archives already named
  as `project.pbxproj` expects. **That store output has since been reclaimed, so the durable measurement is the
  installed tree, not the zip**: `libffi.a` 53,088 / `libgmp.a` 847,864 / `libgmpxx.a` 32,816 /
  `libHSpopopx-chat-7.1.2.0-2pJp6QhAZjZInPLhny3S4B-ghc9.6.3.a` 324,793,904 (md5
  `3066ce4643834cfb227b46af6d856cb8`) / `…-7.1.2.0…B.a` 91,760,512. Do not read `/tmp/pkg-ios-aarch64-swift-json.zip`
  (78,093,927, 2026-11-23 20:57) as this build — it is the host-`cabal` zip that this pass replaced. The slices
  went to `apps/ios/Libraries/ios/` as produced and to `apps/ios/Libraries/sim/` through
  `apps/ios/Libraries/patch_iossim.py` (the flake has no `aarch64-darwin-ios-simulator` attribute), then
  `python3 scripts/ios/set-minos.py 17.0` over all ten archives. `scripts/ios/prepare.sh` was not used: it needs
  the absent `mac2ios` and a `~/Downloads` this CLI cannot write. No `result-*` symlinks exist, because
  `--no-link` was passed.
- **The allocator gate is a binary symbol count with a live control, not a grep for a magic number.**
  `#if defined(USE_LARGE_ADDRESS_SPACE)` encloses both reserve functions, so the compiled-out archive must
  lose the symbol. Census over **all five** archives in both slices, new versus the replaced (`_osGetMBlocks`
  is the must-be-true control proving the tables are greppable):

  ```sh
  for f in apps/ios/Libraries/{ios,sim}/*.a; do
    printf '%s %s\n' "$f" "$(grep -a -o '_osReserveHeapMemory' "$f" | wc -l | tr -d ' ')"
  done   # old core -ghc9.6.3.a = 3 in ios AND sim; every new archive = 0
  ```

  Independently, `ar x <core> MBlock.thr_o OSMem.thr_o` then `xcrun objdump -d MBlock.thr_o | grep -c
  0x4000000000` gives old 1 / new 0 for both slices, and `OSMem.thr_o` shrinks 7,648 to 4,840 (ios) and 4,848
  (sim) bytes. Note `nm` under-reads the `patch_iossim.py` output *archive* (reads 0 even where the bytes are
  there), which is why the raw-byte census is the primary instrument and the extracted member is what `nm` and
  `objdump` are trusted on.
- **The 15 cluster nodes and the derivation labels survived the rebuild.** The load-bearing claim is set
  identity, not volume, and both sides re-derive from one pass each:

  ```sh
  b=libHSpopopx-chat-7.1.2.0-2pJp6QhAZjZInPLhny3S4B-ghc9.6.3.a
  LC_ALL=C grep -a -o -E '[a-zA-Z0-9]+\.(popopx|simplex)\.im|[a-zA-Z0-9]+\.onion' \
    apps/ios/Libraries/ios/$b | sort -u | wc -l     # 69
  ```

  NEW and the replaced tree both answer **69 distinct hosts = 15 `popopx.im` + 17 `simplex.im` + 37 `.onion`**,
  with `comm -23` and `comm -13` between the two sorted lists both empty, and the 15 are exactly ntf1-3, relay1,
  smp1-8, xftp1/6/8. *Re-measured 2026-11-24: this census describes the installed archives, which still
  predate the preset fix - all four core slices answer 69 (the `-ghc9.6.3` flavour) and 67 (the plain one)
  distinct hosts with the relay1 key `04Mm3i26…` present once each. After the next rebuild relay1 must read
  0 in all four; the resulting totals are to be re-measured with this same recipe, not predicted.*
  `o5vmywmrnaxalvz6` is present in both. Under the same regex the *occurrence* counts do fall
  (28 to 27, 27 to 23, 52 to 49), which is duplicate call sites being folded, not a host being lost — do not
  quote a count as a coverage claim. The derivation label reads branded **1** / upstream **0** per slice, and the
  arithmetic control `SbChainInit` total = branded + upstream holds (1 = 1 + 0 in both `ios` and `sim`); the
  branded form is what the pinned `0c9141f9` produces (`src/Popopx/Messaging/Crypto.hs:1511`), so no wire-label
  split was introduced.
- **minos and the link.** Device objects carry the *legacy* `LC_VERSION_MIN_IPHONEOS version 17.0 / sdk 17.0`
  (3,634 occurrences in the core archive) and simulator objects carry `LC_BUILD_VERSION platform 7 / minos 17.0
  / sdk 17.0` (3,634), which is why a `platform`/`minos` census on the device slice reads blank while `sdk` reads
  17.0 — the two slices are gated with different `otool -l` field names, and neither shows `27.0` anywhere (0 in
  all five archives). The arithmetic control is `version commands == objects`: `ar t` reports 3,635 entries, of
  which one is `__.SYMDEF`, leaving 3,634 objects each with exactly one version command.
  `xcodebuild build -project apps/ios/POPOPX.xcodeproj -scheme "POPOPX (iOS)" -destination
  'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` answers `** BUILD SUCCEEDED **` with **0** `was built for
  newer 'iOS' version` warnings, and the linked leaves are `platform IOS minos 17.0 sdk 27.2` (27.2 is the Xcode
  SDK the app sources were compiled against, not a library claim) with `_osReserveHeapMemory` = 0 and
  `_osGetMBlocks` = 1 in `POPOPXChat.framework/POPOPXChat` — the RTS that reaches the binary is the
  compiled-out one.
- **`hs_init.c` gains `-M512m` in all three entries, and it is an operational cap, nothing more.** The
  per-target `-A`/`-H` tuning documented at `apps/ios/README.md:39-42` (main 64 MB, NSE 512 KB, SE 1 MB) is
  kept; the flag list from the brief (`-H32m -A8m -n2m -I0`) would have overwritten it. What `-M512m` does is
  make exhaustion observable: `RtsFlags.c:1890-1894` raises the cap to `-H`'s suggestion if `-H` is larger, and
  `:1896-1901` refuses `-M` below `-A` with an `errorBelch` plus a clamp. Then `Schedule.c:1626` computes
  `mblock_overflow` from `maxHeapSize` under the comment "We will either return memory until we are below
  maxHeapSize or trigger heapOverflow" — so an over-cap allocation aborts with an RTS message instead of being
  jetsam-killed silently. `argc` moved 5 to 6, 7 to 8, 7 to 8 and was verified against the literal entry counts;
  `xcrun -sdk iphoneos clang -arch arm64 -fsyntax-only -Wall` is clean.
- **Unverified, so nobody reads more into this than it shows.** No device was launched, so the crash itself is
  proven fixed only statically (the reservation is not in the linked binary). The simulator build was not
  re-run this round; only the device link was exercised. The `.drv` reads show `--build/--host/--target` all
  `aarch64-apple-darwin`, i.e. this "iOS" job is still not a true cross-compile — it is a host build with the
  iOS platform load commands rewritten by the toolchain, which is exactly why the minos census is load-bearing.

## Unreleased — the desktop RTS glob matches GHC 9.6.3's versioned dylib, 2026-11-23

- **`apps/multiplatform/common/src/commonMain/cpp/desktop/CMakeLists.txt:73` was changed by ruling, and the
  line is the whole story.** It globbed `libHSrts*_thr-*.${OS_LIB_EXT}` upstream; the worktree version being
  tested read `libHSrts_thr-*`, and that form **cannot match** what `scripts/desktop/build-lib-mac.sh` copies
  today, because the producer's copy step (`:87`, `cp "$RPATH/$DYLIB" ./deps`, i.e. whatever `libpopopx.dylib`
  actually links against) lands `libHSrts-1.0.2_thr-ghc9.6.3.dylib` in `libs/mac-aarch64/` — a dash and a
  package version between `libHSrts` and `_thr`. `RTSLIB` therefore globbed empty and
  `set_target_properties(rts PROPERTIES IMPORTED_LOCATION ${RTSLIB})` on the next line got nothing. The line now
  reads `libHSrts-*_thr-*.${OS_LIB_EXT}`: the `-` anchors the version dash, so it matches the versioned library
  and, unlike upstream's `libHSrts*_thr-*`, can never match a versioned and an unversioned RTS in one tree (the
  two-hit case that `set_target_properties` also rejects).
- **The three patterns were measured against the real CMake engine, not argued.** `cmake -P` with
  `OS_LIB_PATH=mac OS_LIB_ARCH=aarch64 OS_LIB_EXT=dylib` (as `CMakeLists.txt:20-39` sets them) reported
  `libHSrts*_thr-*` → 1 file, `libHSrts_thr-*` → **0 files**, `libHSrts-*_thr-*` → 1 file. A bare
  `cmake -S …/cpp/desktop -B /tmp/cmake_probe` with the fixed line configures and generates (exit 0) and writes
  `libHSrts-1.0.2_thr-ghc9.6.3.dylib` into `CMakeFiles/app-lib.dir/link.txt`; the same probe with
  `libHSrts_thr-*` **exits 1** and writes nothing.
- **One caveat about the `packageDmg` run, recorded so nobody reads more into it than it shows.**
  `./gradlew --no-daemon packageDmg` finished in 54 s with `BUILD SUCCESSFUL` and wrote a
  fresh `apps/multiplatform/release/main/dmg/POPOPX-7.1.2.dmg` (236,261,998 bytes, 22:33 — up from
  177,854,983, because the Haskell libraries under it were rebuilt at 20:14 the same day), and
  `desktop/build/cmake/main/mac-aarch64/libapp-lib.dylib` was relinked at 22:33 carrying
  `@rpath/libHSrts-1.0.2_thr-ghc9.6.3.dylib` with `hs_init` still undefined-by-design. But its
  `CMakeCache.txt` is dated 20:28, so Gradle reused the earlier configure: **that green is the relink, not the
  glob.** The glob itself is proven by the scratch configure and the three-way probe above. The 11:34 DMG was
  moved to `/tmp/POPOPX-7.1.2.dmg.pre1134` before the run so the artifact at the canonical path is the new one.
- **`libs/` and `release/` are both gitignored** (`apps/multiplatform/.gitignore:14` and `:20`), so this commit
  is the one CMake line plus this entry; `CMakeLists.txt.bak`, which still holds the pre-edit line 73, is an
  untracked working file and was left alone.
- **Not verified by this pass.** Nothing else in the desktop chain was re-gated: `packageDmg` produced no new
  notarization or installation test, and no Linux or Windows tree exists here to confirm the same pattern under
  `OS_LIB_EXT=so`/`dll` (their `libHSrts` naming is GHC's, so it should hold, but it was not measured).

## Unreleased — every iOS library object now claims `minos 17.0`, and the device link is proven clean, 2026-11-23

- **What the noise was.** `xcodebuild build -scheme "POPOPX (iOS)" -destination 'generic/platform=iOS'
  CODE_SIGNING_ALLOWED=NO` succeeded but emitted **2212** repetitions of
  `ld: warning: object file (…/apps/ios/Libraries/ios/libHSpopopx-chat-…a[NNN]) was built for newer 'iOS'
  version (27.0) than being linked (17.0)` (baseline log `/tmp/xb_before.log`: exit 0, `** BUILD SUCCEEDED **`,
  2215 warnings = 2212 version + 3 unrelated `Metadata extraction skipped`). ld prints one line per linked
  *member index*, so the count is per object, not per library; attributing it gives 2008 from
  `libHSpopopx-chat-7.1.2.0-…-ghc9.6.3.a`, 199 from `libgmp.a`, 5 from `libffi.a`, and they all come out of one
  step — `Ld …/Debug-iphoneos/POPOPXChat.framework/POPOPXChat`, whose command line carries
  `-L/Users/elliot/popopx-chat/popopx-chat/apps/ios/Libraries/ios`. The Haskell archives are linked into the
  framework, not into the app binary.
- **The cause is in `mac2ios`, and it is upstream's design, not a mis-use.** `zw3rk/mobile-core-tools`'
  `mac2ios.c` walks the archive members and writes only `build_version_command.platform` (or rewrites the
  `LC_VERSION_MIN_MACOSX` command id) — it never touches `minos` or `sdk`, so every object keeps the host
  build's values. The tree measured before this fix claimed `minos 27.0` on 2894 objects of the big archive
  plus 1377 at `11.0`, and `27.0` on all objects of the other four.
- **`scripts/ios/set-minos.py` is new** and rewrites those two 32-bit fields for every object of every
  archive, in place. It is wired into `scripts/ios/prepare.sh:15-19` and `scripts/ios/prepare-x86_64.sh`,
  i.e. straight after the `mac2ios` loops, so an archive produced by either route is correct from the start;
  the version is `${IOS_MINOS:-17.0}`, deliberately in step with `IPHONEOS_DEPLOYMENT_TARGET`, and the
  comment says so because that pairing is the whole point.
- **Two deviations from the obvious recipe, both forced by these files.** The task asked for
  unpack → `vtool` → `ar r` + `ranlib`, and that route is not safe here: `ar -t` on
  `libHSpopopx-chat-…-ghc9.6.3.a` lists 4272 members of which **312 names are duplicated** (GHC emits flat
  names), so `ar -x` would overwrite them into each other and the rebuilt archive would silently lose
  objects; separately, `xcrun vtool` refuses an archive outright — `file is not mach-o` — so it can only run
  per extracted object. `set-minos.py` therefore parses the `!<arch>` container itself (60-byte headers,
  BSD `#1/<len>` long names, `__.SYMDEF` skipped, members padded to even) and writes each 4-byte word at its
  offset, which leaves size, member order, member names and the symbol table untouched. Header offsets that
  matter: `mach_header` and `mach_header_64` both put `ncmds` at +16 and `sizeofcmds` at +20, and their
  headers are 24/32 bytes; inside `LC_BUILD_VERSION` the fields are minos +12 / sdk +16, inside
  `LC_VERSION_MIN_<platform>` they are version +8 / sdk +12. Getting the first pair wrong is the failure
  mode worth remembering — it produced `bad_cmdsize` for every object and wrote nothing, so the tool failed
  safe and `cmp -l` proved the archives were unmodified.
- **Re-running the fixed pipeline over `/tmp/pkg-ios-aarch64-swift-json.zip`** (78,093,927 bytes, 5 members)
  printed, per archive and for both slices, `objects` 8 / 525 / 12 / 4271 / 251 and `fields_written` 16 / 1050
  / 24 / 8542 / 502 — exactly `2 × objects`, i.e. both fields of every object — with `fat=0 not_macho=0
  bad_cmdsize=0`, `mac2ios` having touched 10139 objects per slice. The installed files were renamed from
  cabal's `…-inplace…` to the `…-2pJp6QhAZjZInPLhny3S4B…` names `project.pbxproj` already references, which is
  `scripts/ios/update-pbxproj.sh`'s job in CI and was done by hand here because `project.pbxproj` is out of
  scope; that file is byte-unchanged by this pass (md5 `01e75327c31427a1b0f3404e613af30d`, still the 2/0 lines
  already in the worktree).
- **Gates on the ten archives.** `otool -l`: `platform` is **2/IOS only** in `ios/` and **7/IOSSIMULATOR only**
  in `sim/`, and `minos`/`sdk` read **17.0 for every one of the 5067 objects per slice**, with `27.0` now
  occurring **0** times in any archive and `11.0` gone too. `xcrun vtool -show-build`, an independent
  instrument, agrees on the 23 members extracted by index from all five archives in both slices (first, middle,
  last: `prep_cif.o`, `assert.o`/`lt65-neg.o`/`randmui.o`, `dummy.o`, `Chat.o`, `AppSettings.o`, `FastSet.o`,
  `Updates.thr_o`, `AutoApply.thr_o`, `M20230321_agent_file_deleted.o`, `Paths_popopx_chat.o`),
  each reporting `LC_BUILD_VERSION`, `platform IOS`/`IOSSIMULATOR`, `minos 17.0`, `sdk 17.0`. Sizes equal the
  zip members (56,192 / 834,648 / 32,624 / 313,120,160 / 88,411,752), `lipo -info` arm64 throughout, `ar -t`
  member counts unchanged (9 / 526 / 13 / 4272 / 252), and every md5 moved — the device `-ghc9.6.3.a` went
  `78acd1cc…` → `653f29b0…`, the plain one `617857ae…` → `fbd76346…`, the sim pair `6594c5bb…` → `1dbc85d0…`
  and `fe36869a…` → `c839b444…`. `scripts/ci/ios-sim/prepare-libs.sh` gained the same assertion as its
  platform gate (`:28-39`), and running that block over the installed tree exits 0.
- **The cluster content is untouched by a 4-byte version patch, and was re-measured rather than assumed:**
  `smp1`…`smp8.popopx.im` 2 occurrences each in the `-ghc9.6.3.a` and 1 each in the plain archive,
  `relay1.popopx.im` 2/1, `xftp1.popopx.im` 2/1, `xftp6.popopx.im` 2/1, `xftp8.popopx.im` 3/1, `.onion` 91/40,
  `popopx.chat` 2641/2639, and the deliberately retained upstream pair `smp4.simplex.im` 2/2 with key
  `o5vmywmrnaxalvz6` 1/1.
- **The build gate.** The identical `xcodebuild` invocation (same scheme, same DerivedData, `BUILD SUCCEEDED`,
  exit 0) reports **0** `was built for newer 'iOS' version` lines and **0** `ld: warning` lines of any kind;
  its 3 remaining warnings are the pre-existing `Metadata extraction skipped` ones. 2212 → 0. The zero is not
  an incremental-build artifact: the after log carries the same `Ld …/POPOPXChat.framework/POPOPXChat` step at
  line 1835, again with `-L…/apps/ios/Libraries/ios`, against archives rewritten at 22:19, and the app binary
  was rebuilt (110,286,864 → 110,395,240 bytes, `LC_BUILD_VERSION platform IOS minos 17.0 sdk 27.2`).
- **Supersedes one line of the entry below.** It recorded "a device **link** of the iOS archives is not proven
  here"; the device link is now proven, at 17.0 and warning-free, for exactly these archives.
- **Not verified by this pass.** CI run `45186952933` (`ios-sim.yml`, dispatched from `e6c41c1cd`) built its
  archives through the *old* `prepare.sh`, so those artifacts still claim `minos 27.0` — the simulator slice is
  re-gated only by the next dispatch of `ios-sim.yml` from this commit. The `~/Downloads` copy of
  `pkg-ios-aarch64-swift-json.zip` is still the read-only 31 Oct `7.1.0.14` artifact and was left in place on
  purpose; anything running `scripts/ios/prepare.sh` verbatim, rather than the CI route, still reads it. The
  `gradlew packageDmg` red is unchanged and still needs your ruling on
  `apps/multiplatform/common/src/commonMain/cpp/desktop/CMakeLists.txt:73`.

## Unreleased — the dependency moves to `0c9141f9`, and both shipped library trees are rebuilt from it, 2026-11-23

- **`cabal.project:24` now reads `tag: 0c9141f92b788a954a495ce8604966f2af5ef9ef`**, with
  `scripts/nix/sha256map.nix:2` carrying its Base32 hash
  `1rrg2405yg9l5pixdbzssczmhkn1v26pqdxy1yd97jkcp6bahiza`. The two move as one unit because two different
  fetchers read them: cabal resolves the `tag:` for `cabal build`, `sha256map.nix` (imported at
  `flake.nix:52`) feeds `fetchgit` for Nix, and a mismatch between them only surfaces in the Nix build. The
  hash is the file's own output — `gawk -f scripts/nix/update-sha256.awk cabal.project` runs
  `nix-prefetch-git --fetch-submodules --quiet <location> <tag> | jq -r .sha256` — and it was re-measured
  after landing: that command returns `1rrg2405…` for `0c9141f9`, and, as the control that the tool is wired
  to the right recipe, still returns `hs-socks` `a30cc7a7`'s recorded `0yasvnr7g91k76mjkamvzab2kvlb1g5pspjyjn2fr6v83swjhj38`
  unchanged.
- **The pin is a bare commit SHA now, not a tag name.** `0c9141f9` is the dependency's `origin/master`, and
  `popopx-pin-7` (`13df615d`, the entry below) is **not an ancestor of it** —
  `git merge-base --is-ancestor 13df615d HEAD` exits 1 in `/Users/elliot/popopx-chat/popopxmq`, whose
  `master` was checked out at `0c9141f9` for this pass. `popopx-pin-1`…`-7` remain local tags there. What the
  new commit contributes to this app is the `popopx.im` cluster: the dependency's `extraSMPServerHosts`,
  declared only at `Popopx/Messaging/Agent/Protocol.hs:1405` (0 occurrences in this repo's `src/`), and its
  XFTP presets, whose three `xftpN.popopx.im…:8443` addresses `src/Popopx/Chat/Operators/Presets.hs:112-116`
  repeats verbatim. The migration list is unchanged, so no existing database is touched by the bump.
- **`scripts/desktop/build-lib-mac.sh:111-112` had matched nothing.** Its libcrypto rewrite keyed on
  `libHSsmplxmq-*` — upstream's abbreviation of `simplexmq` — while GHC abbreviates this fork's package to
  `libHSpppxmq-*`, so the pattern never fired and the dependency dylib kept absolute Homebrew install names.
  Both sites now read `libHSpppxmq-*`. A full `SKIP_VLC=1 bash scripts/desktop/build-lib-mac.sh` exits 0 and
  the tree gates clean: 143 files / 225M in `apps/multiplatform/common/src/commonMain/cpp/desktop/libs/mac-aarch64`,
  every `@rpath` dependency resolving to a file in that tree, no `otool -l` output containing
  `/Users/`, `/opt/` or `/usr/local`, 143/143 arm64, and 143 signatures valid / 0 invalid / 0 unsigned after
  `codesign --force --sign -` — that re-signing is mandatory, because the script's own `install_name_tool -id`
  invalidates the ad-hoc signature it reads on `libcrypto.3.0.dylib`. All 30 symbols declared in
  `libpopopx.dll.def` are exported, and `dlopen(…, RTLD_NOW)` plus `dlsym(…, "chat_badge_issue")` succeed, so
  the closure loads rather than merely existing. Byte census of the tree: `smp1/relay1/xftp1.popopx.im` 2
  each, both `.onion` keys of smp1 and relay1 present, `xftp1.simplex.im` and `xftp6.simplex.im` 0, and
  `smp4.simplex.im` still present because `Presets.hs:97-102` keeps the disabled upstream hosts so previously
  issued short links resolve.
- **The iOS archives were rebuilt by the route this repo's own CI uses, not by Nix.**
  `scripts/ci/ios-sim/build-core.sh` writes an iOS-flavoured `cabal.project.local` (`+swift +client_library`,
  `static: True`, `-DIOS`, `+commoncrypto`, `+DoNotGetEntropy`), builds `lib:popopx-chat`, collects the chat
  archives with brew's `libffi/libgmp/libgmpxx` and zips them; `scripts/ci/ios-sim/prepare-libs.sh` then
  compiles `mac2ios` from `zw3rk/mobile-core-tools@4dcb77d5` and runs `scripts/ios/prepare.sh`. Repeating that
  by hand produced `/tmp/pkg-ios-aarch64-swift-json.zip`, sha256
  `491a8d2595e919660a587b00842437e67912b2b7623c4e435bf0da16dcf66292`, 78,093,927 bytes, 5 members. Both
  `apps/ios/Libraries/ios` and `…/sim` now hold those bytes: sizes equal to the zip members exactly
  (313,120,160 + 88,411,752 for the two chat archives), `lipo -info` arm64 for all five, and
  `otool -l` platform load commands of **2/IOS** in `ios/` and **7/IOSSIMULATOR** in `sim/` — the second is
  `prepare-libs.sh:17-25`'s own gate, the first is the device slice this task exists to refresh. Every md5
  differs from the archive it replaced (the `-ghc9.6.3.a` went `6271f1c4…` → `78acd1cc…`), and the content
  delta is the point of the rebuild: `popopx.im` occurs **0 times in the slice installed before and 29 times
  in the new one**, because `83159481d` — this repo's own HEAD — is the commit that moved the default servers
  onto the cluster, and the replaced archives predate it. `extraSMPServerHosts` rises 126 → 186 in the same
  file, which is the dependency's contribution.
  Two things about this step are worth repeating. First, **`scripts/ios/prepare.sh:8` reads a fixed path**,
  `~/Downloads/pkg-ios-aarch64-swift-json.zip`, and a read-only artifact from 31 Oct was sitting there: the
  first install silently rebuilt `Libraries/` from it and named itself `libHSpopopx-chat-7.1.0.14-…` with zero
  `popopx.im` hosts. An existence check on the input is not a provenance check — compare the installed sizes
  against the zip that was meant to produce them. Second, `project.pbxproj` pins the two chat archives by
  name (`libHSpopopx-chat-7.1.2.0-2pJp6QhAZjZInPLhny3S4B{,-ghc9.6.3}.a`), which is a Nix package key, while
  cabal emits `…-inplace…`; the new files were installed under the names the project already references,
  because rewriting them is `scripts/ios/update-pbxproj.sh`'s job and `project.pbxproj` was out of scope here
  — CI runs that script immediately after `prepare-libs.sh`, and it is the fix to reach for if these names and
  the project ever drift again.
- **`Presets.hs:104-110` no longer claims the pin still names upstream's `xftpN.simplex.im`.** That sentence
  was written for `popopx-pin-7` and went stale with this bump; the comment now records that the pinned
  commit names the same three `popopx.im` servers, and why the list is held here anyway (the app-visible
  servers should not move just because the pin moved).
- **Not verified by this pass.** `gradlew packageDmg` is still red before it reaches the DMG: the desktop tree
  built by `build-lib-mac.sh` ships RTS as `libHSrts-1.0.2_thr-ghc9.6.3.dylib`, which
  `apps/multiplatform/common/src/commonMain/cpp/desktop/CMakeLists.txt:73`'s `libHSrts_thr-*` glob does not
  match, so `set_target_properties(rts …)` at line 74 gets an empty variable — **that file is not mine to
  edit and needs your ruling**. The Nix derivation `.#"aarch64-darwin-ios:lib:simplex-chat"` was started twice
  and stalled with the daemon alive, its children at 0.0% CPU and no log growth for 12+ minutes, so `sha256map.nix`
  has been validated by its generator, not by a Nix build, on this machine. A device **link** of the iOS
  archives is not proven here and is not proven by CI either: `build.yml:1377` `build-ios` fills
  `apps/ios/Libraries/sim` with `scripts/ci/ios-stub-libs.sh` stubs, so the only real-library job is
  `ios-sim`, which builds for the simulator. `ios-sim.yml` was not dispatched.

## Unreleased — the pin moves to `popopx-pin-7`, and the call media key gets its own separator, 2026-11-17

- **`cabal.project:24` now reads `13df615df7892532b4e83f92d529b96c3d788dea`** = tag `popopx-pin-7` of the
  dependency, with `scripts/nix/sha256map.nix:2` carrying its Base32 hash
  `04ihl1j1qm4s9sik4c65gh2w78x6k2y8nv8a5jir11i6fm9gir9z`. The hash was not typed in: re-running the file's
  own generator (`gawk -f scripts/nix/update-sha256.awk cabal.project`) over all twelve entries rewrote
  exactly one line, which re-proves the other eleven in the same pass. `popopx-pin-6` (`4cc1b9d4`) is
  skipped on purpose — it renamed the XOR-aggregation UDF by adding a 126-line migration that pin-7 deletes
  36 minutes later in favour of renaming it in place, and pin-6's own push run `44027639184` concluded
  `failure`. The gate this pin was taken at is recorded in FORK.md item 16: the dependency's all-platform
  push run `44037250044` concluded `cancelled`, manually and not by the workflow (`build.yml:21` does not
  cancel on push), once `4c8bdb7e` superseded it; green at `13df615d` are three compile legs across two
  runs — `ubuntu-22.04-aarch64` and `ubuntu-24.04-aarch64` from that run, `ubuntu-24.04-x86-64` from PR run
  `44036381631` — while the rest of that run's x86-64 matrix reached no conclusion (`cancelled`, not
  failed), and no leg anywhere builds `aarch64-darwin`.
- **`SimpleXCallMediaKey` is the eleventh domain separator, and it lives here, not in the dependency** —
  `src/Popopx/Chat/Call.hs` uses it as the HKDF separator when deriving a call's media key, so the sweep
  recorded in the entry below, which moved ten separators inside `popopxmq`, passed over it. A separator is
  hashed independently on each side of a connection, which rules out a find-and-replace: swapping the
  string where it stood would leave two builds of this fork registering with the same relay and
  negotiating SRTP keys that cannot decrypt each other, silently and in both directions. The brand
  therefore rides the call protocol version instead — `callMediaKdfPopopxVersion = VersionCall 3`,
  `currentCallVersion` raised from `2` to `3`, and the separator chosen by the *negotiated* version at
  `Call.hs:88-90` — so a peer that advertises at most v2 keeps deriving with `SimpleXCallMediaKey` and the
  call still connects. Nothing had to be written twice to get there: `supportedCallVRange` derives the
  ceiling from `currentCallVersion`, `git grep -n VersionCall -- src` is 14 lines all inside `Call.hs`, and
  the same grep outside it is empty.
- **Verified locally, with one number deliberately left unsettled.** `cabal build` and
  `cabal build popopx-chat-test` both exit 0. `-m "POPOPX chat protocol"` = 82 examples / 0 failures (among
  them `x.call.inv with call version range`, the `CallVersionRange` wire fixture at
  `tests/ProtocolTests.hs:435-436`), `-m "WebRTC crypto"`
  = 4 / 0, and `-m "webrtc calls api"` = 3 / 0, which contains `negotiate call between current and v1
  clients` — the test that would fail if the version gate were wrong. Each selector was run separately
  under `--fail-on=empty`, so an empty selection cannot be read as a pass. The linked proof is in the
  bytes: all seven executables read `popopx_xor_md5_combine` **7** times and `simplex_xor_md5_combine`
  **0**, and the test binary carries `POPOPXCallMediaKey` once next to `SimpleXCallMediaKey` once, both
  guards live. What is not reconciled is the dependency's own build tree: the four `libHSpopopxmq*`
  archives on disk still read the old UDF name with zero of the new, and none of their objects post-dates
  the pin fetch. That is the drift FORK.md item 16 describes, it belongs to the work being done on
  `popopxmq`, and nothing here was deleted or force-rebuilt to make the two agree.

## Unreleased — the branded key-derivation labels reverted, 2026-11-17

This one changes a wire value, so it is not part of the documentation section below it.

- **A fork whose peers derive different keys is not a compatible build.** The brand sweep of the
  dependency `popopxmq` moved ten HKDF and BBS **domain separators** to `POPOPX…` spellings:
  `sbcInit`/`sbcHkdf` (SMP transport blocks — `Transport.hs:846` runs the same chain on the server and
  the client), `pqX3dh` ×2, `rootKdf`, `chainKdf` (the end-to-end ratchet), `contactShortLinkKdf`,
  `invShortLinkKdf`, `serviceReqBinding` and `entitlementBBSHeader`. Each is hashed independently on
  both sides of a connection, so both sides stay internally consistent and simply stop understanding
  each other. Measured on built bytes: our CLI ↔ a relay built here delivers (`NEW` → `IDS`, the queue
  created and the subscription accepted); the same CLI ↔ upstream's relay binary sends `NEW`, waits 7 s,
  returns `BROKER {brokerErr=TIMEOUT}` and that relay logs nothing about the connection; from the other
  side the published `-libs` core times out against a relay we build and succeeds against upstream's;
  and the CLI rebuilt after this revert gets `IDS` in the same second it sends `NEW`, against that very
  same upstream relay binary. Both
  relays report the same `v7.1.0.17`, so it was not a version gap. **Corrects a verdict in the task
  record of 2026-11-15**: the `BROKER TIMEOUT` family was not "the preset relay's, not our wire" — it
  is our wire, on the label side.
- **CI is the fourth pairing, and reverting does not close it.** `Test changed scopes` runs the mcp e2e,
  which takes *both* ends from published release assets rather than from the tree under test: the client
  from `-libs` tag `core-7.1.0.20` (measured **0 branded / 2 upstream**, upstream's package name still)
  and the relay from our own `popopxmq` release `v7.1.0.17` (measured **2 branded / 0 upstream**, digests
  matching the pins at `smpServer.ts:14,16`; upstream has no `v7.1.0.17` release, so those are our builds).
  Run 43982143632 answers that mismatch with `Tests: 11 failed, 2 passed`, every failure a
  `BROKER {brokerErr=TIMEOUT}` on a `localhost` address. So the harness is not green "when it builds its
  own relay and red when it fetches the published core" — it is green when both ends come from one tree
  and red when the two published ends disagree, which they do today. Closing it needs a republish of the
  relay binaries from the reverted tree, with `smpServer.ts:10` and its four digests moved in the same
  change; the pin move alone leaves CI exactly as red as it was.
- **Reverted to upstream's exact bytes** in `popopxmq` commit `cb9e1aa3cbd8bd2fdb932243ffb9c554b3826bae`
  = tag `popopx-pin-5` (12 files: the 5 source files above, plus `NOTICE`, `protocol/crypto-registry.md`,
  `protocol/agent-protocol.md`, `protocol/xrcp.md`, `protocol/pqdr.md` and two `plans/`, all of which had
  recorded the branded values). Every derivation site now carries a line saying the literal is a protocol
  constant. Gates, scoped to the dependency's `src` so the prose here cannot count itself:
  `git -C ../popopxmq grep -o '"POPOPX\(SbChainInit\|SbChain\|X3DH\|VerifyCode\|RootRatchet\|ChainRatchet\|ContactLink\|InvLink\|Service\| badges v1\)"' -- src | wc -l` → **0**,
  and its positive control, the same command with `SimpleX` → **10**. Held as branding because no
  foreign process reads them: the two `POPOPX XFTP … v` `--version` strings, the `.popopx` name TLD,
  and the `adminPopopx`/`complaintsPopopx` keys this server serves — emitted at `Server/Web.hs:273,280`,
  read only by `apps/common/Web/static/index.html:272,290`, a page the same server serves.
- **What is NOT yet true, and why — overtaken the same day, and the half that still is.** This bullet was
  written while `popopx-pin-5` was unpushed and `cabal.project:24` still named `25d7213d…`. Neither is
  the state now: `cb9e1aa3` was pushed and tagged, `b5bc7577` reverted it, and the pin reads
  `13df615d…` = `popopx-pin-7` — see the top entry, and the gate above re-run at that commit reads
  **10 branded / 0 upstream** where this entry quotes **0 / 10**. The built half of this bullet is the
  part that stayed true, and it is worth keeping because it is the one thing a pin move cannot do by
  itself: the iOS Haskell archives installed on this machine are still pin-4 bytes. Measured again after
  the re-pin, `grep -a -o -E 'POPOPXSbChain' ARCHIVE | wc -l` reads **2** on each of
  `apps/ios/Libraries/ios/` and `apps/ios/Libraries/sim/` — which now agrees with the dependency by
  accident, pin-4 having branded what pin-7 re-branded — while the same recipe on
  `simplex_xor_md5_combine` reads **8** and on `popopx_xor_md5_combine` reads **0**, and
  each slice still carries `SimpleXCallMediaKey` once with no path to the v3 separator. `v7.1.2-popopx.1`'s
  published assets were built through pin-4 too, and that remains the one number here taken from inference
  rather than measurement, because downloading the asset is the step egress keeps failing. The rebuild
  order, and why pin-6 was skipped, are in FORK.md item 16.

## Unreleased — records and citations, 2026-11-17

Documentation only: no `src/**`, no build file, no asset and no wire value changed in this section.

- **A citation that 404s is not a citation.** Five fork documents linked upstream source with
  `github.com/simplex-chat/simplex-chat/blob/db0768c21/...`, but `db0768c21` is **this** repository's
  initial commit - it exists only here - and `blob/<sha>` resolves against the host in the URL. Both
  halves were ours and the pair named no real object. 9 lines / 5 files (`FORK.md`,
  `PRIVACY-POPOPX.md`, `apps/popopx-badge-service/README.md`,
  `apps/popopx-badge-service/protocol/badges-rpc.md`, `apps/popopx-badge-service/web/README.md`) now
  carry the upstream commit whose tree they were written against -
  `f8776692dfedc27dc3e723231b2ca11e02bedd06` (= `master` of `simplex-chat/simplex-chat`, measured
  2026-11-17) - so the link opens upstream's file instead of a 404 on our fork. `db0768c21` stays in
  these files wherever the text means *"this repository's own initial commit"*, which is a fact about
  our history rather than an address into theirs. Re-derive both directions, each command excluding this
  file because this entry quotes both spellings and would otherwise count itself:
  `git grep -n 'blob/db0768c21' -- . ':!CHANGELOG.md'` → 2 lines, both prose about the convention;
  `git grep -c 'f8776692dfedc27dc3e723231b2ca11e02bedd06/' -- . ':!CHANGELOG.md'` → 9 lines / 5 files.
  The rule this generalises: a link is a wire value with a second end, the host that serves it - check
  that end answers before shipping the text that depends on it.
- **Links into deleted directories.** `PRIVACY-POPOPX.md` pointed at `/docs/*.md` paths that this
  repository no longer carries (`git ls-files docs` returns one surviving file, `docs/CLI.md`); they
  now name the permalinks the site publishes. Gate:
  `git grep -n 'popopx\.chat/docs/[A-Za-z0-9_.-]*\.md' -- . ':!CHANGELOG.md'` → 0.
- **Two more sentences this fork outgrew, and one a sweep inverted** (same file):
  - "popopx.chat is not yet owned or served by this fork, so that address is not yet reachable and no
    service advertised by this repository is live", and the matching line under **Contact**. Both were
    written before the site existed; re-measured 2026-11-17 - the domain resolves to `43.129.4.33` and
    `/`, `/security/`, `/docs/simplex.html`, `/docs/upstream-disclaimer.html` all answer `200`, while
    `dig +short MX popopx.chat` is **empty**. They now say what is actually unverified (mail delivery,
    because no MX is published) and name the fallback channel, GitHub issues (`has_issues: true`).
    Self-contradiction was the tell: the same file links to four `popopx.chat` pages ten lines below
    the sentence denying that the domain is served.
  - "chat@popopx.chat, which appears in upstream's files, must not be presented as the contact for
    this fork: it reaches SimpleX Chat Ltd" - true of `chat@simplex.chat`, nonsense about our own
    address, and already on the pushed tip. That is the address-sweep reading the *entity* out of the
    sentence: the fix restores `chat@simplex.chat`. Gate for the class:
    `git grep -n 'chat@popopx\.chat' -- . ':!CHANGELOG.md' | grep -i 'upstream\|simplex chat ltd\|reaches'`
    → 1 line
    (`FORK.md:171`), which correctly describes replacing upstream's encoded relay address with ours.
- **This file was overtaken by a later action, and says so instead of being rewritten.** The
  `v7.1.2-popopx.1` section above records "the `popopx-chat-libs` backend releases ... that repository
  still has no releases". That was true on 2026-11-15 and is not now: `popopx-chat/popopx-chat-libs`
  has 3 published releases (measured 2026-11-17, `api.github.com/repos/popopx-chat/popopx-chat-libs/releases`
  = `core-7.1.0.20` 6 assets, `nodejs-addon-cce06d8` 5 assets, `core-7.1.0.14` 6 assets), each named
  "(mirror of simplex-chat/simplex-chat-libs)" - upstream's bytes, whose pinned SHA-256s are unchanged,
  under our repository and asset names (ruling 2026-11-16). The 2026-11-15 text stays as it was
  written, because a dated record is evidence about the date it carries; this bullet is the correction.
- **Site-side mirror of the same defect class** (repository `popopx.chat-site`, branch `main`, commits
  `8e60eaa` and `f74c3f3` - unpushed as of this entry): two `popopx-desktop-macos-*.dmg` links that 404
  (the release above never published a macOS desktop asset, see "Not published here" above), upstream's
  PGP fingerprint presented as the fork's contact key, the fork loading SimpleX Chat's directory listing
  into our own pages, and a privacy page that said "no push service is used" while the build presets
  `ntf3.simplex.im` / `ntf4.simplex.im`. Each was found the same way - the assertion was re-derived from
  the host or the source that has to back it.

- **Store and package copy that spoke as the operator of someone else's relays.** Four user-facing
  descriptions - `README.md`'s disclaimers, `fastlane/.../full_description.txt`, the desktop
  `com.popopxchat.popopx.appdata.xml`, `scripts/flatpak/com.popopxchat.popopx.metainfo.xml` - carried
  SimpleX Chat Ltd's operator statements in this fork's first person: "historically our servers had
  over 99.9% uptime each", "we have never provided ... access to our servers", "we do not log IP
  addresses ... on our servers", "your profile and contacts ... our servers do not have access",
  "routed via our servers". POPOPX operates no relay, so not one of those is this fork's to assert -
  and one of them was not even English any more: the AppStream copy had been swept into
  "**POPOPX** Messaging Protocol", a protocol that does not exist. Each now names the operator
  (`SimpleX Chat Ltd` for the presets, "whoever runs the relay you use" for the logging claim), routes
  POPOPX questions to this repository's issue tracker, and says so where the sentence used to promise
  an answer ("report vulnerabilities to the team in the app" - the in-app team contact is upstream's,
  held at four `HOLD (task #66)` sites pending our own relay). Gates, scoped so the records quoting
  these strings do not measure themselves: `git grep -n 'POPOPX Messaging Protocol' -- . ':!FORK.md'
  ':!CHANGELOG.md'` → 0 (unscoped: 2, the record itself); `git grep -n 'our servers' --
  apps/multiplatform/desktop scripts/flatpak fastlane` → 0 (HEAD: 6); `git grep -n '99\.9\|never
  provided or have been requested\|do not log IP' -- README.md` → 0. Both AppStream files re-parsed
  with `xml.dom.minidom` after the edits.
- **`README.md` also denied having a security policy** while this fork publishes one at
  [popopx.chat/security/](https://popopx.chat/security/) - and sent vulnerability reports "to the team
  in the app", i.e. to SimpleX Chat Ltd's contact. It now gives **chat@popopx.chat**, states plainly
  that no OpenPGP key is published for it, and states plainly that **no MX record exists for
  `popopx.chat`**, which means this fork currently has no *confirmed* confidential reporting path;
  closing that gap needs a mail route or a published key, which is infrastructure, not wording.
  `PRIVACY-POPOPX.md` was re-read against that and its fallback to the issue tracker is now scoped to
  non-security reports, because the policy it cites forbids public issues for unpatched ones.

## v7.1.2-popopx.1 — 2026-11-15 (153 commits after the import point `db0768c21`)

Forked from `github.com/simplex-chat/simplex-chat` at `db0768c21` (2026-11-11), code version
`7.1.2.0` (`v7.1.2`). This section was headed `Unreleased` while no POPOPX binaries existed; the
first release is published now, so the heading is the tag itself.

**What was published.** Release `v7.1.2-popopx.1`, built by run `43649743373` from the tagged commit
`986143710` (annotated tag object `cc428ee06`): 19 assets = 18 binaries + `LICENSE`, each asset named
by a `SHA2-256(...)` line in the release notes. Neither draft nor prerelease, so `releases/latest`
resolves - measured, not inferred. `install.sh` recomposes `releases/latest/download/popopx-chat-ubuntu-<ver>-x86_64`
from its own moved `APP_NAME`, and all four Ubuntu CLI assets exist under those names (the installer was
not executed on a machine); the desktop updater queries `api.github.com/repos/popopx-chat/popopx-chat/releases`
(`AppUpdater.kt:188`), which is this repository. Not published here: the macOS `.dmg` (no Developer ID
credential is configured), Android APKs, iOS builds, and the `popopx-chat-libs` backend releases that
`pip` and `npm` install (#77 - that repository still has no releases).

The fields the release template at the end of this file asks for, filled with what was measured for this
tag rather than with intent:

- upstream commit this build starts from: `db0768c21` is this repository's own initial commit ("Initial
  commit for secondary development", 2026-11-11); the code is upstream's `v7.1.2` = `50a575e44`, which is
  **not an ancestor** of `master` - the history was re-imported, so the compare API finds no common
  ancestor and a changelog builder has no base to diff.
- iOS: not published. `macos-latest (iOS)` is skipped on a tag, so this release carries no iOS artifact.
  The signing identity ruled for this fork is Team ID `PDBA6XRBQT`.
- Android: not published. `applicationId = "com.popopxchat.popopx"` (`apps/multiplatform/android/build.gradle.kts:15`)
  with a debug suffix variant, and no store listing behind it.
- in-app update visibility on desktop: **none, on both channels** - ruled **B1 (accept, document)** on
  2026-11-15, so `AppUpdater.kt` was left untouched. Read from the comparator, not inferred:
  `:114 isConsideredBeta = preRelease || semVer == null || semVer.isNotStable` filters `-popopx.1` out of
  STABLE (`:194`), and BETA's only other test is `currentSemVer < r.semVer` (`:195`) while `:60-61`
  (`preRelease != null -> -1` / `other.preRelease != null -> 1`) ranks a labelled version *below* the same
  bare numbers an installed 7.1.2 reports. The tag name that avoids colliding with upstream's `v7.1.2` is
  therefore the reason the release cannot self-update; **B2** would change that comparison. Until then the
  assets in the release are the update path. `.github/release_body.md` said "only the beta channel will"
  offer it until this measurement - that sentence was wrong about a published page, and the page is only
  corrected by patching the release body.
- servers this release presets: the SMP/XFTP presets still name relays operated by SimpleX Chat Ltd, and
  the consent flow still names that company, because `CARequired` makes the operator name a party to the
  consent. Held with the per-host reasoning in `FORK.md`.
- link domain actually serving this release: `popopx.chat` - certificate SANs present (`popopx.chat`,
  `popopxchat.com`, `www.popopxchat.com`); `/.well-known/assetlinks.json` and
  `/.well-known/apple-app-site-association` reachable over HTTPS with no redirect: **no** - both `404`
  when re-measured 2026-11-15 while `/` on the same host answers `200`.
- relay domain `popopx.im`: no host listens under it and no fingerprint of it is in any preset; the iOS
  entitlement `applinks:*.popopx.im` is in place for the day one does.
- every upstream-operated host still named in the build: listed per host, each with whether it fails
  silently or visibly, in `FORK.md` "Upstream-operated hosts, and how each one fails".
- publisher and contact address shipped in the app and in these files: POPOPX, chat@popopx.chat.

**Two defects this release had to be rebuilt to fix**, both found by reading the first attempt rather
than the pipeline: `make-appimage-linux.sh` moved its result with `*popopx*.AppImage`, but appimagetool
names the output after the desktop file's `Name=` field, so on this tree the file is
`POPOPX_Chat-<arch>.AppImage` - both AppImage builds succeeded and neither was moved or uploaded. And
every build leg appended its own SHA-256 line to the one shared release body, which is a
read-modify-write of that body: 2 of 16 lines were lost to the race. The glob now takes the product by
position, and a single `release-hashes` job writes all the lines after the uploading legs finish, from
the digest GitHub records for each asset. The release and the tag were deleted and rebuilt from the
fixing commit instead of patched: an asset name cannot be uploaded twice into the same release, and the
tag has to pin the commit the notes describe.

The "no release yet" measurements inside the 2026-11-13 and 2026-11-14 entries below - the reproduce job
that "prints `No published release to reproduce - skipping.`", `releases/latest` that "answers 404 for
both owners today" - are kept as written: they were true on their own dates. This section supersedes
them; `scripts/popopx-chat-reproduce-builds.sh` now has a release to verify.

**The first reproduce run answers, and the answer is no** (2026-11-15, dispatch `43657558913`, 2 h 25 m).
All seven Linux artefacts were rebuilt and **none matched** `v7.1.2-popopx.1`, so `_sha256sums` was never
written and the last step failed. The script prints only mismatches, so seven lines means nothing matched
rather than seven of many. For the four CLI artefacts the asymmetry is in the files: the release leg
compiles with `cabal build -j --enable-tests` (`build.yml:471`) and the reproduce leg with `cabal build -j`
(`popopx-chat-reproduce-builds.sh:84`), and no `cabal.project.freeze` is tracked here, so each side lets the
solver choose dependency versions under different constraints. What is *not* the difference: the two sides
pin the same `ubuntu:22.04`/`24.04` image digests, the same GHC 9.6.3 and the same apt snapshot, and the
packaging already fixes the timestamps (`SOURCE_DATE_EPOCH`, `dpkg-deb --root-owner-group
--uniform-compression`). The three desktop artefacts are the Kotlin bundle and need a separate diagnosis.
Upstream's own nightly fails identically - seven consecutive red runs, 2026-11-08 to 2026-11-14 - so this is
an inherited property of the build, not something the rebrand introduced. Ruled **option b**: the
`schedule: - cron: 0 2 * * *` trigger is dropped and `workflow_dispatch` kept, because a run costs about
2.5 h of runner time to report the same known answer every night. `FORK.md` §"Reproducing a build" carries
the measurement and the candidates for the desktop half.

The step that reads `releases/latest` is now authenticated with `secrets.GITHUB_TOKEN` and distinguishes
"404, nothing published" from "could not tell": scheduled run `43668965123` printed
`No published release to reproduce - skipping.` and went green in 6 seconds on 2026-11-15 02:41:43 while the
release was published, because its anonymous call from a runner's shared IP returned no `tag_name`. A guard
whose skip branch is also its error branch turns an outage into a green idle run, so any status other than
200 or 404 fails the step.

### This fork's own artwork is licensed now; the names and upstream's art are not (2026-11-16)

The images whose bytes this fork wrote are licensed under **AGPL-3.0-only, or at the recipient's option
CC0-1.0**, which withdraws the 双轨制 ruling that held the pictures proprietary while the code was free.
The reasoning is in `FORK.md` item 15: the icons ship inside the binaries and the vector masters that
draw them are the §13 corresponding source, so a permission requirement on that part of the work is a
further restriction §10 forbids and §12 does not let us keep by disclosing it. Untouched are the names —
trade mark sits outside the copyright licence — and upstream's byte-identical files, which this fork has
nothing to grant. `ASSETS_LICENSE.md` was rewritten first, then `NOTICE`, `README.md`,
`TRADEMARK-POPOPX.md`, `AGPL-COMPLIANCE.md` §4, `branding/source-svg/README.md` and `FORK.md`.

### The sponsor entries are gone from both repositories (2026-11-16, ruling 「删掉两个仓库的 FUNDING.yml」)

`.github/FUNDING.yml` declared `github: simplex-chat` and `open_collective: simplex-chat` — upstream's
funding address on the front page of a repository that is not upstream's and whose README disclaims any
affiliation with them. Measured on the rendered repository page, GitHub was displaying no sponsor
affordance from the file (`"showSponsorButton": false`, `"sponsors": false`), so it moved no money; it
only asserted a relationship, which is the sort of claim that starts being visible without anybody
changing it. Removed rather than repointed: this fork's organization has no sponsor program to point at
(`/sponsors/popopx-chat` falls back to the organization page, no tiers), and the precedent is this fork's
own 2026-11-13 deletion of the AppStream `<url type="donation">` elements — a funding entry has no slot
to say whose funds they are — and `FORK.md` item 12, by which this fork deleted its own crowdfunding
funnel rather than relabel it. Donating to upstream is still described, in words, with the recipient named,
in `README.md`; that section is upstream's copy and this fork receives none of it. `popopxmq` deleted its
copy under the same ruling, recorded in that repository's NOTICE.

Everything below is a **name and identity** change. Nothing in this list alters the protocol, the
cryptography or the wire format.

### The last five `simplex:/` texts, and the phrase that named them (2026-11-16, rulings `simplex:/ 更新为 popopx:/` + 执行 A1+A2+A4+A6 + #112 A + #113 仅 tools.ts)

Two rulings, one sentence long each, and both turned on reading the producer rather than the
text. `05dd5a73c` moved the link scheme to `popopx:/`; the app has emitted and parsed nothing else
since, and the accepted prefixes are `popopx:/` and `http(s)://` (`Markdown.hs isUri`, and the
dependency's `ServiceScheme.hs`, whose `SSPopopx -> "popopx:"` parser accepts no other spelling).
That answers the open question in `POPOPX-REBRAND-PLAN.md` D9: there is **no dual parse**, so links
issued before the move are inert on this fork's clients - and any text still saying `simplex:/` was
describing a scheme that no longer exists here.

`82ac26bec` moved those five texts and held four records (one occurrence each). Four of the five
were prose - the MCP `spec/api.md` target row, the directory service README's sample output, the iOS
navigation spec, and `apps/ios/README.md`, whose claim `URL scheme: simplex:// for deep linking` was
simply untrue of this build: the registered schemes measured from `POPOPX--iOS--Info.plist` are
`popopx` for connection links and `popopxchat` + `simplexchat` for app links. The fifth was
behaviour. `scripts/relay/entrypoint.py:40` scans the relay's output to decide which token *is* the
address; it looked for `simplex:`, so it never matched, `/out/relay-address.txt` was never created,
and every container start re-ran the capture and logged `relay address not captured; will retry next
start`. A guard whose input path is authored for a tree that no longer exists is not a failing guard -
it is an absent one, and it had been absent since the scheme moved.

Reading that file to decide which prefix is correct pulled up the build behind it, and the build was
broken independently of any naming question: `scripts/relay/Dockerfile` fetched
`github.com/simplex-chat/simplex-chat@88df79d1e`, an upstream commit from August whose tree declares
`executable simplex-chat` in `simplex-chat.cabal`, while running `cabal build exe:popopx-chat`.
`5fd42d793` renamed the executable and the `COPY` target but left the remote and `CHAT_REF`, and
`docker-compose.yaml:8` defaulted to the same ref, so **the relay image has been unbuildable since
2026-11-12** and never could have produced the binary `entrypoint.py` names. `a51c59355` points both
at this repository, pinned to a recorded master commit. Verified statically, and stated as such:
`executable popopx-chat`, `flag client_postgres`, `scripts/cabal.project.local.linux` and all ten
switches the entrypoint passes exist at that pin; no `docker build` was run. The pin came from the locally
recorded `origin/master` while both egress paths were down, and was confirmed once direct egress answered:
`git ls-remote origin refs/heads/master` returned `967cd6e88ae1e88eaa4078ecc4fa9aa07f4fe317`, which was then the
live master tip. That lasted one day: master has moved twice since, so this sentence now gives the command rather
than a SHA. Measured 2026-11-16 on tip `667c102d4`, `git rev-list --count 967cd6e88..HEAD` reads **15** and
`git rev-list --count origin/master..HEAD` reads **1** (`origin/master` = `e3ce5da01`). An earlier version of this
paragraph named `d591bc28e` and "twelve commits ahead", which was true for the few hours between those two pushes -
that is the trap, not the number. The pin is therefore an ancestor, not
the tip: it still fetches and still declares everything `entrypoint.py` reads (`executable popopx-chat` at
`popopx-chat.cabal:607`, `flag client_postgres` at `:33`, `scripts/cabal.project.local.linux`, and all ten long
switches parsed in `src/Popopx/Chat/Options.hs`), and advancing it to a CI-validated
commit is a deployment decision rather than something a newer SHA forces. The same probe re-measured the publishing
blockers for #82 -
`gh secret list` and `gh variable list` are empty for both `popopx-chat/popopx-chat` and
`popopx-chat/popopx-chat-libs`, while that second repository now answers `gh release list` with the two
mirrored releases (`core-7.1.0.20`, `nodejs-addon-cce06d8`), which is why the MCP end-to-end job fetches its
backend from us rather than 404ing.

The phrase tier that followed moved 59 of the 64 `SimpleX link` occurrences - the other 5 are records
(`CHANGELOG-POPOPX.md` — this file, renamed 2026-11-25 — 3, upstream's then-`CHANGELOG.md` 1, the AppStream release note in
`com.popopxchat.popopx.metainfo.xml` 1). The denominator is a command, not a memory: `git grep -o 'SimpleX link'
f2a262472^ | wc -l` reads 64. Re-measured on `667c102d4` the phrase reads 9 occurrences in 4 files, the same 4
files: the two holders the tier deliberately left are unchanged at 1 each (`CHANGELOG.md`, the AppStream release
note) and the rest is these two records quoting the phrase they rule on (6 here, 1 in `FORK.md`) - a recount after
reading this sentence runs higher again, because the sentence quotes it:

| commit | what moved | how it was proved |
|--------|------------|-------------------|
| `f2a262472` | the directory service's group-settings notice, its three verbatim test mirrors, five hspec titles, one comment | producer and mirrors compared byte-for-byte afterwards (1 in `Service.hs`, 3 in `DirectoryTests.hs`, 0 of the old spelling); titles carry no in-repo pin - the only `--match` is `scripts/ci/run-tests.sh:15`, whose patterns come from a pull request's `ci-tests` block - and asking that question exposed a stale note: the comment at `tests/Test.hs:80` claimed four "SimpleX &lt;service&gt;" titles below it were kept upstream-valued, but `968907a2d` had renamed all four on 2026-11-15, so it now records the mechanism instead of a count that had already gone stale |
| `5932bccee` | the MCP tool schema, the sentence the server throws, and the spec/plan/reference rows that quote it | `tsc --noEmit` rc 0, `jest test/unit` 9 suites / 274 tests green; no test asserted the thrown sentence, its only other holders moved in the same commit |
| `bb6a7c4ca` | 20 lines across `COMMANDS.md`, `commands.ts`, `_commands.py` and the nodejs `api.ts`/`docs` pair | regenerated, never typed: `tests/APIDocs.hs:153` writes before asserting, so `-m"Bot API docs"` is generator and comparator at once - 2 failures while stale, 17 of 17 green after; `typedoc` changed exactly 4 ins / 4 del and no other line |
| `a77fe94dd` | 19 lines in the two clients' product and spec documents | each row compared with what ships: iOS's picker is titled `POPOPX links` at `DeveloperView.swift:74` under *Deprecated options*, so `SimpleX link mode` was stale twice; Kotlin's label is `strings.xml:116`; the citation `strHasSingleSimplexLink` names a symbol no file has ever declared and became `strConnectTarget` (`ChatListView.kt:901`) |
| `57b8a0bb3` | the four *format* examples `@name.simplex` / `#name.simplex`, and four `simplex_name` field rows in the MCP plan | authority is `popopxmq` `PopopxName.hs:54,121`: `data PopopxTLD = TLDPopopx \| TLDTesting \| TLDWeb`, parser accepts the label `popopx` - this build cannot parse a `.simplex` name, so a shape example must spell it the way the client does, and `tools.ts:242` already did |

`5932bccee` also settled #113's two live sites, which were self-contradictions rather than naming:
`popopx_name`'s own description offered `@directory.simplex` while 20 assertions in `test/unit` use
`@directory.popopx`, and the target row gave `#name.simplex` in the same sentence as
`@directory.popopx`. `57b8a0bb3` completed the pair in the rows describing them. Everything else in
that family is held, and the reason is the same test that has decided every name tier here: a
destination belongs to whoever operates it. `@directory.simplex` (17 occurrences in the package's
`PLAN.md`, `spec/flows.md`, `REFERENCE.md`, `TESTING.md`), `#ridgeline.simplex`, `#agents.simplex` and
the peer display name "SimpleX Directory" describe connecting to services SimpleX Chat Ltd operates -
`REFERENCE.md:88` still reaches that directory by `https://smp4.simplex.im/a#…`, and the package's own
fixture pairs the upstream display name with our namespace (`messages.test.ts:1013`:
`name: "SimpleX Directory", popopxName: "@directory.popopx"`). Two documents therefore read
"POPOPX link" beside an unchanged `.simplex` example; that is the split, not an unfinished line.

Measured at the end of the pass: `simplex:/` 4 occurrences / 4 files, none of them code. `SimpleX link` 5 /
3, of which one is the AppStream release note. `POPOPX link` 576 / 91 files. `[@#]<name>.simplex` 25, of which 20 are upstream-operated
names in the MCP package, 2 are host names in the WebRTC files of both clients, and 3 are the records in
`CHANGELOG.md` and `PRIVACY-POPOPX.md`. `simplex_name` 24 / 9 files, and only 16 of them are code:
the recorded database migration name `20260603_simplex_name` - 3 in each `Migrations.hs` (the string, plus
`m20260603_simplex_name` and `down_` it) and 4 in each module that already bears the file name
`M20260603_popopx_name.hs`, plus 1 in each schema-dump mirror; a database that applied it stores that
string, so it does not move. 2 more are `POPOPX-REBRAND-PLAN.md`'s protected-literal list, and the last 6
are the two paragraphs above quoting it.

Re-measured on `667c102d4`, because every one of those five numbers is a working-tree count and the tree moved:
`simplex:/` still reads 4 occurrences in 4 files outside these two records, and none of the four is code
(`POPOPX-REBRAND-PLAN.md`, `CHANGELOG.md`, `PRIVACY.md`, and the live `.github/ISSUE_TEMPLATE/question.yml:9`,
whose occurrence sits inside a working upstream invitation URL - the reason "all records" above is the wrong
label and `FORK.md` states the four by name). `POPOPX link` reads 579 occurrences in the same 91 files, the 3
extra being these records. `simplex_name` reads one more than the 24 above, in the same 9 files - the pass's own
count already included 6 record quotes, and the code side is unchanged at 18 (16 Haskell + 2 plan), so what grew is
the quoting, now 7:
`[@#]<name>.simplex` reads 31 in 6 files: the MCP package's 20 are unchanged, and the other 11 are these two
records quoting the examples they rule on - so the "2 WebRTC" line above does not reproduce in any tree this
repository holds, and is left unrepaired rather than rewritten into a guess (the only WebRTC spellings carrying a
dot are `stun.simplex.im` and `turn.simplex.im`, which are hosts on `simplex.im`, not `.simplex` names;
`PRIVACY-POPOPX.md` holds no such occurrence at all, its `.simplex` string being `simplexonflux.com`).
This paragraph quotes the very spellings it counts, so a recount taken after reading it runs higher than the
numbers above - the stable facts are the *file* counts and which files those are.

What this paragraph said when it was written - that nothing here was compiled by CI and **nothing was pushed** -
is no longer true, and the push is the part a reader can check from this checkout: the branch was authorized and
landed the same day, so `origin/master` moved past these commits. Measured 2026-11-16, `git rev-list --count
origin/master..HEAD` reads **1** on tip `667c102d4` - and that one commit is the badge-web tier below, not these
records. Re-read the command instead of copying a SHA or a status; either way the sentence is about GitHub or
about a moving branch, and both go stale mid-sentence. What did not change is the *kind* of proof: the Haskell
side rests on the local generator run above and on a real compile -
`cabal build test:popopx-chat-test` rebuilt and linked the test executable, which is what compiles every
module this tier edited (`Preferences.hs`, the directory service, its three mirrors, `MarkdownTests.hs`,
`Profiles.hs`, `Commands.hs` and `Test.hs`). The iOS and Kotlin document edits need no build, and the
Android/desktop legs remain static verification as elsewhere in this section. CI's own verdicts are named by run
id where they were read, and no line here claims a badge for a commit it cannot name.


### The rest of the name/address tier, and the one unit only a rendered-text run could prove (2026-11-15, rulings 必改 the rest + 需要确认的按照建议进行)

68 occurrences moved. The residue of #109 is now **4 occurrences outside the record files** — the 3 hspec titles
and the historical AppStream release note, which is exactly the `不能改` set — plus the mentions in the record
files themselves, which quote the phrases they rule on.

**必改, 62 occurrences / 59 lines.** `src/log.ts` 7, `src/tools.ts` 3, `src/cli.ts` 1 and their mirrors
`test/unit/log.test.ts` 7, `messages.test.ts` 2, `options.test.ts` 2 — the pairing is 11 to 11, which is what a
stale-expectation sweep cannot break: both counts went to 0 in the same commit. `bot.ts` 3 + `api.ts` 1 and the
7 nodejs mirrors, which are `it` titles only (jest selects by file, so these are cosmetic). `PLAN.md` 16,
`spec/api.md` 3, `spec/architecture.md` 2, `spec/flows.md` 1, `REFERENCE.md` 2, `TESTING.md` 1,
mcp `README.md` 2 (its "your SimpleX address" was stale against the shipped "POPOPX address"),
`apps/popopx-calculator-bot/README.md` 1, and the `Controller.hs:1501` comment. PLAN.md mattered beyond prose:
its table at 808/819-825 **transcribes the apps' error text**, so it is a mirror of `log.ts` and had to move in
the same commit. Gate: mcp `274/274`, nodejs `54/54`, both suites run locally.

One occurrence outside the ruled count moved because it shares a ruled sentence: `tools.ts:403` now reads "by a
**POPOPX link** or a **POPOPX name**". Leaving it would have shipped a sentence that names our feature twice,
differently. It is 1 of the 64 `SimpleX link` occurrences (31 files; 60 outside the record files) still in the tree —
that cluster (mcp and nodejs
sources, their typedoc and spec mirrors, the generated `bots` docs, 4 hspec examples, `Preferences.hs`) remains
a tier of its own and was not ruled.

**需裁定, 6 occurrences, executed as recommended.** `Directory/Service.hs:380/1174` builds
`"\nPOPOPX name: "` into the text a directory user sees, and the only readers of that exact string are
`tests/Bots/DirectoryTests.hs:2263/2296`, so the four lines are one unit. `cabal build all` proves nothing about
it, because the mismatch would be a runtime string comparison — so the unit was *run*: `-m inconsistent` →
`2 examples, 0 failures`, and `-m verify` → `21 examples, 0 failures` including
`should verify and show a channel's SimpleX name [✔]` and the NOT-verified mirror. The titles themselves stayed
upstream's spelling, which is what kept those selectors working. The reason for moving the pair now, rather than
at deployment: the text is ours to render the day this fork runs its own directory service, and shipping it
still saying "SimpleX name" is the misattribution the rebrand exists to remove. Plus `bots/README.md:115` and
`README.md:47` — the label became POPOPX, the address payload `https://smp6.simplex.im/a#…` stayed, because that
relay is upstream's.

Verification note: every changed line in all 23 files was checked against `HEAD` by normalizing the tokens
back — 65 insertions, 65 deletions, **0 lines differ by anything other than the ruled wording**.

### The generated bot API docs: 6 literals rewrite 9 output lines (2026-11-15, ruling 必改 the 6 literals)

Of the 93 `SimpleX name` / `SimpleX address` occurrences measured in #109, one tier has its far end **inside
this repository**: `bots/api/COMMANDS.md`, `bots/api/EVENTS.md`,
`packages/popopx-chat-client/types/typescript/src/commands.ts` and
`packages/popopx-chat-python/src/simplex_chat/types/_commands.py` are written by the test-suite, not kept by
hand. `tests/APIDocs.hs` `testGenerate` reads the current file, writes the generated text, then asserts the two
are equal — a drift detector that is **supposed to go red the first time after any literal moves**. So editing
those four files by hand would be undone by the next `cabal test`, and editing only the generators would leave
the suite red. The only correct move is literal + regeneration, in the same commit.

Moved: `API/Docs/Commands.hs:86` ("Set or remove **POPOPX name** of bot address…"), `API/Docs/Responses.hs:105`,
and the four in `API/Docs/Events.hs` (**POPOPX address**) — matching the app's shipped wording (`8326d77e3`) and
the identifiers already sitting next to them (`CEPopopxDomainNotReady`, `popopxDomain`, the `popopx_name` tool
field). No other file in the repo quotes any of the six sentences: each exact string greps to 0 hits outside
these seven files.

The gate is a recipe worth repeating, because the harness is a generator and not a comparator:
`cabal test popopx-chat:test:popopx-chat-test --test-options='-m <markdown|TypeScript|Python>'` — three runs,
11 writing specs between them. `-m generate` is **wrong**: it matches 20 examples and drags in the badge C-API
and captcha specs. Run *before* editing it reported `138 / 4 / 4 examples, 0 failures` and left the tree
byte-identical, which is the proof that the 9-line diff afterwards belongs to this change and nothing else.
Re-run after the edit: same counts, 0 failures. Both halves of the pair now measure 0 — 6 generator literals and
9 generated lines — and the residue of #109 at this commit is 72 occurrences outside the record files, 81
counting this document, which quotes the phrases it rules on. The next section brings that 72 down to 4.

Left untouched by the same ruling: the `需裁定` unit `Directory/Service.hs:380/1174` `"\nSimpleX name: "` with
its two exact-text `<##` mirrors at `tests/Bots/DirectoryTests.hs:2263/2296` (that text is rendered by a
directory service we do not operate yet, so our build would differ from what users see), and the `不能改` set —
the 3 hspec titles (`DirectoryTests.hs:113/114`, `MarkdownTests.hs:492`) which are CI `-m` selectors, the
historical AppStream release note, the record files, and the printed `npx -y @simplex-chat/mcp …` instructions,
whose package is still published under that name.

### The last five naming sub-tiers, ruled together: A to E (2026-11-15, ruling 推 8 个；A+D 执行，B 改 popopx-mcp，C+E 执行，E 关闭)

The residue left after the naming unit was five tiers, each with a different far end. They were ruled in one
reply and are executed here as one commit, 49 files. What decided each was not the token but **who reads the
value**:

- **A - Haskell identifiers (16 files, 59 replacements).** Only code positions moved: `simplexChatCore`,
  `runSimplexChat`, `simplexChatTerminal`, `simplexChatCLI`, `simplexChatContact`, `simplexChatInvitation`,
  `simplexChatServer` became popopx-spelled, whole-word. Every **string literal was preserved byte for
  byte**, per the standing Haskell ruling, so `Operators.hs:94/98` still maps `"simplex" -> OTSimplex`,
  `server_operator_tag` still writes `'simplex'`, and the persisted values are untouched. Identifiers that
  *name an upstream thing* also kept their name: `operatorSimpleXChat` 9, `simplexChatRelays` 9,
  `simplexChatSMPServers` 7, `OTSimplex` 4, `ConnectSimplex` 3 - re-measured after the pass, all unchanged.
  The gate is real, not a grep: `cabal build all` (library + 8 executables) and
  `cabal build popopx-chat:test:popopx-chat-test`, both green. It earned its cost - the first run was red on
  three `apps/**` modules that a `src`/`tests` census does not see, which is how the pass learned that the
  fork's own services import `Popopx.Chat.View`.
- **B - the MCP server's identity is ours, the command the user types is not.** `serverInfo.name` becomes
  `popopx-mcp` (`serve.ts:115`), with its e2e assertion moved in the same commit; `bin simplex-mcp`, the
  usage text and the `simplex-mcp:` error prefix stay, because that spelling is `package.json` `bin` and is
  rewritten only at publish time. The `customData` keys `simplexMcp`/`simplexMcpFiles` were refused: they are
  JSON members the core persists in the agent's database, so renaming one silently forgets approvals an
  already-running agent stored - the reason is now a comment above the key in `control.ts`.
- **C - the Node.js facade moved, its two pinned neighbours did not.** `src/simplex.js`/`simplex.d.ts` →
  `src/popopx.*` and the `import * as simplex` in `core.ts` follow, because nothing outside the package reads
  those names. `cpp/simplex.cc`/`simplex.h` **cannot** move: they are `ADDON_SOURCES`, the input to
  `current_addon_hash()`, which is the published `nodejs-addon-<hash>` tag pinned in `src/release.ts` - and
  no lane exists to publish a re-hashed add-on (`secrets.NODEJS_REPO_TOKEN` is absent, #82). Python's
  `logging.getLogger("simplex_chat")` likewise stayed: that string equals the import path of the
  distribution `simplex-chat`, which is a ruled-hold registry name. `popopx.d.ts` records which file it is
  typing and why that name is load-bearing.
- **D - the docs that still described the previous round.** `CreateSimpleXAddress` → `CreatePOPOPXAddress` in
  12 places across `apps/{ios,multiplatform}/{spec,product}`, because the code was renamed two tiers ago and
  only the documents lagged (`App.kt:195 Step3_CreatePOPOPXAddress`, `OnboardingView.swift:51
  step3_CreatePOPOPXAddress`, and `CreatePOPOPXAddress.swift` is a real path). The 6 `SimpleX.AppImage`
  fixtures in `AppLinkSchemeTest.kt` moved as inert input. Held: the persisted raw values of
  `OnboardingStage`/`enum …: String, Identifiable`, which iOS writes to `UserDefaults`
  (`onboardingStageDefault.set`), and everything that names an upstream-operated destination.
- **E - `scripts/ci`, and three of its lines were already broken.** Two of them are repairs this repo caused,
  not brand edits: `package-tests.sh:22` and `scope-tests.sh:16` still ran `cp src/simplex.* dist` after C
  moved that file, which would have made every Node.js CI step ship a `dist/` without its facade; and
  `android/smoke-test.sh:29` matched the on-screen text `Search or paste SimpleX link`, which the app has not
  rendered since the display tier - `strings.xml:517` says `Search or paste POPOPX link`. The rest were stale
  citations of this repository's own producers, each checked against the producer first: the artifact is
  `POPOPX.app.tar.gz` (`ios-sim.yml:210`), the cabal executables are `popopx-chat` /
  `popopx-directory-service` (`build-backend.sh:25/37`), the library this repo builds is `libpopopx.so`
  (`build-lib-linux.sh:38`), the Swift preview is `BadgesSupportPopopxView_Previews`, the API paths are
  `/repos/<owner>/popopx-chat/actions/...`, the test backend's feature heading - which `ios-sim/backend.sh`
  *generates* and `claude-prompt.md` *reads*, so both sides moved together - is now "POPOPX names".

**Held, with the reason recorded rather than assumed**: `lib:simplex-chat` is a **Nix attribute path**, spelled
that way in 10 places in our own `flake.nix` and consumed as a command argument by `build-core.sh:14` and
`scripts/android/build-android.sh:108`, so the CI citations are true and renaming the attribute is a separate
change; `release-apk.sh` and `release-app.sh` download **upstream's** signed APK and **.deb** and assert
against upstream's fingerprint and `/opt/simplex`, which is why `reproduce-builds` could only ever verify
their build; `smoke-test.sh:287`'s `for operator in "SimpleX Chat"` is a preset operator name the core
returns; `SIMPLEX_LIBS_DIR` is the second spelling of the ruled dual loader. All 23 held lines were
re-measured, and the residue in `scripts/ci` is exactly those 23.

**Newly measured, NOT touched - and #101 closes with it open.** "SimpleX name(s)" survives in 71 lines / 26
files outside `scripts/ci`, and unlike the tiers above most of it is **user-visible text this fork writes**:
`packages/popopx-chat-mcp/src/log.ts:75-130` mirrors the apps' error wording the moko resources now render as
"POPOPX name error", `tools.ts:230/403/432` describes the tools to the model that reads them,
`bot.ts:194-201` logs it, and `apps/popopx-directory-service/src/Directory/Service.hs:380/1174` emits
`"\nSimpleX name: "` into a listing - a Haskell **literal**, so the standing ruling protects it and moving it
means moving its `DirectoryTests.hs:2263/2296` `<##` mirrors in the same commit. `MarkdownTests.hs:492`'s
describe title is held as every other hspec title is, because CI selects on it.

### The app's own link scheme became popopxchat:, with the old spelling left working (2026-11-15, ruling 可以多个则增加 popopxchat://)

`appLinkScheme = "simplexchat"` was the last unresolved item of the apps/ios tier: residue, or something with
a far side? Measured, the second - one cross-process value with **1 producer, 2 recognizers and 7
registrants**, and iOS already registers two schemes today: `POPOPX--iOS--Info.plist` declares
`com.popopxchat.popopx -> [popopx]` and `com.popopxchat.popopx.deeplink -> [simplexchat]`. "Only one" was
never the shape, so the value was added to rather than replaced: `popopxchat` is now the name this project
issues and registers first, and `simplexchat` stays registered and stays recognised.

- **Producer (1)** `apps/popopx-badge-service/web/src/routing.ts:24 appCodeLink()` - the badge page decides
  what the browser hands to the OS, so this single line is what a user actually clicks. It emits
  `popopxchat:/badge/code/<code>`.
- **Recognizers (2)** iOS `ContentView.swift:isAppLink` and Kotlin `ChatListView.kt:isAppLink` now accept
  either spelling, so a code handed over before the move still redeems instead of falling into the
  connection branch (where it would fail as a malformed link). `AppLinksTest.acceptsTheLinkSpelledWithTheInheritedScheme`
  guards the legacy half, because a compatibility claim with no test in front of it is an absent guard.
- **Registrants (7)** the iOS deeplink array, `AndroidManifest.xml`'s app-link intent-filter, the jpackage
  macOS plist in `desktop/build.gradle.kts`, `distribute/popopx.desktop`,
  `scripts/flatpak/com.popopxchat.popopx.desktop`, and the deb's `SCHEME_MIME_TYPE_LINE` with its own
  `grep -qxF` guard in `scripts/desktop/make-deb-linux.sh`. Each lists both, so a fresh install answers
  either. The three Linux MimeType lines are now byte-identical to each other.
- **Two registrars deliberately kept single-scheme**: Windows HKCU and the AppImage entry, both written at
  runtime from the one `appLinkScheme` const in `AppLinkScheme.desktop.kt`. Neither has a published build
  (`releases/latest` is still 404), so no `simplexchat:` desktop link is out there to answer for, and
  registering a third means re-ordering assertions that compare the exact sequence of writes
  (`shell.writes.take(3)`, `assertEquals(… + windowsProgIdValues("popopx", …), shell.writes)`) in a
  680-line file this machine cannot compile - there is no Java runtime here, and 29 scheme literals went
  through it as a pure 1:1 substitution. A rename keeps every one of them testing what it tested. The asymmetry is stated at `AppLinkScheme.desktop.kt:61`.

Gates, one per end. **badge-web `npm test` = 525/0**, and the suite caught the third end before I did: its
own build gate failed, because tracked `public/index.html` names the bundle hash on disk - editing
`routing.ts` without `npm run build` is red, so the rebuilt bundle is in this commit. Those tests also hold
the leak guard "nothing the page wrote to history or storage holds the link", which was written as
`!url.includes("simplexchat")`; keyed on the scheme it would have gone quietly false under a rename, so it
now looks for `/badge/code/`, which no spelling hides. **iOS `xcodebuild build-for-testing`** compiles the
changed Swift and the plist parses to the two expected arrays. **Kotlin: static only** - CI is the only
compiler here, and the desktop run has to read this tip.

The five spec/product sentences that describe all this were corrected too, and two of them were not merely
un-rebranded but wrong: they still called the connection scheme `simplex:` (it moved to `popopx:` in #3) and
the Windows ProgId prefix `SimpleX.<scheme>` (the code says `POPOPX.`), and the `ChatListView.kt` line
anchors cited 797/826/829 where the file now says 807/839/832 - re-measured against the file, not
guessed. The change itself is 25 files / 90 insertions / 69 deletions, `popopxchat` as the scheme in 37
occurrences across 17 tracked files; everything else in the diff is these two paragraphs of record.

### Preset relays stay upstream's by decision, until ours exist (2026-11-15, ruling 先使用上游的 smp 服务器)

Ruled: the app keeps using upstream's SMP/XFTP presets, and the presets move when this project has its own
POPOPX relay. **No code changed** - they have pointed at `*.simplex.im` with upstream's keys since the
service-destinations pass (#3), so this closes the "empty them / replace them now" idea rather than
executing anything. Recorded here so that pass is not improvised later:

- `simplexChatSMPServers` (`src/Popopx/Chat/Operators/Presets.hs:42-77`) holds **host and key** pairs, and
  the enabled list is a `NonEmpty` - the type is why "just empty the presets" was rejected, not policy.
- Renaming one half is the exact failure the `pairs` gate watches for: the client compiles, encodes, sends,
  and the server answers `UNKNOWNCA` while the app retries forever. A new relay therefore arrives with its
  own key, and both move in the same commit, together with the `tests/**` mirrors and the two
  `scripts/ci/*/backend.sh` harnesses that read the same hosts.
- The operator record moves with it, not before it: `operatorSimpleXChat`'s trade name and the
  `simplex.im` it states are SimpleX Chat Ltd's, `CARequired` makes that name a party to the user's consent,
  and `0a5adde7d` reverted an earlier attempt at exactly this. Until our relay has an operator of its own,
  naming it POPOPX would claim an identity that is not ours - the same test the section above applies to a
  display name.

### A display name moves with its speaker, not with its spelling (2026-11-15, ruling 需裁定 进行改正)

The 需裁定 tier of the four-way sweep listed, by directory, the body text the sweep can reach. Reading it
produced a rule finer than "is this our brand": **a name moves only when the string is us speaking.** Three
cases fell out on opposite sides of it, and the difference is not the word `SimpleX`.

- **Us naming ourselves - moved, 511 occurrences / 20 files (6 of them the test-group selector below).**
  `apps/popopx-badge-service` and
  `apps/popopx-directory-service` are code this fork runs, and each was introducing itself to *our* users as
  `SimpleX Badges` / `SimpleX Directory`: the `--service-name` defaults
  (`BadgeService/Options.hs:41`, `Directory/Options.hs:137`), their help and `progDesc` text, the startup
  banners, the directory's served page and READMEs, and the ini examples. The directory's own welcome
  message already ended with `https://popopx.chat/docs/directory.html` while opening with "Welcome to SimpleX
  Directory" - one sentence, two operators, which is what made it residue rather than a citation.
- **The other party's name - held.** `adminContactProfile` at `src/Popopx/Chat/Library/Internal.hs:3501` is
  the contact the core auto-creates for every user, `displayName = "Ask SimpleX Team"`, and `shortDescr` one
  line below already says "POPOPX Chat app". That half-drift looks like a bug, but `adminContactReq` is a
  proof-bearing encoded address on **`smp6.simplex.im` with upstream's server key** - the preset contact
  really is SimpleX Chat Ltd's support line. Renaming it would advertise someone else's support desk as ours,
  in the one place a user acts on the name. `Help.hs:53` already holds `/simplex` for the same reason. Same
  test, same answer, for the `packages/popopx-chat-mcp` fixtures (110 occurrences): each
  `name: "SimpleX Directory"` sits beside upstream's `smp4.simplex.im/a#…` address or the `@directory.simplex`
  alias, and a peer's display name is whatever that peer declared - our local alias beside it is already
  `@directory.popopx`. The python SDK's one fixture is a fake API reply for the same kind of peer profile.
- **A name whose value is set elsewhere - held.** `"simplex-badge-web"` in
  `apps/popopx-badge-service/web/package.json` is unread in this tree (no importer, no publish scope - the
  `badge-web` CI scope globs paths, not the package name), so nothing here can prove whether that name was
  ever published. That is the third end again, so it waits for the same evidence the SDK asset names needed.

The moved group was **one unit, and two comments in this repo already said so**: `scripts/ci/desktop-linux/backend.sh`
and `scripts/ci/ios-sim/backend.sh` carried "Kept: … the three move as one unit, not from here", naming the
producer default and `tests/Bots/DirectoryTests.hs:117`. An earlier pass declined to edit the harness string
alone, correctly, because the CI backends start the service **without** `--service-name` and then assert on the
name - change one end and the harness silently talks to a bot it can no longer find. All four ends moved here
(default, seeded profile, 454 assertions in the hermetic suite, both harnesses) plus `tests/Test.hs`'s two
`describe` labels, which are not CI selectors (`-m` appears nowhere for them, so the label is free). The two
`Kept:` comments now state the coupling instead of recording a hold that no longer exists.
Gate: `cabal build popopx-chat-test` compiles **every Haskell file this tier touched** - that target also
builds the two services' sources (`Directory.Options/Service`, `BadgeService.Options/Service`), so there was no
"static verification only" excuse here - and the hermetic examples run green: 4/0 for the ini `display_name`
cases, 2/0 for the two unit cases carrying the moved `"POPOPX Badges"` literals. Both `backend.sh` harnesses
pass `bash -n`. `packages/popopx-chat-mcp` has no `vitest` binary installed, so its fixtures were not executed -
which is also why they were left alone.

Reading the suite's own tree surfaced a residue the text sweep could not see: the top-level hspec group was
named **"SimpleX badge service"**, and that label is a *selector*, not prose. `scripts/ci/run-tests.sh:15` feeds
each line of a PR body's ` ```ci-tests ` block to `-m`, and `scripts/ci/README.md:102` documents the selected
tests as `/SimpleX badge service/` and `/SimpleX badge service e2e/`; `apps/popopx-badge-service/web/README.md:135`
carries a copy-pasteable `cabal test --test-options=…` with the same string. Moving the label therefore had to
move its four mirrors in the same commit - the recurring lesson that a test group name is a wire value with a
reader outside the file. It failed loud enough to be safe either way: `run-tests.sh` appends `--fail-on=empty`
whenever a selector was supplied, so a stale `SimpleX badge service` in some future PR body stops the job
instead of quietly running nothing. Verified by selection count - the new selector resolves to **412 examples**,
the old one to **0**.

The `src/Simplex/` half of the same sweep ran first: **191 references rewritten** in 17 documents, because
`05dd5a73c` moved the module tree and the docs kept pointing at a directory that no longer exists. Counting
lines rather than occurrences had overstated it as 194/20 files; 3 of those occurrences are in
`FORK.md`, `CHANGELOG-POPOPX.md` (now `CHANGELOG.md`) and `POPOPX-REBRAND-PLAN.md` (deleted 2026-11-25) and **are** the record of the rename, so they
keep the old spelling. Resolution was checked against the filesystem, not by grep: 121 distinct path tokens
now land on a real file, 8 more (`src/Popopx/Messaging/…`, `FileTransfer/…`) land in the **popopxmq**
dependency, whose tree has the same layout, and the 31 that look unresolved are table cells and prose whose
sentence states its own base directory - zero markdown links were broken either way.

### Which repository may publish, and the two values that shared one spelling (2026-11-15, rulings 使用 popopxChatCore + 名称更新)

- **`.github/workflows/build.yml:59`** (`release_branch`) compared `github.repository` to
  `simplex-chat/simplex-chat`, so the branch guard that decides *what may be released* resolved to the empty
  string on every one of our own runs. It now reads `github.repository == 'popopx-chat/popopx-chat'`
  (`4a7f674b1`). **What this does not yet change: `build.yml:136` (`reduced`) still tests
  `github.repository != 'simplex-chat/simplex-chat'`** — the second reader of the same value, consumed at 14
  steps — so our pushes keep running the reduced matrix. That is a *different* decision (which jobs a fork
  run owes you) and is listed for ruling, not folded in here.
- **`simplexChatCore` was two values sharing a spelling**, and only one of them is a build boundary: the
  JSON field in `packages/popopx-chat-client/types/typescript/package.json` and its reader/writer
  `scripts/ci/packages_release.py:730/:775`. Both ends are in this repository — measured: the `-libs`
  repository has **0** occurrences of either spelling, and `releases.toml` there keys `[core.master]` by
  version→SHA, never by this field — so renaming the field to **`popopxChatCore`** moved 14 occurrences /
  3 files (4 in the script, its 9 test fixtures, 1 in `package.json`) with no third end to chase. The field
  also *guards a version pair*: it said core `7.1.0.18` while `popopx-chat.cabal:8` says `7.1.2.0`, and
  `types_problem()` refuses a release unless they agree. Both now read **`7.1.2.0`**, with the
  `POPOPX Chat core: 7.1.2.0` line that `TYPES_README_CORE` requires (`README.md:7`). The Haskell export
  keeps its name (20 occurrences / 13 files) — it is a public identifier of `Popopx.Chat.Core`, and a
  rename of it needs `cabal build` over the library and all eight executables as its gate, so it is listed
  for ruling rather than folded into a scripting commit. **Verification here is static**: this suite needs
  `tomllib` (Python ≥ 3.11) and `python3` on this machine is 3.9.6, so it is a CI-only gate.
- **The generated overlay directory is named for us.** `apps/multiplatform/common/build.gradle.kts:15` and
  the `apps/multiplatform/.gitignore` entry moved `resources/assets/simplex/` → `resources/assets/popopx/`.
  Only the *destination* is affected — the 4 CI callers pass the source (`-Ppopopx.assets.dir=../../assets`),
  and `verifyPopopxAssets` checks that source — so this is a rename of a gitignored build output, with no
  reader left behind: `assets/simplex` survives only in this file's records (3 occurrences, all markdown),
  and 0 lines outside markdown in the whole tree.
- **Two generators outside this repository were still writing upstream names.**
  `tools/r7/popopx_logo_sync.py` emitted `distribute/simplex.{png,icns,ico}` while the tracked files and both
  consumers (`desktop/build.gradle.kts:68,73,82`, `make-appimage-linux.sh`) read `popopx.*`, and its brand-kit
  manifest `tools/r7/popopx_brand.py` named 10 repo paths that no longer exist (`images/simplex-chat-logo*.svg`,
  `images/how-to-use-simplex.svg`, 8 `media-logos/simplex-*`) plus 2 resample targets whose `size(dst)` read
  would have failed outright. A re-run would therefore have written untracked `simplex.*` files *beside* our
  own and refreshed nothing. All 15 target paths and the 6 docstrings that name them now point at the tracked
  `popopx.*` files, whose pixel sizes match the manifest exactly (measured with `sips`: 1024², 276×276,
  279×276, 768×190, 768×189, 512²) and whose derived source names match the 15 tracked
  `branding/source-svg/{images,media-logos}__popopx-*` masters. `py_compile` passes on both files.

### The last upstream drawings compiled into the desktop and Android apps (`2a967acb0` + `b6a3ee009` + `0a7b7172f` + `23e22c439`, 2026-11-15)

Three asset sets reach a desktop/Android build, not one. `assets/multiplatform/resources/MR/images/**` is an
*overlay* selected by `-Ppopopx.assets.dir=../../assets`: `build.gradle.kts:14-37` `Sync`s it into
`src/commonMain/resources/assets/popopx/MR/images` (that directory is generated and gitignored; it was named
`assets/simplex` until the 2026-11-15 pass), and deletes that directory when the property is absent.
It was replaced first (ruling C2). `apps/multiplatform/common/src/commonMain/moko-resources/images/**` is a
plain moko source directory, so it is compiled in **both** cases - with or without the overlay - and it still
carried upstream's artwork after the overlay went.

- `2a967acb0` redrew the 29 illustrations: `decentralized`, `decentralized_light`, `privacy` and `shield` at
  @1x/@1.5x/@2x/@3x/@4x (20 files; the first two are the default `ServerOperatorInfo` logo,
  `PopopxAPI.kt:4781/4783` and `dummyOperatorInfo` `:4866/4868`), the 6 `wallpaper_*@4x` tiles and the 3
  `badge_*.svg`, from vector masters added as `branding/source-svg/moko__*.src.svg`, each at its original
  pixel size.
- `b6a3ee009` redrew 6 more that `2a967acb0` had filed as Google Material geometry and which are not:
  `ic_double_check.svg`, the 4 `ic_radiowaves_up_forward_{1,2,3,4}_bar.svg` and `ic_heart@4x.png`. Its parent
  asserted that "the 257 `ic_*` files are Google Material Symbols geometry", which measures wrong for 9 of
  them: 248 do carry Material's `viewBox`, 2 are Material path data on another grid, 1 is GitHub's octocat and
  6 are SimpleX's own drawings.
- The first `ic_double_check` was replaced twice. Delivered as one glyph it read as a **W** at the 22px it
  renders at, because the left tick's upstroke crossed the right tick's downstroke. The fix is not an
  opinion: rasterise the replaced file and the candidate at intrinsic size and compare measured ink.
  Upstream's is a *filled* Fabric.js path (`viewBox="0 0 48 48"`, `matrix(0.05 …)`) whose four sizes put
  9/28/61/110 opaque pixels inside a 20x10 box; the crossed version put 69 px on the same canvas. `0a7b7172f`
  ships separated ticks at stroke 1.8 - 9/30/64/112 inside upstream's exact box.
- `23e22c439` installs the baselines those glyphs move. CI run `43709521708`, dispatched on `0a7b7172f` with
  `headSha` read back before anything was consumed, rendered 210 files: **202 byte-identical to what was
  committed, 8 changed** - `ChatInfoView` x2 and `GroupChatInfoView` x2 (the double-check ticks) and
  `SettingsView` x2 and `WhatsNewView` x2 (the `decentralized` operator logo, 19x24 in the row-icon column),
  each light+dark at font-100. The control that this is the artwork and not a flaky renderer: this run and
  `43704584787`, from two separate runners on adjacent tips, differ in exactly 4 of 210 files, and those 4 are
  exactly the ones whose glyph changed between `e90c911e0` and `0a7b7172f`. Everything else reproduced
  byte-for-byte, so an unexpected diff means an unexpected change.

Census after all four, measured with the brand-restored-path recipe in `ASSETS_LICENSE.md`:
**1562** tracked images, **911** ours (559 differ from upstream's, 352 have no counterpart), **651**
still byte-identical to upstream's. The same-path-only version of that recipe claimed 147 upstream files as
ours, because this fork renamed `packages/simplex-chat-*` to `packages/popopx-chat-*`; names move, blob ids
do not. Measuring `HEAD:<f>` right after installing also read 655/190 - an installed file is in the index,
not in `HEAD`; `git add` first, then measure `:<f>`. What is still upstream's is now geometry and
documentation rather than brand art (272 Material Symbols, 42 empty placeholders, 186 + 130 renders of
scenes with no artwork in them, Apple's SF Symbols, GitHub's octocats) except for 4 files: the 2
`packages/popopx-chat-mcp` UI screenshots and the 2 Haskell logo fixtures, which needed a Haskell run to
replace (`Forward.hs:850` asserts the transferred size; `ImageTests.hs:103` and `:262` assert the PNG's
structure). Those 4 went the same day - see the next section.

### The last 4 upstream images: 2 Haskell logo fixtures and the 2 MCP screenshots (2026-11-15, ruling "…进行运行替换")

The ruling asked for a run, and the run is the whole story of the fixtures: `tests/fixtures/logo.jpg`
(200x200) and `logo-large-rgba.png` (1630x466) are read by **10 examples in 4 files**, and replacing the bytes
without moving the mirror is red, not neutral. Measured before touching anything, then re-run after:

- `logo.jpg` 32080 -> 6074 bytes, so `Forward.hs:850` and `Files.hs:190` - which hold the *same* assertion in
  two suites - both moved from `(31.3 KiB / 32080 bytes)` to `(5.9 KiB / 6074 bytes)`. First run was red on
  exactly that line with the old string expected, which is the stale-mirror class, not a failing feature.
- `logo-large-rgba.png` 28676 -> 68521 bytes at the same 1630x466, RGBA8 with transparency and the same aspect,
  because `ImageTests.hs:103/:262` assert those properties and `MobileTests.hs:390/:408` assert the PNG magic.
  What the two new bytes *are*: `logo.jpg` is this fork's app icon at 200x200 - the same mark as
  `apps/ios/Shared/Assets.xcassets/popopx_app_icon.imageset/popopx_app_icon.png` - and `logo-large-rgba.png` is
  the POPOPX wordmark banner, rendered from
  `branding/source-svg/tests__fixtures__logo-large-rgba.png.src.svg`. Neither reuses upstream's logo.
- The consumers, by their real group paths: `POPOPX chat client > file tests > messages with files` -> "send
  image with generated preview" (`Files.hs:187`), `file tests > file transfer over XFTP without chat items` ->
  "send and receive small standalone file" and the same "with extra information" (`:1332/:1357`),
  `forward tests > multi forward api` -> "with relative paths: multiple files from contact to contact"
  (`Forward.hs:801/:850`), `profile tests > user profiles` -> "set profile image from file" (`Profiles.hs:1221`);
  plus the 3 `Image resize` readers and the 2 `Mobile API Tests` C API readers. Two
  of them bound a *derived* length from above (`preview <= 14000`, `img <= 12500`), so smaller source bytes cannot
  break them - and they were run, not reasoned about: `-m '/Image resize/'` = 29 examples / 0 failures, the 2
  C API examples = 2 / 0, the 5 chat examples = 5 / 0 (`cabal build popopx-chat:test:popopx-chat-test` rc=0).
- How to select them: `-m` is matched **componentwise from the top-level group**, so a wrong first component
  silently matches 0 examples - `/POPOPX chat client/image data/` and `/Mobile API Tests/Images/` both returned
  0 while the real groups are `Image resize` and (nested deeper) `Mobile API Tests`. A plain leaf title matches
  from anywhere, which is the reliable form here.

The 2 `packages/popopx-chat-mcp` screenshots (742x1489) were rebuilt as vector mockups of the POPOPX agent
chat - no upstream UI, no third-party brand depicted, the app's own strings for the encryption notice and the
approval cards - from `branding/source-svg/packages__popopx-chat-mcp__images__*.src.svg`.

The part a byte-level pass cannot see: a published image has a **third end, the host that serves it**.
`README.md:10-11` pointed at `raw.githubusercontent.com/simplex-chat/simplex-chat/...`, so replacing the
repository's copies would still have shown readers upstream's art. Both `<img src>` now name
`popopx-chat/popopx-chat/master/...` and both return 200 (direct egress; they serve the new bytes once
pushed). The README's prose - "SimpleX MCP server", "SimpleX Network", the 3M downloads / 600k users figures,
"SimpleX Directory", `mcp__simplex-my-agent` - is untouched and awaits ruling (#100).

Census after this pass, against the index with the recipe in `ASSETS_LICENSE.md`: tracked 1562 -> **1565**
(the 3 new `.src.svg` masters), still upstream's 651 -> **647**, ours 911 -> **918**. `packages/**` upstream
images 13 -> **11**, `tests/fixtures/**` 7 -> **5**. Nothing in this repository is upstream's *artwork* now;
what remains byte-identical is glyphs, empty placeholders, unchanged renders and third-party marks.

### The 72 overlay illustrations that were still blue, and the patch that never reached them (2026-11-15, ruling 80 张 assets/** 覆盖层图…进行运行替换)

The ruling counted 80 files in `assets/multiplatform/resources/MR/images`; the measurement is 72. The 8
`popopx_address*` files are not blue - they were resampled from the iOS master by `9c8df8f09` and read
hue 271-274, already the brand. They are also the only files in that directory with no
`<concept>_<theme>.svg` master, so `popopx_assets.py` would have redrawn them from a different scene had
the pass not stopped at the masters that exist.

Why they stayed blue: `master_palette.install()` patched `popopx_assets`' four module constants
(`BLUE/TEAL/CYAN/DEEP`) but not the `L`/`D` role dicts, which were built from the pre-sync values at
import time and are what the scenes actually read - 5 `ink`, 8 `soft`, 3 `line`, 13 `paper` sites. The
brand kit moved, the illustrations beside it did not, which is the two-targets-two-brands failure the
module's own docstring exists to prevent. Second cause: `popopx_assets.main()` writes a vector master
only `if not os.path.exists(src)`, so the 36 tracked masters were frozen and re-running the generator
would not have touched them.

Executed as `tools/r7/r98_overlay_purple.py`: the dicts are now patched (`L.ink #062A3A→#3D0A6D`,
`L.soft #D6F0FA→#EBDCF7`, `L.line #A9DDF0→#C9A6E4`, `L.hi #0088FF→#7A2BBE`, `L/D.paper #FFFFFF→#FAF6FE`,
`L.opaque #EAF7FF→#F3E8FB`, `D.ink→#F3E8FB`, `D.soft #0E3A4F→#2C0B4A`, `D.line #2A6F8C→#5B2A86`,
`D.hi #70F0F9→#9B5FD0`, `D.opaque #041C28→#1A0533`, and the gradient stops `TEAL→#3D0A6D`,
`CYAN→#9B5FD0`), the 36 masters are **redrawn** from the patched generator and 72 rasters re-rendered.
Redrawn, not hex-substituted: `t["paper"]` and the literal `"#FFFFFF"` were the same colour before and
are different colours after, so only the generator can tell the two roles apart.

Gates, all 72: the colour-stripped master is byte-identical to the tracked one (geometry untouched); the
**alpha plane hash** of the new render equals this renderer's own re-render of the *old* master and also
equals the committed bytes, so nothing but RGB moved and the committed files did come from this `svg2png`;
blue-pixel census `63043 → 0` on `your_network@2x` and 0 blue pixels in all 80 files; names and pixel
sizes of all 80 verified against the pre-recolour snapshot. Diff: 108 asset files (36 text, 72 binary).

Not yet done: the overlay is compiled into the desktop and Android builds, so the desktop baselines that
draw these scenes move. CI renders from the pushed tip, so that re-render waits on push authorization -
and the comparator, not this machine, counts how many of the 210 change.

### The MCP end-to-end red is a held-host dependency, recorded not fixed (2026-11-14, ruling E3)

The full gate on `ef6ceac9a` (run `43591293792`) finished with one red step: `Test changed scopes`, inside
the MCP package's end-to-end suite — 12 of 13 tests, all of them the group-link scenarios. The evidence
run for that ruling printed the core's own answer for the first time, and it is not a code fault:

```
Chat command error (see chatError property): {"type":"errorAgent","agentError":{"type":"BROKER","brokerAddress":"smp://…=@smp12.simplex.im,…","brokerErr":{"type":"TIMEOUT"}},"agentConnId":""}
```

The suite starts its own local SMP/XFTP pair and registers it with `/smp`, which *adds* to the user's
server list instead of replacing it, so the 21 upstream preset relay addresses remain in the pool that
`apiCreateGroupLink` draws from (`Commands.hs:3387`); across the twelve failures seven different relays
appear. Ruled to record this rather than to chase it, because three measurements bound it: the dialed
host+key pairs are byte-for-byte upstream's (`Presets.hs`, SMP and XFTP alike) so no identifier sweep
moved one half of a wire value; the test files are upstream's except the evidence wrapper and the harness
server source; and the step has never succeeded here at all — 100 runs: 36 skipped, 4 failed, 0 succeeded.
It is also not on the release path: `Test changed scopes` is skipped for a tag push, so `v7.1.2-popopx.1`
publishes exactly what this gate verified regardless of it.

What is left open, and stated in `FORK.md` rather than hidden: upstream ran the same step green in the same
hour on an mcp-scoped commit (their run `43591265929`), so the residual is ours, and the leading hypothesis
is that a client from our SMP protocol era stalls against the older software those public relays answer.
Proving it is a one-line A/B of the harness server binary. The fix that would actually close it is not in
this tree — it is this fork operating relays and authoring its own pairs, at which point the presets move
with them and the suite stops reaching outside itself.

### The last three app-visible blog links: two repointed to upstream, one documented (2026-11-14, rulings A5-1 + A6-3 + 77-C)

The blog pass left four occurrences in code and resources and ruled two of them the same day. These are the
remaining two, plus the record of a fourth thing that is not a name at all.

**A5 `contentModerationPostLink` moved to upstream's URL — the two declarations only.** One URL, 11
occurrences in 6 files: the declarations `apps/ios/POPOPXChat/ChatTypes.swift:26` and
`.../common/views/chat/item/CIFileView.kt:305`, 2 imports (`PopopxAPI.kt:33`, `ChatModel.kt:16`), 7 reads
(`ChatTypes.swift:5448`, `POPOPXAPI.swift:1133,3317`, `CIFileView.swift:307`, `CIFileView.kt:313`,
`PopopxAPI.kt:9130`, `ChatModel.kt:4965`). The host changed in the declarations and nothing else: the
"how it works" row, the alert actions and the `how_it_works` strings in every locale are as they were, so no
capability is lost and no snapshot scene is affected — the URL never renders. Both sides gained one line of
comment naming the reason, because the rest of the fork deliberately moved its display host the other way
and a future sweep would "fix" this back into a 404.

**A6 `fastlane/metadata/android/en-US/full_description.txt:2` keeps its citation and stops claiming the
audit.** New text: the November 2022 Trail of Bits assessment *covers the upstream project this app is forked
from; it is not an audit of this fork*, linking the live upstream article. Deleting the sentence was the other
option on the table and is the one the file's own history would prefer less: a store listing that drops a real
audit of the code it ships is a loss for the reader, and a store listing that implies the audit covers POPOPX
is not true. `en-US` is the only locale directory under `fastlane/metadata/android/`, and no test mirror
reads this file.

**A8 — ruled the same day as 品牌更新 and executed as `e338bbcdd`, the rest of that file's brand wording.**
It had opened `<h1>SimpleX - the first messaging platform…` and kept calling the app, its platform and its
relays "SimpleX" in lines 1, 15-18 and 22: store copy wearing another operator's brand while describing this
application. 9 occurrences became 2 — the 5 app-name uses are POPOPX, the 3 phrases that named the relays
"SimpleX platform servers" / "SimpleX relay servers" / "any other SimpleX servers" now describe the servers or
name the protocol, because the preset relays are still upstream's (see the service-destinations rulings), and
what remains is exactly two instances of the protocol's own name, "SimpleX Messaging Protocol", which stays
upstream's. `title.txt` and `short_description.txt` already said POPOPX Chat, and all nine image files under
`fastlane/metadata/android/en-US/images/` were already redrawn by `9c8df8f09`, so nothing else in the store
metadata carries upstream's brand. One claim was left alone on purpose: "the first messaging platform that has
no user identifiers" is inherited marketing, and dropping it is a copy decision rather than a brand one.

**77-C: the SDKs' native-backend 404 is recorded, not renamed, and closes with #56.** Re-measured today:
`popopx-chat/popopx-chat-libs` has **0 releases**, and every one of the 17 digests the two pin dictionaries
record is upstream's asset digest for the correspondingly-named asset — `release.ts` = upstream tags
`core-7.1.0.20` + `nodejs-addon-cce06d8`, `_version.py` = `core-7.1.0.14`. So `3591a7eba` ("both ends") moved
the client and the generator of the asset name and could not move the third end, the host that holds the
bytes. Pointing the fetchers back at upstream's release was rejected: it would either strand the desktop
pipeline, which builds a `popopx-chat-libs-<platform>` artifact of its own, or give one zip two spellings by
pipeline. `check-pins` would catch it (`core-7.1.0.20 is not published`) but has never run on this fork —
`packages.yml` is pull-request-only — and needs Python ≥ 3.11, which is not this machine's 3.9.6.

Gates after the edit: `popopx.chat/blog` in code and resources **4 → 1** (only the ruled-keep metainfo
`<image>`), the two slugs now resolve to the upstream host that serves them, `simplex.chat/blog` occurrences
+3 by design. No Kotlin/Swift identifier changed, so nothing recompiled differently and no baseline is
expected to move; the URL is not a wire value — no reader outside these 6 files exists (`rg` for both slugs
finds only them plus `README.md:20`, which already said `simplex.chat`).

### #33 item 1 executed (option 1c): the served association record now names our own certificate (2026-11-14)

Ruled 2026-11-14 — **1c, our own keystore**, out of the three ways to close the item left open above. The other two
were rejections for the same reason: an empty `sha256_cert_fingerprints` array and a deleted file both *remove a
capability* (the record stops attesting anything) where the defect was a mismatched value, and a value we control
now exists.

- **The key pair is new and it is ours.** Material lives outside both repositories, in
  `/Users/elliot/popopx-chat/keys/` (directory 0700, files 0600): an encrypted PKCS#1 PEM key, its certificate and
  the passphrase file. Nothing secret is tracked in either repo and the passphrase was never printed. Subject
  `/CN=com.popopxchat.popopx/OU=POPOPX Chat Android Release/C=US`, RSA 2048, `sha256WithRSAEncryption`, serial
  `8E22C76424902B78`, no X509v3 extensions, valid 2026-11-14 → 2054-04-01. Its SHA-256 fingerprint — the value
  Android compares against the installed APK — is
  `3A:7F:67:1A:8F:21:D3:93:6D:46:78:DE:1D:4F:0E:29:C3:DF:9E:35:2A:CB:26:0D:02:6A:DD:0C:17:FA:4C:CB`.
- **One line changed, in the dependency**: `apps/common/Web/static/.well-known/assetlinks.json` went from SimpleX
  Chat Ltd's three fingerprints (Play App Signing, the GitHub APK upload key, F-Droid) to this one. `package_name`
  was already `com.popopxchat.popopx`; pairing it with three certificates that never sign our build is the
  misattribution, and it cannot be fixed by renaming anything.
- **Pin chain.** popopxmq `25d7213d` = tag `popopx-pin-4` was the pin as of this section, and this repository's two holders of the pin moved with
  it (`cabal.project:24`, `scripts/nix/sha256map.nix:2`). The nix hash came from the command that file's own generator
  calls (`nix-prefetch-git --fetch-submodules`, per `scripts/nix/update-sha256.awk`), and the route was proven first by reproducing pin-3's recorded hash
  byte-for-byte — an unproven hash command against a dependency that has to resolve on someone else's machine is
  how a pin silently becomes unbuildable. `diff -rq` between the two fetched trees is **exactly one file**, this
  one, so no Haskell source moved — a clause scoped to that one step, because the same generator pass carried both
  holders to `13df615df7892532b4e83f92d529b96c3d788dea` = tag `popopx-pin-7` on 2026-11-17, across which
  `git -C ../popopxmq diff --stat 25d7213d..13df615d` counts **81 files**, 16 of them under `src`. The hash recorded
  for pin-7 is `04ihl1j1qm4s9sik4c65gh2w78x6k2y8nv8a5jir11i6fm9gir9z`, again the generator's own output rather than a
  typed value, and regenerating all thirteen entries diffed **exactly one line** against the committed file, which is
  what re-proves the twelve entries this section does not touch.
- **Scope, proven two ways.** `Web.Embedded` (the TH module that inlines `static/.well-known/`) is listed only in
  `executable smp-server`, `executable xftp-server` and `test-suite popopxmq-test` in `popopxmq.cabal` (`:479`,
  `:518`, `:582`) and never in the library (`:98`), and the tree diff above shows nothing else changed — so the
  iOS archives stay current and none needed rebuilding. No test anywhere asserts the embedded content: the only
  readers are `Embedded.hs:14` (embed) and `Web.hs:151` (serve).
- **What this does not yet accomplish.** This fork still publishes no APK and `apps/android/build.gradle.kts` has
  no `signingConfig` at all (measured the same day), so nothing consumes this certificate yet; when it does, the
  conversion keeps the same fingerprint because it is a property of the certificate, not of the container. Play App
  Signing and F-Droid each sign with their own certificate and their digests join this array when those channels
  exist (#56). And the record is still not *reachable*: `popopx.chat` answers 404 for both `.well-known` paths and
  no relay serves HTTPS, so verification stays inert — inert now in the direction where nothing is attributed to
  the wrong owner.
- **Two holders of upstream's `3C:52:C4:FD:…:AD:85` are deliberately kept**: `scripts/ci/android/release-apk.sh:10`
  and `scripts/popopx-chat-reproduce-builds-android.sh:4` verify *upstream's* signed APK, so for them that digest
  is simply the right value.
- **Left open by this pass, awaiting a ruling**: `apps/multiplatform/README.md:114`, `:125`, `:134` still tell a
  contributor to add their signature to `github.com/simplex-chat/website`'s `assetlinks.json` "and make a PR… then
  you should be able to verify SimpleX", and `:125`'s prose says the hosted file is "on simplex.chat" while both of
  its links point at `popopx.chat`.

Verified: `assetlinks.json` re-parsed from disk (1 entry, `package_name` unchanged, 1 fingerprint of 32 hex groups
/ 31 colons, 0 hits for any of the three upstream digests), `nix-instantiate --parse` on `sha256map.nix`, the pin
SHA in both holders and the superseded one absent from both, fingerprint derived twice independently (and the tempting
third route is a trap worth recording — LibreSSL 3.3.6 `openssl x509 -outform der` writes **0 bytes** and exits 0,
whose digest is the empty-input constant `e3b0c442…`). Gates: `ding_wire_audit` FORWARD 0 / REVERSE 0 / BARE 16
(unchanged), `deps` MIXED 0 / STALE 0, `pairs` all zeros. **The dependency commit and tag are local**: this pin
resolves from GitHub only after they are pushed, so our commit must not be pushed ahead of theirs.

### #33 executed as items 2 and 3: our relay hosts are claimed, the stale association record is corrected (2026-11-14)

Ruled 2026-11-14 — the Team ID in the link-association work is **ours**, `PDBA6XRBQT`. That settled the question
#33 was blocked on and turned out to need **no identifier change**: everything that already names a signer names
us correctly. What it exposed instead were two defects and one open decision.

- **Item 2 — executed.** `applinks:*.popopx.im` and its `?mode=developer` twin added to
  `apps/ios/POPOPX (iOS).entitlements` (`tools/r7/r33_2_applinks.py`, 2 insertions, 5 → 7 `applinks` rows,
  `plutil -lint` OK), declared as the pair `*.simplex.im` already has. `*.simplex.im` is **held** by the ruling
  「保留」; Android is untouched, because an intent filter takes no wildcard host and no `*.popopx.im` relay
  serves HTTPS yet. So the app can now be adopted by our own relay hosts the moment they serve the file, and
  cannot be adopted by anything it does not operate.
- **Item 3 — executed.** Four stale measurements in `FORK.md` rewritten against a fresh reading the same day:
  the "certificate is single-name `CN=popopxchat.com`, no `popopx.chat`" claim (two Let's Encrypt YR1 leaves are
  installed, `CN=popopx.chat` with SAN `popopx.chat`+`www.popopx.chat` at `notBefore` 2026-11-13 04:04:23Z, and
  `CN=popopxchat.com` with its own pair at 04:06:37Z — the ruled plan asked for one certificate carrying three
  names, the deployment covers the same names as two, which is equivalent for the verifier); the same claim's
  shorter form earlier in the file ("Two things are still missing", now one); the "this repository stores it as
  `apple-app-site-association/index.json`" line, which described a copy that left with `website/` — the shipped
  copy is the dependency's, already extensionless and already typed `application/json` in two places of
  `Web.hs`; and "the Team ID appears in three places across two files", which measured 9 occurrences in 6 files
  here plus 3 files in `popopxmq`. The "link claims are inert, for three independent reasons" count was also
  wrong — the list had grown to six bullets while the certificate reason retired, so it no longer states a
  number.
- **Item 1 — not executed, awaiting the choice.** The dependency's
  `apps/common/Web/static/.well-known/assetlinks.json` pairs our `package_name` with SimpleX Chat Ltd's three
  fingerprints. Three ways to close it were laid out (empty the array / drop the file from the embed / mint our
  own keystore); the value is not derivable here — no keystore is tracked in either repository — and it is a
  security boundary rather than a name, so it stays a ruling rather than a sweep. It is latent, not live: no
  relay serves HTTPS, so nothing is currently mis-answering.

Measured 2026-11-14 for the record: `https://popopx.chat/`, `https://www.popopx.chat/` and
`https://popopxchat.com/` all `200`, while `/.well-known/apple-app-site-association` and
`/.well-known/assetlinks.json` on `popopx.chat` and the `www` copy of the latter are `404`, and
`https://smp1.popopx.im/.well-known/assetlinks.json` does not connect. iOS push needed no change and is worth
recording as clean: `APNS.hs:215` `appTeamId` and `appName`/`TOPIC` already name us, and the key is read from
`APNS_KEY_FILE`/`APNS_KEY_ID`.

Verified: no source file changed — an entitlements array and two documents — so there is nothing to compile, no
archive to rebuild and no snapshot to re-render (neither harness reads the entitlements). `ding_wire_audit audit`
FORWARD 0 / REVERSE 0 / BARE 16, unchanged.

### The 4 desktop baselines the crowdfunding deletion left behind (CI run 43553929937, 2026-11-14)

The dispatch was asked for a different reason: this machine has no JVM, so `desktop-linux.yml` was run on
`2c98dcda1` to get a real Kotlin compile of the blog pass. That compile is green — `Run desktop tests`
**255 tests, 0 failed**, and `Run smoke test` reached the chat list — which proves `WhatsNewView.kt` still builds
with the `post = "…"` arguments deleted, and explains why nothing had to be left behind: Kotlin's row link is an
optional parameter reached only behind `if (link != null)` (`WhatsNewView.kt:91-92`), the same shape Swift has.

The job's one red step was **Compare snapshots**: **210 rendered, 206 `equal`, 4 `changed`** —
`SettingsView.PreviewSettingsLayout-{dark,light}-font-100.png` (1046 and 1051 changed pixels, `maxDelta` 120/121)
and `WhatsNewView.PreviewWhatsNewView-{dark,light}-font-100.png` (64114 and 61052, `maxDelta` 255).

**None of the four belongs to the blog pass.** The comparator's diff image is three panels — reference, render, and
the changed pixels in red — so reading it says which side moved: in both pairs the *reference* panel still draws
copy this repository deleted ("Own a part of POPOPX Chat! 🚀" with the badge artwork, and "Crowdfunding on
Wefunder. Learn more", in the What's-new scene; the "Upstream's crowdfunding" row in the settings scene) while the
*render* panel draws the current page. The two magnitudes are the two shapes of the same fact: the What's-new card
was the *first* slide of that pager, so deleting it shifts every later row and 64114 pixels disagree, while the
settings row sat at the bottom of the list and only its own line and the divider above it differ. The render is
correct and the committed baseline is the stale half, and the
history agrees: the last commit to touch `common/src/desktopTest/snapshots` is `91535ad21` (2026-11-13), which
predates `d09968bd9`, and nothing touched it afterwards — whereas the iOS tree moved twice after that ruling
(`54cd6cc69`, then `2c98dcda1`). The crowdfunding install therefore landed on one of this fork's two independent
baseline trees and not the other; only CI renders this one.

Installed: exactly those 4 files, taken from the run's `desktop-snapshots` artifact and selected by its own
`compare.json` `failed` list rather than by a second pixel diff. Byte sizes `39549 -> 37050`, `37950 -> 35348`,
`75666 -> 42031`, `72876 -> 39231`; all four stay `402x874` (`sips` on both sides, so no canvas moved); re-measuring
every one of the 210 committed PNGs against the artifact afterwards returns **0 differing**, which is the receipt
that the 206 `equal` ones were not touched. The artifact's own 210-entry name set is identical to the committed one
in both directions.

Confirmed by a second dispatch rather than by the local comparison alone: run **43559086343**, on `master` at the
install commit, ended `success` with every step of the Xvfb job green and the comparator logging
**`210 snapshots, 0 differ from the references in apps/multiplatform/common/src/desktopTest/snapshots`**. The
artifact it uploaded holds 212 files — the 210 renders plus `compare.json` and `index-desktop.json` — and no
`snapshots-diff` image, which is the same fact from the other side.

### The What's-new and release-notes links went with the blog (2026-11-14, 删除博客链接)

42 files, 17 insertions / 138 deletions (`tools/r7/r70_bloglinks.py`, five locales completed by
`r70b_a2_tail.py`, 143 records in `tools/r7/r70_bloglinks.jsonl`). Measured that morning: all 27 distinct
`popopx.chat/blog/…` URLs the apps carry answer **404** (27/27, no timeouts), and the directory staged for
the site contains **no `blog/` at all** — so this is not fixed by publishing the site, and the links are
deleted rather than repointed.

- **A1 — the per-version "read the post" button: 47 URL-bearing lines.** 22 `post: URL(string: "…/blog/…"),`
  arguments in `WhatsNewView.swift`, 22 `post = "…"` in `WhatsNewView.kt`, plus 3 Kotlin feature-row
  `link = "…"`. Both `VersionDescription.post` fields were already optional with an existing nil call site,
  and both renderers branch on them (`if let post = v.post` / `ReadMoreButton(v.post)`), so the rows lose
  their button and nothing else.
- **A2 — the link was inside the copy, so the key had to move too: 17 lines.** iOS uses the English string
  *as* the localization key, and the transport-isolation row carried
  `[by connection](…/blog/…#transport-isolation)` — so the URL lived in **the key and the value of 16
  `.lproj` catalogues**, 32 of the 33 occurrences. Stripping only the code literal would have compiled,
  rendered and silently fallen back to English in 16 languages. The pass rewrote key and value together into
  the link-free wording Android already had, and asserts all 16 keys equal the code literal byte for byte.
- **A3 — the badges "read more in our blog" row: 35 lines.** One Swift `ExternalLink`, one Kotlin
  `ReadableTextWithLink`, **the import that call was the only user of in that file**, the key in 21 moko
  locales and the same string in 11 iOS catalogues. The helper itself stays; two other views call it.
- **A4 — 39 of the 43 flatpak release URLs**: `<release><url type="details">` in
  `com.popopxchat.popopx.metainfo.xml`. The four that survive are not blog links — two `popopx.chat/badges/`
  and two upstream GitHub release tags.

Held, each with its reason: the metainfo `<screenshots><image>` (a dead `/blog/images/…png`, but an image is
not a link and dropping the only screenshot is a separate ruling), `contentModerationPostLink` in
`ChatTypes.swift` / `CIFileView.kt` (a paired value with 8 readers), `fastlane`'s store description, and
every `simplex.chat/blog` — upstream's host serving upstream's articles — including the 232 `.xcloc`
catalogues, which `project.pbxproj` references zero times and so are not a build input.

**The tool silently skipped five files, and only the residue count caught it.** `Doc.write()` gated the save
on `if not self.cut_idx: return`, so a file that was *rewritten* but never *cut* was computed, JSONL-logged
and reported as edited without ever reaching disk — exactly the five locales A2 rewrote and A3 touched no key
in (bg, cs, fi, ja, th). Left that way they would have shipped a key no code asks for and no value for the key
the code now asks for. The per-file count assertions could not see it: they validate the computation, not the
filesystem. Re-measuring occurrences **on disk** (15 where 5 were expected) is what exposed it.

Gates: `popopx.chat/blog` occurrences 126 → **5**, exactly the holds above (4 in code and resources plus the one
already in this file; the prose written by this decision has added mentions of its own since);
`plutil -lint` 16/16 catalogues
OK; `xmllint` 22/22 XML documents OK; `scripts/ios/localizations.py check` → "No problems found";
`check-kotlin` unchanged and naming none of the deleted keys; `()`/`{}`/`[]` balance shift +0 in all four code
files; wire audit FORWARD 0 / REVERSE 0 and `sweep WORKTREE` 0; `xcodebuild` build and `build-for-testing`
both **SUCCEEDED**. The Kotlin side is **static verification only**: this machine has no JDK, no Gradle
distribution and no Android SDK, and the CI "Build and test Kotlin apps" step in run 43547895589 was
*skipped*, not passed, so the first real Kotlin compile of these files is the next pushed run.

Snapshot re-render (`SNAPSHOT_SIZE=large`, 262 scenes): **260 equal / 2 differ**, and the two are exactly
`BadgesHowItWorksView-{light,dark}-large` at 1099 changed pixels each — regenerated and installed, reconciling
the suite at 262/262. (The comparator's other 112 `missing` are the baselines of the four font sizes this
single-size render cannot produce; CI renders those per job.) `NewFeaturesView-{light,dark}-large` came back
**byte-identical, and that is a coverage gap rather than a clean bill of health**: HEAD carries 23 What's-new
pages — 22 with a `post:` and the newest (`v7.1`) already with `post: nil` — and the scene's paged `TabView`
renders only the selected newest page, so all 22 deleted "Read more" buttons sit on pages the harness cannot
reach. Nothing in this repository visually verifies A1; it is verified by the Swift compiler and by the fact
that both renderers branch on the optional.

**The two questions that pass left open were answered the same day.** The metainfo
`<screenshots><image>` is ruled **keep** (「它是图片不是链接，不删掉」): it names an image, not a link, and
removing it would leave AppStream without its only screenshot — the dead `/blog/images/…png` reference stays as
an inert asset. `popopx.chat/docs` is ruled **hold** (「先不动，保留」): 31 holders in 18 files, measured
2026-11-14 to answer 404 on all 13 distinct paths, left exactly as they are because that tier is a separate
decision from the blog and 8 of the 31 are fixtures in `scripts/ios/test_localizations.py`. Both rulings are
recorded in `FORK.md`. `contentModerationPostLink` (A5) and the fastlane store description (A6) were named in
the same message but received no decision, so both are untouched and still awaiting one.

### The five holders that outlived the ruling (2026-11-14, 功能保留)

8 files, 19 insertions / 23 deletions (`tools/r7/r68_i_pending.py`, JSONL in `tools/r7/`). The rule for this group was
**keep the capability** — repair the pair that was broken, delete the promotion, never the function. The badge-web
suite is **green: 525 pass / 0 fail** — the first time this fork has measured it without a red (524/3 before the
crowdfunding tier, 523/2 after commit 3).

- **The brand pin had never run.** `test/design.test.ts:447-450` resolved `../../../../branding/source-svg/…`, which is
  the depth of the **source** tree; `npm test` executes the compiled `build/test/design.test.js`, one level deeper, so
  the four marks resolved to `apps/branding/…` and ENOENTed. One `../` each — and the assertion then **passed**, which
  is the evidence that `public/img/{wordmark,symbol}-{light,dark}.svg` really are byte-for-byte the masters. A test that
  cannot find its input is not a failing test, it is an absent one: this is the guard that was supposed to stop anyone
  redrawing the mark "close enough", and it had been silent since the file was written.
- **`embed.ts` was the other half of a tier-戊 pair.** `test/embed.test.ts` had moved to `popopx.chat` and the allowlist
  had not. `trustedHost` has exactly one live reader — `main.ts:138`, the `postMessage` origin gate for theme, route and
  return-url — so the asymmetry meant our own site could not drive our own badge page while upstream's could. Now
  `popopx.chat` and `*.popopx.chat` are admitted **and** `simplex.chat`/`*.simplex.chat` are kept: nothing that used to
  work stops working (功能保留 in the direction that matters for a security boundary is *additive*). The dotted-suffix
  rule is applied to both hosts and one negative, `https://notpopopx.chat`, proves it; `https://popopx.chat.attacker.com`
  was already asserted. The test's title states the new rule — it names no CI selector (`npm test` runs
  `build/test/**/*.test.js` wholesale, unlike the hspec group names that are).
- **Consequence of touching `src/`**: the build hash is derived from the compiled module bytes, so `npm run build`
  regenerated it — `ee8dc5d62acfb879` → `4782e3e6d8b0fafb` in `public/index.html` (5 lines) and `public/sw.js` (1). The
  prerendered shell did **not** move this time, which is the cross-check that nothing user-visible in the rendered DOM
  changed. `test/build.test.ts` fails until the regenerated files are committed, so they are part of this commit.
- `scripts/ci/android/claude-test.md:11` told the CI test agent to leave the "Invest in SimpleX Chat!" card open; commit
  1 deleted that card, so the instruction named a screen the app cannot show. The two real cards keep their wording.
- `packages/popopx-chat-mcp/README.md`: the **whole "Own a part of SimpleX" section** (6 lines) went — a funding CTA with
  `utm_source=mcp` inside our own package's documentation, the same class as the badge-service README CTA commit 2
  deleted. Nothing else in the README moved, and no `#own-a-part-of-simplex` reference existed to break. `wefunder` is
  now **0** occurrences across `apps/`, `packages/` and `scripts/`.
- `apps/popopx-support-bot/src/messages.ts`: the welcome message kept its identity line and its directory link and lost
  the *Join the livestream about SimpleX roadmap and equity crowdfunding* line — a dated broadcast whose target was
  measured **404** on both egress paths. The template literal's closing backtick sat at the end of that line, so it moved
  onto the directory line. Verified with this repo's own compiler (`typescript` 6.0.3 from the badge web,
  `tsc --ignoreConfig --noEmit` on `src/messages.ts` + `src/util.ts`): **0** errors in the edited file (the 5 reported
  errors are `util.ts`'s missing modules — this package has no `node_modules` here); the bot's only assertion on
  `welcomeMessage` is that it is non-empty (`bot.test.ts:1940-1942`, and vitest cannot run without an install).

**Held**: `apps/popopx-support-bot/plans/20260207-support-bot-implementation.md:882` carries the same welcome text — a
plan document is a record, the same treatment as `CHANGELOG.md` and the flatpak `<release>` notes.

**Newly noticed, NOT touched, and not a crowdfunding item**: the bot's first line still reads `a **SimpleX team** support
bot`, and `packages/popopx-chat-mcp/README.md:1` titles the package `# SimpleX MCP server`. Both belong to the
first-person-attribution class (#66), not to this ruling.

### The specs stop describing the round (2026-11-14, ruling 删除众筹 — commit 4 of 4)

10 files, 23 insertions / 62 deletions (`tools/r7/r68_h_docs.py`, JSONL in `tools/r7/`; 43 edits, 10 files, each an
asserted line span or an asserted single-substring replacement). The last group of mirrors: documents that describe the
app, which after three commits described a screen the app no longer has.

**Section 10 of each `spec/client/chat-list.md` could not be deleted whole.** Under the funnel's heading sat the
chat-list *banner slot*: the priority chain, the dismissal preferences and the shared card chrome — all of which survive
with the badge alert banner and the supporter pitch. So both sections were retitled **Chat List Banners** (anchor
re-derived: `{#10-chat-list-banners}` in the iOS file, which spells its own anchors, and the GitHub slug in the Kotlin
file, whose TOC link is derived from the heading text) and then trimmed:

- The chain paragraph moved as one unit on both platforms, 4 edits each: `the badge alert banner, the pitch, then the
  Wefunder banner` → `…, then the supporter pitch`; the recorded enum lists lost their third member (`.badgeAlert`,
  `.badgePitch` / `BadgeAlert`, `BadgePitch` — verified against `ChatModel.kt:133` `enum class ChatListBanner {
  BadgeAlert, BadgePitch }` and `ChatModel.swift:386-388`); `the pitch and Wefunder conditions start with` → `the
  pitch's condition starts with`; and the `ConnectOnboardingView` sentence deleted, because `OnboardingCards.kt` now
  holds **0** references to `bannerSlotFree`/`chatListBanner` — the onboarding placement is gone, not renamed.
- **Placement**: the Kotlin chat-list row survived and was re-verified rather than left as prose (`ChatListView.kt`
  wraps both surviving items in `Box(Modifier.zIndex(1f).padding(16.dp))`, at `:1109` and `:1136`, after
  `ToggleChatListCard`). The iOS `### Placement` table went whole — both of its rows were the funnel's (last branch of
  the chain; the slot below `ConnectOnboardingView`, which the current `chatList` does not have: its onboarding branch
  is now just the pages in one `VStack`).
- **Dismissal**: the two funnel preference rows out, the two pitch rows kept, and the sentences re-pointed — "Both are
  in `hintDefaults`" still holds for the survivors (`SettingsView.swift:132-133` declares them, `:166-167` resets them),
  while "The X is never offered in the onboarding branch…" went with the placement it described.
- **Index rows were retargeted, not dropped.** `CODE.md`, `spec/impact.md`, `product/concepts.md`,
  `product/views/chat-list.md` and both Source Files tables named the deleted file; each now names
  `SupportPOPOPXBanner.*`, the file that holds the chrome after commit 1's repair *and* the pitch the retitled section
  documents. Dropping them would have left a spec that cites a file no index can find. Declaration lines were measured,
  not guessed: Swift `struct SupportPOPOPXBanner` `:12`, `struct BannerCard` `:95` — the chrome sentence cited `#L94`,
  one line out, and was corrected.
- `product/views/chat-list.md`: the funnel's bullet and its file-map line (retargeted), and "…pages replace the list,
  **with the crowdfunding banner below them where it applies**" → "…pages replace the list".

One unrelated stale mirror, fixed because it sat in the table being trimmed: `apps/multiplatform/spec/client/chat-list.md`
quoted the pitch's alert as *"You can support **SimpleX** later in Settings."* while `badges_banner_dismiss_message` has
emitted *"You can support POPOPX later in Settings."* since the display-strings tier (`strings.xml:3211`; the iOS row of
the same table already read POPOPX). That is an earlier pass's half-moved pair, not collateral of this ruling.

Gates: every relative link in the 10 edited files resolves — 0 broken: the dead links into
`GetStakeBanner.{swift,kt}` that an earlier pass counted are gone with the text. `git grep -w` for
`GetStakeBanner|GetStakeView|getStake|GetStake|crowdfundingAvailable|Wefunder` outside `CHANGELOG.md` and
`FORK.md` → **1** hit, `packages/popopx-chat-mcp/README.md:74`, which is still awaiting its own ruling. `crowdfund` is
now absent from every file under `apps/ios` and `apps/multiplatform` except the two What's-new `post` URLs.

### The Kotlin banner chrome that went with the deleted file (2026-11-14, repair of commit 1 of 4)

1 file, 67 insertions / 2 deletions. Commit 1 deleted `apps/multiplatform/…/views/chatlist/GetStakeBanner.kt` whole, and
that file had been declaring more than the funnel: the shared chat-list banner chrome — `fun Modifier.bannerCard`,
`fun BannerDismissButton`, `private fun gradientBrush` — which `views/badges/SupportPOPOPXBanner.kt` imported and called
at its own `:51` and `:80`. So `commonMain` could not compile, and **no gate available on this machine could have said
so**: `xcodebuild` was green because iOS never had the asymmetry (its `SupportPOPOPXBanner.swift` had always declared the
same chrome, with the comment *"one declaration so the cards cannot drift apart"*), the badge-web suite has no Kotlin,
and Android remains static verification only (no SDK, no gradle here). The pass's brace-delta gate is also blind to it:
every span it cut was self-contained, the missing symbol is a cross-file fact.

What found it was the commit-4 survey: `apps/multiplatform/spec/client/chat-list.md:363` says the chrome is *"declared
separately from `GetStakeBanner` so other banners can adopt the same chrome"*, which read against the deletion means
*separate top-level symbols in the file being deleted* — so the symbols were grepped for, and there were none.

Fix = the move, not a re-add: the three declarations were recovered verbatim from `git show d09968bd9^:…GetStakeBanner.kt`
and appended to the file that now owns them, with the iOS comment so the two platforms read alike; the import block lost
the 2 `views.chatlist` imports and gained the 11 the chrome needs (`CircleShape`, `RoundedCornerShape`, `clip`, `Offset`,
`Brush`, `onSizeChanged`, `IntSize`, `stringResource`, `darkStops`, `gradientPoints`, `lightStops`).

Verified statically, which is all Android work in this fork can be verified: brace/paren/bracket deltas 0; `git grep -w`
finds exactly one declaration of each symbol and **zero** remaining `views.chatlist` references from the badges package;
`darkStops`/`lightStops`/`gradientPoints` are `internal` in `views/newchat/OnboardingCards.kt`, same Gradle module, so
the `internal` visibility is not a break, and `GradientEndpoints` really does carry `startX`/`startY`/`endX`/`endY`. A
sweep of the 12 identifiers these four commits deleted (`GetStakeView`, `GetStakeBanner`, `InvestPerk`, `investPerk`,
`withInvest`, `investPanel`, `INVEST_LABEL`, `CROWDFUNDING_ACTIVE`, `crowdfund*`, `wefund*`) across every `.kt` and
`.swift` returns only the 2 What's-new `post` URLs whose blog slugs contain "crowdfunding" — record, held with the
`investor` badge type.

### The badge service stops offering the round (2026-11-14, ruling 删除众筹 — commit 3 of 4)

8 files, 29 insertions / 221 deletions (`tools/r7/r68_g_badgeweb.py`, JSONL in `tools/r7/`). This is the checkout's own
promotion: the sentence under a Pay button that says *or invest instead*, which is the one place the funnel sat inside
the app we would actually deploy. `src/crowdfunding.ts` went whole — `CROWDFUNDING_ACTIVE`, `WEFUNDER_URL`, the
`INVESTOR_PERKS` table (supporter 100/250/1000, legend 1000/2500/10000), `perkAmount`, `minimumFor`, `dollars` — and
with it every reader:

- `screens.ts`: `INVEST_LABEL`, `InvestPerk`, `investLink`, `investSentence`, `investPanel`, `withInvest` (39 lines),
  the `perk?: InvestPerk` field of 5 option interfaces and the 8 call sites that wrapped a screen
  (`return withInvest(panel(…), investPanel(…))` → `return panel(…)`). The copy it stopped rendering named the company:
  `Invest $100+ in SimpleX Chat`.
- `main.ts`: `investPerk` + `withPerk` + the 4 `...withPerk({}, investPerk(…))` spreads. The compiler, not the script,
  caught the last orphan: `const chosen = …` fed only `investPerk(price, chosen?.months)`, so `tsc`'s `noUnusedLocals`
  is what proved the cut was complete — a brace-delta gate cannot see an unused local.
- `icons.ts`: `wefunderMark` and its two path strings. `styles.css`: the `.invest` / `.invest-link` / `.wefunder` rules
  (37 lines). `.panel > button:last-child { margin-bottom: 20px }` therefore applies to the primary button again, which
  is the pre-round layout `CROWDFUNDING_ACTIVE = false` was written to return to, so no other rule had to move.
- `public/sw.js`: the `crowdfunding.js` entry, which `test/sw.test.ts` cross-checks against `readdirSync(src)` — a
  module deleted from `src` but left in the precache fails the suite by itself.
- `public/index.html`: **generated**, by `npm run build`. The prerendered shell *is* `landing()`'s output
  (`test/main.test.ts` compares them byte for byte) and the content-derived build hash covers the compiled modules, so
  the build renamed it `c1e049e40dfe7be6` → `ee8dc5d62acfb879` in `index.html` and `sw.js` together. The diff is the
  5 hash-bearing lines plus the one shell line losing `<div class="invest">…</svg></a></div>` — nothing else moved,
  which is what says the committed shell had not drifted for other reasons.
- `test/screens.test.ts`: 2 `domTest`s deleted whole (the order summary's invest block, the codes list's), 12
  assertions, 3 `perk:` arguments and 2 copy lines, and 2 assertions rewritten to assert the absence instead
  (`primary` is now the last child of the landing panel; `div.invest` count 0 on the invoice failure). 527 tests → 525.

**Kept**: `hasBadgeArt("investor")` and `badges-rpc.md:88`'s `investor` wire tag (same reason as commit 2), and the
"Settings → Supporter perks → Redeem code" strings — that is code redemption, a different feature that merely shares
the word.

Gates: `npm ci && npm test` → **523 pass / 2 fail** (525); the baseline before this pass was 524 / 3, so nothing here
broke and one red went with the rebuild. `git grep WEFUNDER|wefunder|crowdfunding\.js|CROWDFUNDING_ACTIVE|investPanel|InvestPerk|perkAmount`
→ 0 hits outside `CHANGELOG.md`, `FORK.md` (record) and `packages/popopx-chat-mcp/README.md:74` (awaiting its
own ruling); inside the app only the two kept hits above. `ding_wire_audit.py audit` FORWARD 0 / REVERSE 0.

**The 2 reds are pre-existing and unrelated to this tier** — both are earlier passes' one-sided pairs, reported here so
they are not mistaken for collateral of this commit:
`design: the brand artwork is the official file, byte for byte` — `test/design.test.ts:447-450` resolves
`../../../../branding/source-svg/…` relative to the **compiled** `build/test/`, one level shallower than `test/`, so it
asks for `apps/branding/source-svg/…` and ENOENTs on a file that exists at the root. Needs one more `../`.
`embed: only https simplex.chat and its subdomains may drive the theme` — `test/embed.test.ts:6` expects
`trustedHost("https://popopx.chat") === true` while `src/embed.ts:53` still admits only `simplex.chat` and
`.simplex.chat`. Unlike a display host this allowlist is a security boundary (which embedding origin may drive the
theme and the route), so it is a ruling, not a sweep.

### The badge keeps its `investor` type and loses the round (2026-11-14, ruling 删除众筹 — commit 2 of 4)

66 files, 95 insertions / 489 deletions (`tools/r7/r68_def_badge.py`, JSONL + patch in `tools/r7/`). This is the
part of the funnel that lived *inside* the badge UI, so the boundary had to be drawn first: a badge the badge service
issued is a fact about a contact, a funding round is a promotion. Four groups:

- **D — the investor offer, deleted.** `struct BadgeInvestorOffer` (Swift, 13 lines, and the `BadgeLevel.investorOffer`
  computed property with its 2 sentences) and `fun BadgeInvestorOffer` (Kotlin, 20 lines, with `BadgeLevel.investorOffer`)
  were the only carriers; the 4 iOS and 4 Kotlin call sites went with them, so did `WEFUNDER_URL` — commit 1 left it
  precisely because this offer still read it — the `BadgeInvestorOffer(level: .supporter).hidden()` spacer, and the
  README's `[Invest in SimpleX Chat on Wefunder]` CTA together with the sentence that qualified it as upstream's.
  Strings: 3 `badges_investor_offer_*` keys from the 20 moko files that held them (60 line records), 22 `"Invest $100+…"`
  / `"Invest $1000+…"` entries from 11 `.strings` and 26 units from 13 `.xliff`. 3 further `.xliff` units went because
  commit 1's key match missed the trailing-period spellings (`Crowdfunding on Wefunder.`, `Learn more on Wefunder.`) —
  the same near-miss class as an escaped-slash URL in a `sed` address.
- **E — `badge_invested` rewritten, not deleted.** The alert shown when you tap someone's investor badge asserted an
  investment; it now asserts the badge, the only thing the client can actually verify: `%s has the POPOPX investor
  badge.` in 23 moko files, the same at `NameBadge.swift:152`, and in 12 `.strings` (the key **is** the English text, so
  the key moved with the value) plus 16 `.xliff` (`id` + `<source>` + `<target>`). Translations were composed per locale
  from that locale's own word for *badge* and *investor* — de `Investor-Badge`, pl `odznaka inwestora`, zh-rCN
  `投资人徽章`, fa keeps the ZWNJ inside `سرمایه‌گذار`, ca keeps the Android apostrophe escape `d\'inversor` —
  and the `%s`/`%@` count of every one of the 51 new values was checked against the value it replaced (1 = 1).
- **E2 — the investor alert's destination.** The Kotlin branch offered *Learn more* → `https://popopx.chat/crowdfunding`
  (our host, a page we do not publish). Once the sentence stopped claiming an investment the link had nothing to
  explain, so the branch became confirm-only — the shape iOS already had. The `uriHandler` parameter stayed: deleting it
  would strand an unused local in 2 more files and it is not a compiler warning.
- **F — the name-sale footnote, deleted.** `popopx_name_sales_footer` ("Crowdfunding investors can reserve names before
  the sale starts:") from 21 moko files, 11 `.strings`, 14 `.xliff`, and its two readers. In `SetPopopxDomainView.kt` the
  `simplex.domains` link stays and only the sentence and its separator space went; in `UserAddressView.swift` the whole
  `} footer:` clause collapsed onto the Section's own closing brace (brace delta preserved).

**Kept**, because they describe an issued badge rather than the round: `BadgeType.investor` and its wire tag
(`src/Popopx/Chat/Badges.hs:105,113,118,120-122,165`, `ChatModel.kt:2271 @SerialName("investor")`, the SDK mirrors,
`badges-rpc.md:88`), the display name `badges_type_investor`, and the `badge-investor` imageset.
Gates: `ding_wire_audit.py audit` FORWARD 0 / REVERSE 0 / BARE 16 (baseline unchanged — nothing here is a wire value);
`ET.parse` over all 39 edited `.xml`/`.xliff`; `scripts/ios/localizations.py check` rc 0; the placeholder count of every
rewritten value checked against the value it replaced; zero-check for
`BadgeInvestorOffer|investorOffer|investor_offer|WEFUNDER_URL|popopx_name_sales_footer|crowdfund` clean in
`apps/ios/Shared`, the `.lproj`/`.xcloc` files and `commonMain` except the held blog slugs; `xcodebuild` device **and**
`ARCHS=arm64` simulator BUILD SUCCEEDED, then `** TEST SUCCEEDED **` for the `large` snapshot re-render — 4 of 262
baselines legitimately changed (`BadgesCheckOrderView` and `BadgesHowLongView`, light+dark each, the deleted offer line
was the only difference) and were installed; the re-run reports 0 changed for the `large` set. That the 2
`BadgesSupportPopopxView` baselines did **not** move is the cross-check that `BadgeInvestorOffer(…).hidden()` really
drew nothing. Android: static verification only — no Android SDK or gradle on this machine. The 22 imports that
`WhatsNewView.kt` no longer needs went in the same commit (the 2 that were already unused before commit 1 are upstream's
state and stayed).

### The crowdfunding funnel is deleted (2026-11-14, ruling 删除众筹 — commit 1 of 4)

Supersedes ["The iOS crowdfunding funnel was restored, with the round named as upstream's"](#the-ios-crowdfunding-funnel-was-restored-with-the-round-named-as-upstreams-2026-11-13)
below: the same line of work then ruled that this fork does not promote the round at all, so the attribution went
with the funnel instead of surviving as a label. Three tangled things were separated first:

- the **promotion** — deleted;
- the **investor badge type** — kept. `BadgeType.investor` and its wire tag `"investor"` are emitted by
  `src/Popopx/Chat/Badges.hs:105,113,118,120-122,165` for badges the badge service has already issued, so deleting
  them would falsify history rather than promote anything. `badges_type_investor` and the `badge-investor` imageset
  stay; the offer copy around them goes with the next commit;
- the **records** — `CHANGELOG.md`, `FORK.md`, this file, the flatpak `<release>` notes and the blog URL slugs that
  contain the word "crowdfunding" are untouched.

Deleted in one scripted pass (`tools/r7/r68_ab_funnel.py`, JSONL + the full patch in `tools/r7/`): 77 files, 3
insertions / 775 deletions, plus 20 files removed.

- **iOS** — `Shared/Views/ChatList/GetStakeBanner.swift` (whole file, 82 lines); in `ChatListView.swift` the two
  `@AppStorage` keys, `showGetStakeSheet`, the `.appSheet`, `openGetStake()`, the onboarding branch and the last arm
  of the banner-slot chain (18 lines, the chain's own closing brace preserved); the `isInUS` section in
  `SettingsView.swift` and its 2 `DEFAULT_GET_STAKE_BANNER_*` constants with their `allDefaults`/`hintDefaults` rows;
  `.getStake` from `ChatListBanner`; the `SnapshotScene(GetStakeBanner_Previews…)` line; the 4 `project.pbxproj`
  records (build file, file reference, group child, Sources phase).
- **Kotlin** — `views/chatlist/GetStakeBanner.kt` (whole file, 133 lines, including `openGetStake`); the banner arm
  and its `remember`s in `ChatListView.kt`; the onboarding banner block in `OnboardingCards.kt` and its 3 imports;
  `GetStake` from `ChatListBanner`; the 2 `mkBoolPreference` rows, the 2 `hintPref` rows and the
  `SHARED_PREFS_GET_STAKE_BANNER_*` constants — no compat read, this is a new application; the settings section in
  `SettingsView.kt` and its 2 imports; and in `WhatsNewView.kt` the two `FeatureView` entries plus
  `CROWDFUNDING_CONTACT_URI`, the 4 layout constants, `CrowdfundingLayout`, `crowdfundingLayout`,
  `crowdfundingAvailable()`, `InvestInSimpleXChatView`, `CrowdfundingSlide`, `getStakeSlides`, `GetStakeView` and
  `Modifier.fullScreenOnClick` — 291 lines. `MAX_PAGE_ZOOM` and `Modifier.pinchZoom()` went with it because their
  only caller was `GetStakeView`; `WEFUNDER_URL` and `isInUs()` stayed because the badge offer and the `v7.0.1`
  version label still read them — they move with the badge layer, not with the funnel.
- **Artwork** — the 8 `crowdfunding_{1..4}@{2x,3x}.jpg`, the 4 `assets/default` placeholder SVGs and the 4
  `branding/source-svg/crowdfunding_*_light.svg` masters.
- **Strings** — `invest_banner_title`, `invest_banner_subtitle`, `invest_settings_title`, `v7_0_invest_descr`,
  `v7_0_crowdfunding`, `v7_0_invest_learn_more` (all `translatable="false"`, so base only) and `v7_1_invest`
  (20 moko files); on iOS the keys "Learn more on Wefunder" and "Crowdfunding on Wefunder" — 16 `.strings` entries
  in 11 `.lproj` and 20 xliff units in 13 `.xcloc`.

Verified: the token sweep (`GetStake|getStake|crowdfunding|Crowdfunding|CROWDFUNDING`) is **0** in `apps/ios/Shared`
and `apps/multiplatform/common/src` except the 4 rows this commit does not own (the 2 badge-layer strings go with
commit 2, the 2 blog URL slugs are held); 69 XML files re-parse; `scripts/ios/localizations.py check` rc 0 (514
warnings, all pre-existing); `ding_wire_audit audit` FORWARD 0 / REVERSE 0 / BARE 16 — unchanged; `xcodebuild` Debug
**BUILD SUCCEEDED** for `generic/platform=iOS` and `generic/platform=iOS Simulator`; the `large` set re-rendered as
**262 scenes with 0 changed** (374 references, down from 376), 4 baselines re-installed — `SettingsView-{light,dark}`
because the section lived inside the settings list itself (so `isInUS` is true in the harness) and
`ChatListView-{light,dark}` because the banner row is gone. Android: static checks only, no Android SDK or gradle on
this machine.

### File and artefact names — 45 paths moved, 22 held (2026-11-13)

The residue left after the copy, wire and asset tiers was **names**: 67 tracked paths were still spelled
"simplex". None of them could be renamed as documentation, because each is a build input, an installed
path, a generated artifact key or a resolved module — so all 45 that moved went with their readers in one
pass:

- **13 Kotlin files**, each named after the symbol it declares — `PopopxApp.kt`, `PopopxService.kt` (and
  its `platform/` expect/actual pair), `PopopxAPI.kt`, `POPOPXInfo.kt` (+ `.android`/`.desktop`),
  `PopopxNameView.kt`, `SetPopopxDomainView.kt`, `SupportPOPOPXBanner.kt`, `BadgesSupportPopopxView.kt`.
  Four of them were already orphans: the identifiers inside had moved weeks earlier and nothing outside
  the file named them. 339 path citations in this fork's own code maps
  (`apps/multiplatform/{CODE.md,product/**,spec/**}`) moved with the files.
- **2 desktop snapshot baselines**: `SimpleXInfo.PreviewSimpleXInfo-*.png` →
  `POPOPXInfo.PreviewPOPOPXInfo-*.png`. The name is generated (`SnapshotTest.kt:180`
  `"${scene.name}-$theme-font-$scale.png"`), so those two files had been orphaned by the display-copy tier
  and were pointing at nothing.
- **4 desktop launcher artifacts** — `distribute/SimpleX.desktop` and `distribute/simplex.{png,ico,icns}`
  became `popopx.desktop` and `popopx.{png,ico,icns}`, together with their three `iconFile.set(…)` sites
  in `apps/multiplatform/desktop/build.gradle.kts:68,73,82` and the `cp` in
  `scripts/desktop/make-appimage-linux.sh:41`. These are build inputs: a half-move is a desktop bundle
  that silently ships the default icon. The generator of the three binaries — `tools/r7/popopx_logo_sync.py`
  and its manifest `tools/r7/popopx_brand.py`, both outside this repo — kept emitting the old names until
  2026-11-15, so a re-run would have written untracked `simplex.*` files beside our own and never refreshed
  them; it now targets the tracked `popopx.{png,icns,ico}`, `media-logos/popopx-*` and `images/popopx-*`.
- **2 build-reproduction scripts** and both readers (`.github/workflows/reproduce-schedule.yml`,
  `scripts/ci/android/release-apk.sh`).
- **2 support-bot test mocks**. Their **alias keys stayed** (`"simplex-chat"`, `"@simplex-chat/types"` in
  `vitest.config.ts`): those are the npm names `package.json` installs, so they belong to the published
  packages, not to us. Only the mock paths moved.
- **22 artwork files** — `media-logos/**` and `images/**` together with their `branding/source-svg/`
  mirrors, whose names are the output path with `/` written as `__`, so a half-move would break the
  convention that generated them. All 24 files in this set are POPOPX bytes; only the names were upstream's.

**Deleted, not renamed.** `branding/source-svg/moko__ic_simplex_{dark,light}@4x.svg` are byte-identical to
their already-renamed counterparts `moko__ic_popopx_*@4x.svg` (same md5, `2fb6e266…` and `8e284b07…`) and
nothing reads them, so a rename could only have collided with the file it was meant to become; deletion is
the only move that removes the name.

**Held, with reasons.** 20 paths in `packages/**` (the Node `simplex.{cc,h,js,d.ts}` and the Python module
`src/simplex_chat/**`) — `packages_release.py test-names` rewrites the published names from `NPM_SCOPE`
and `PYPI_PROJECT`, and an installed distribution name is not prose. That is the whole residue: **67 → 20**
paths named "simplex", 45 renamed with their readers and 2 deleted.

This pass also repaired a **compile break on `master`**: the display-copy tier `82130779f` renamed Kotlin
declarations and left 10 import lines naming the old symbols, which made CI's
`:common:compileKotlinDesktop` fail (unresolved `SimpleXTheme` ×7, `SimpleXLinkQRCode` ×2, `SimpleXInfo`
×1). It survived because Kotlin is not compiled on the machines used for this fork's static verification.
`tools/r7/kt_import_gate.py` now replays kotlinc's import resolution over every brand-derived import —
10 findings against `f5a7fd984`, 0 against this tree.

A second class survived the same way: the namespace/link-scheme tier `05dd5a73c` carried its own
shell-level escaping into the replacement text, so seven assertion lines in `AppLinkSchemeTest.kt` read
`windowsSchemeValues(\"popopx\", windowsExe)`. A backslash in code position is a **syntax** error, which
no identifier audit can see — the identifier it looks for is intact. `:common:compileTestKotlinDesktop`
failed, and because that task gates the tests that render them, the run produced **no snapshot artifact
at all**: 34e8b5045 removed the 8 stray backslashes, and `tools/r7/kt_lex_gate.py` (a Kotlin lexer replay,
0 false positives against `db0768c21`) now reports the class.

**The desktop CI harness still addressed the app by its pre-rebrand identity.** The values were moved by
approved tiers; the readers were not, so `scripts/ci/desktop-linux/ui` execed `bin/simplex` from a package
named `popopx`, seeded settings into `$XDG_CONFIG_HOME/simplex` where `Platform.desktop.kt:7` writes
`popopx`, and waited for a window called `SimpleX` while `DesktopApp.kt:130` titles it `POPOPX`;
`smoke-test.sh` OCR-matched a search field whose text became `Search or paste POPOPX link`
(`search_or_paste_popopx_link`) in 6 places. The launcher is now derived from the app directory, and the
two jobs that drive **upstream's** released build pass its config directory and window title explicitly,
so "names an upstream thing keeps upstream's name" still holds there.

**The 210 desktop snapshot baselines were regenerated** by CI run `43397744144`, on the ubuntu runner that
renders them. 20 files changed, and they are the 9 scenes whose pixels carry the brand:
`ChatHelpView`, `ContactConnectionInfoView`, `HelpView`, `NewChatSheet`, `POPOPXInfo`, `QRCode`,
`SettingsView`, `UserAddressView`, `WhatsNewView`. The other 190 are byte-identical to what was committed
before, which is expected rather than suspicious: those scenes contain no brand content, and an unchanged
PNG is not a copied one — every file in the set was written by this run. 18 of the 20 had previously been
identical to upstream's, so they leave the "upstream artwork still in the repository" count
(`ASSETS_LICENSE.md`: 565 → 545). This run also shows what the class above costs: because
`desktopTest` renders the baselines, the artifact only exists if `:common:compileTestKotlinDesktop`
compiles, so a syntax error in one test file ships no baselines at all.

### Data locations — treat this as a new application

An installation that ever used a SimpleX-named build does **not** see its chats in this one, and no
migration is provided on purpose. The moved locations are the iOS bundle id / App Group / keychain
access group, the Android `applicationId`, notification-channel and preference-store ids, the
on-disk database prefixes `popopx_v1*`, the macOS `bundleID` and Windows registry capabilities, the
AppImage/AppStream ids, the Flatpak desktop/metainfo ids (`scripts/flatpak/com.popopxchat.popopx.*`)
and `.appdata.xml` filename, and the application data directories. The CLI and the bots call
`getAppUserDataDirectory "popopx"`: `~/.local/share/popopx` on Linux,
`~/Library/Application Support/popopx` on macOS, `%APPDATA%\popopx` on Windows. The desktop app uses
`~/.local/share/popopx` and the config dir `~/.config/popopx` (`%AppData%\POPOPX` on Windows) — both
read from `Platform.desktop.kt:7-16`, which is the generator for these paths. The server-side
filesystem identity moved too — 200 occurrences / 9 files across `docs/SERVER.md`,
`docs/XFTP-SERVER.md`, their `pl`/`fr`/`cs` translations and `docs/CHAT-RELAY.md`:
`/etc/opt/popopx{,-xftp}`, `/var/opt/popopx{,-xftp}`, `/var/lib/tor/popopx-smp`, the
caddy/systemd/docker-compose names — matching what `popopxmq` compiles in as `defaultCfgPath`. The
chat relay's Postgres role and database are `popopx` and `popopx_chat_relay`
(`scripts/relay/.env.example`), and the relay guide's `systemctl`, `Unit=` and executable
references name the `popopx-*` artifacts that guide installs. The commands that fetch a server
still name upstream's artifact (its release binary and the `simplexchat/*-server` image default),
which reads `/etc/opt/simplex`; see `FORK.md`.

### What the user sees

Display copy in every iOS catalogue, Kotlin/Swift string and locale, terminal output and live
documentation says POPOPX. The link namespace the app recognizes and emits is `popopx.chat`
(`.well-known`, universal links, Android `autoVerify`) — **ruled as this fork's link domain on
2026-11-13, with `popopx.im` as the relay domain.** The domain is registered and a site answers on
it, but its TLS certificate names only `popopxchat.com` and nothing is published under
`.well-known`, so link previews and profile/domain resolution remain inert until that box serves a
matching certificate and the two association files.

Flux is **not offered as a server operator** (ruled 2026-11-13). Removed: the preset operator record,
the v6.2 "Network decentralization" what's-new entry, the operator description cards, the routing
example that named Flux, the `*.simplexonflux.com` universal links (iOS entitlements) and intent-filter
hosts (Android), the `Flux` iterations in the CI scripts, the three Flux logo assets, and every locale
unit whose text named the second operator (56 carrier files). Kept, with the reason at each site: the
wire tag `"flux"` (`OperatorTag`/`OTFlux` — it decodes stored rows and the published SDK enums), and
the six `smp://…@smpN.simplexonflux.com` host-and-key pairs in `Presets.hs`, which are members of
`allPresetServers` because previously issued short links encode the host they were created on.
`presetDomains` lost `.simplexonflux.com` with the operator.

**The brand artwork is POPOPX's own.** The iOS app icon is the single master
(`apps/ios/Shared/Assets.xcassets/AppIcon.appiconset/1024.png`, purple `#7A2BBE → #3D0A6D`) and every
derived logo, icon, banner, store image and desktop icon is generated from it or redrawn in its palette
(`branding/source-svg/`, `branding/master-logo/`). The last upstream-drawn files in the iOS catalog were
replaced on 2026-11-13: the 3 crowdfunding badge SVGs, the 6 chat-wallpaper sets (18 PNGs) and
`privacy`/`shield` — same names, same pixel sizes, same `Contents.json`, because a wallpaper preset name
is a persisted value and the images are force-unwrapped by name. The wallpapers stay alpha tiles (the
Swift side supplies the background colour), now in purple instead of black. The 376 iOS snapshot baselines
were re-rendered after that: 246 differ from upstream's renders, 130 are byte-equal because those scenes
carry no brand content. What is left of upstream's artwork is measured in
[`ASSETS_LICENSE.md`](./ASSETS_LICENSE.md): UI glyphs that are not brand marks, third-party
logos, and the documentation/site images whose bulk removal is still unruled.

### Interfaces that other code reads

The FFI library is `libpopopx` (a dual lookup for `libsimplex*` is retained); the Node/Python/Rust
SDK mirrors, the MCP tool outputs (`popopx_name`) and the `.popopx-mcp` data directory moved with
them; the SMP dependency is `github.com/popopx-chat/popopxmq`, and so did the names this fork's CI publishes into its own releases (`popopx-chat-*`, `popopx-desktop-*`) with the four readers of the same value: the desktop updater's `githubAssetName` literals, its GitHub API repository, and the doc and website URLs.
The user-facing download links that named an APK asset now point at the Google Play listing (this fork
publishes no APK), and `{{ release }}` — which was never defined in `website/src`, so every desktop and
CLI link on `/downloads` rendered as a relative 404 — is now the `release` member of the site's
`globalConfig`, read as `{% cfg 'release' %}`. See `FORK.md` items 4 and 5.
The libs release assets (`popopx-chat-libs-<os>-<arch>.zip`, `popopx-chat-nodejs-<platform>.node`) and
the repository they are fetched from moved in the same shape — publisher, runtime downloader and the
pinned digest dictionary as one unit, because a half-move downloads upstream's binary and calls it a
success (`FORK.md` item 6).
References to the SMP dependency itself moved second: 144 of the 446 `simplexmq` occurrences became
`popopxmq` — contributor and operator docs, the iOS product/spec layer, the website nav item, and the
`popopxmq` commit link in the iOS version screen (it pointed our own commit at upstream's repository, so
the settings screen 404ed on every build). A reference moved only where the thing resolves in the fork:
the fork renamed `protocol/simplex-messaging.md` → `protocol/popopx-messaging.md` and
`src/Simplex/**` → `src/Popopx/**`, and it has one branch, `master`, so `stable` ref segments moved with
the path. The three test harnesses that download `smp-server`/`xftp-server` now take them from
`popopx-chat/popopxmq`, which publishes no releases: those suites fail with a 404 until it does, by
ruling, rather than testing our core against a server built from another source (`FORK.md` item 7).
The site's own location moved too: `siteLocation` (`website/.eleventy.js`, read by 19 `og:url`/`og:image`
sites as `{% cfg 'siteLocation' %}`; there is no environment override) and `website/markdown_pages.js`,
which declares the same string a second time, plus the two blog feeds' `metadata.url` — all
`https://popopx.chat` → `https://popopx.chat`, because `website/src/CNAME` already read `popopx.chat`.
`onionLocation` next to it stayed upstream's. The rest of the site's own declarations followed in the same
pass — 142 further occurrences in 19 files, because several templates and scripts hardcode the host instead
of reading `cfg`: the generated sitemap `<loc>`, `robots.njk`'s `Sitemap:` line, the llms indexes and
`_data/llms_facts.json` sources, the badge images and store links in `js/channel-preview.jsc`,
`js/directory.jsc`, and both arms of `isCurrentSite` in `js/simplex-lib.jsc` (its `www.simplex.chat` alias
became `www.popopx.chat`, since the predicate asks "is this our own page"). 36 occurrences stayed, and
they are not self-declarations: 31 in `website/langs/*.json` and 2 in `src/_includes/blog_previews/` are
translated display copy and upstream's published announcements whose *labels* still name upstream's app,
and 3 are `…/contact#/?…smp%3A…` links carrying SimpleX Chat Ltd's encoded SMP address — moving only the
host would hand that address out from our page. Those contacts are now **`mailto:chat@popopx.chat`** (the
`/connect-team` redirect target, the two llms links with their label, and 21 translated contact strings);
the 10 upstream *service* subdomains in the site (`directory.`, `app.` with its F-Droid signing
fingerprint, `badges.`, `git.`, `api.`) and the 2 occurrences inside upstream's own 2022 announcement
stayed, so no `https://simplex.chat` remains in the website except those.
The same host then moved everywhere a client or a user follows it: **378 of the 680 remaining occurrences
outside `website/**`, 300 lines / 83 files** — iOS onboarding and chat-item strings, Kotlin onboarding,
the Flatpak AppStream URLs, the badge/directory/support-bot packages, `README.md`, `docs/guide`, `docs/FAQ.md`,
the SDK READMEs and 98 `tests/**` mirrors of those same strings. Two live defects came out of it: the
Python SDK generated group share links as `https://simplex.chat/contact#/?v=2&group=…` (our app handing out
an upstream-hosted link for a group our own relay serves) and the badge site's contact footer had moved its
`href` while its visible label and its test assertion still read `simplex.chat/contact`. Held there: 135
occurrences in the 23 generated `POPOPX Localizations/*.xliff` catalogs (Xcode re-emits them from source;
hand-editing guarantees a drift), 42 links carrying another operator's encoded relay address, and 124 in
upstream's published text (`blog/`, `plans/`, `CHANGELOG.md`, `PRIVACY.md`, `docs/lang/`, `docs/protocol/`).
Because `popopx.chat` did not yet serve the `.well-known` files, the apps began naming a domain that cannot
answer them: universal links and `autoVerify` will not claim until the host publishes those records. Two of the
three conditions this sentence listed are since retired — the certificate **does** cover `popopx.chat` (measured
2026-11-13), and our own Android signing fingerprint **replaced** upstream's three in the dependency's
`assetlinks.json` (2026-11-14, #33 item 1 above) — so what is left is one thing, not three: nothing is served
under `/.well-known/`.
Ruled 2026-11-13 as use-first-and-record; the gap is written up in `FORK.md`.
The npm and PyPI names in the committed manifests are upstream's on purpose: `packages_release.py
test-names` rewrites them, with `npm:` aliases for the cross-package dependencies, from the
repository variables `NPM_SCOPE` and `PYPI_PROJECT` at publish time. The write-up of that method,
`NODE-PACKAGES-POPOPX.md`, is **not in this repository**: the 2026-11-25 history re-initialization
carried neither that file nor `scripts/ci/packages_release.py`, and nothing in `.github` or `scripts`
calls either name, so these sentences are the surviving record. The last blobs are readable from the
pre-restart objects — `git show b9b44beb3:NODE-PACKAGES-POPOPX.md` (6,573 B) and `git show
db0768c21:scripts/ci/packages_release.py` (43,815 B); `git ls-files` for either path returns nothing.
Environment variables that third
party tooling may set are read under both spellings (`SIMPLEX_ASSETS`/`POPOPX_ASSETS`,
`SIMPLEX_LIBS_DIR`, `SIMPLEX_ADDON_PATH`).

**A `@SerialName` is a wire value, and one tier renamed only the Kotlin side of it.** `82130779f` made
`OperatorTag` read `@SerialName("popopx") POPOPX`, while the core still encodes the preset operator as
`"simplex"` (`src/Popopx/Chat/Operators.hs` `textEncode OTSimplex = "simplex"` — the same spelling the
generated Python type carries and `server_operators.server_operator_tag` stores). kotlinx threw on the
`serverOperatorConditions` response, `APISerializer.fallbackResult` reported it as `* serverOperatorConditions`,
the conditions list stayed empty and onboarding's **Accept button was never enabled** — the desktop smoke test
stopped exactly there. No identifier audit can see this class: the string is intact on both sides, only the
two sides disagree. `PopopxAPI.kt` decodes `"simplex"` again, with its two readers, and the entry keeps
upstream's name because it names upstream's operator; the copy shown for that operator stays POPOPX-branded
by ruling. The other five brand-derived tags in the API model were checked against their emitters and match
(`popopx` TLD, `POPOPX` agent error, `popopxName`, `popopxLink`, `popopxLinks`, `popopxDomainNotReady`).
The same run left **7 test mirrors** behind from earlier tiers: 5 still named the Windows ProgId
`SimpleX.simplexchat` after `WINDOWS_PROG_ID_PREFIX` moved to `"POPOPX."`, and 2 case-variant link fixtures
disagreed with their producers in opposite directions — `PopopxChat:/badge/…` had renamed a scheme that is
held as `simplexchat`, while `SimpleX:/a#…` still spelled the connection scheme that moved to `popopx` in
`05dd5a73c`.

**The class now has a guard that fails if it comes back.** `ServerOperatorsWireTest.kt` decodes the
`conditions` value of a real `serverOperatorConditions` response — taken byte for byte from the failed run's
`app.log` — with the app's own `json`, and asserts both `operatorTag`s read `OperatorTag.SIMPLEX`. Renaming
either side alone turns it red, and the payload is not hand-written, so it cannot drift from the core.
Run `43405919477` on this repository proved both: `:common:desktopTest` was green with
`ServerOperatorsWireTest` listed as 1 test / 0 failures, and the smoke test reported "onboarding reached the
chat list" with `wait "Talk to someone"` resolving on screen — the button that the broken tag had kept
disabled.

**The last desktop launcher line moved with it.** `distribute/popopx.desktop`, which `make-appimage-linux.sh`
installs as `com.popopxchat.popopx.desktop`, still read `Name=SimpleX Chat` and `/opt/simplex/…` although our
package installs the launcher as `/opt/popopx/bin/popopx`. The deb is unaffected either way: `make-deb-linux.sh`
rewrites the desktop entry jpackage generates for it, and only `Name=` survives into the AppImage menu. Held,
with the reason in the file: in `scripts/flatpak/com.popopxchat.popopx.desktop`, `Exec=simplex %U` names the
command the Flatpak manifest declares (that manifest is not here) and `StartupWMClass=simplex-chat` has to match
the class the running app sets, which nothing in this repository controls.

### The reproduce chain was pointed at this repository (2026-11-13)

`.github/workflows/reproduce-schedule.yml` was the mirror image of the desktop-CI finding: a workflow
whose *checkout* names one tree cannot call a *script* renamed in another. It pulled
`simplex-chat/simplex-chat` at the latest upstream tag, then ran `scripts/popopx-chat-reproduce-builds.sh`,
which exists only in our tree; `|| :` swallowed the missing file, the `_sha256sums` test found nothing, and
both scheduled runs (43143049757, 43353616675) went red having compiled nothing. Everything that names
*which build is being proven* moved as one unit: the releases API and the checkout repository,
`repo_name`/`repo` in the script, the three release-asset names (matched against our producers
`build.yml:568`, `:619`, `:643`), the CLI the container builds (`popopx-chat.cabal:607`), the two package
paths (`build-cli-deb.sh:12`, `make-deb-linux.sh:58`), and the sums directory in the workflow, which is now
read out of the script instead of written a second time. One of those was invisible to every token sweep:
`mv release/main/*imple*.AppImage` is a glob, not a word, and would have matched nothing in our build - it
now derives the file the way `build.yml:635` does.

The job is inert until this fork publishes a release (`releases/latest` answers 404), so the first step
detects the empty tag and skips; that is what it does nightly now. Held by the usual rule: the Android
script's `REPO_NAME`/`REPO`/`SIMPLEX_REPO`/`SIMPLEX_KEY`, which name upstream's signed APK, because that is
what it verifies. `FORK.md` §"Reproducing a build" documents how both are run and records that
`STATUS_POPOPX_WEBHOOK_URL/_USER/_PASS` are not configured here, so a red run is the only signal.

### The macOS signing scripts stopped asserting another company's identity (2026-11-13)

Three CI scripts named SimpleX Chat Ltd's certificate as if it were ours: `build-desktop-mac.sh` wrote
`desktop.mac.signing.identity=Developer ID Application: SimpleX Chat Ltd (5NN7GUYB6T)` and
`desktop.mac.notarization.team_id=5NN7GUYB6T` into `local.properties` for the dmg build, `sign-libs-mac.sh`
had `team=5NN7GUYB6T` and composed the same label for `codesign --sign`, and `prepare-keychain-mac.sh`
imported `Developer ID Application: SimpleX Chat Ltd (5NN7GUYB6T).cer`, `SimpleX Chat.p12` and
`SimpleX Chat.pem`. They are unreachable today - the desktop steps are gated on a tag push and this fork has
published no release (`releases` answers an empty list) - so nothing had ever run them, which is exactly why
they had to move before #56 rather than after it: the first release tag would have signed and notarized our
build under SimpleX Chat Ltd's name, or died in the keychain.

The identity is now configuration, not source: `APPLE_POPOPX_SIGNING_IDENTITY` supplies the codesign label and
`APPLE_POPOPX_NOTARIZATION_TEAM_ID` the team, both read at job level in `build.yml`. The team id is forced to
`PDBA6XRBQT` - the value already in `DEVELOPMENT_TEAM` (two configurations), in `KeyChain.swift:13`'s access
group and in `FORK.md` - and is written as the scripts' default, overridable, because it is an identifier and
not a credential; the label itself cannot be derived here since it embeds our legal entity name as it appears
on the certificate. When the label is absent the two desktop steps are skipped with a warning instead of
failing, so a release is not blocked by signing material we do not hold yet. That exemption deliberately does
not cover `sign-libs-mac.sh`: the notarized dylibs feed the `popopx-chat-libs` release, which feeds the
Node.js add-on and the npm packages, and publishing an unnotarized `libsimplex` would be the worse half -
`popopx-chat-libs` has no releases either, measured the same day. `prepare-keychain-mac.sh` is not called by CI
at all, so it keeps working as the local counterpart, now with the file names derived from the same three
values. Held: `"Developer ID Certification Authority.cer"`, which is Apple's own intermediate. The
`app.name=SimpleX Debug` label in `apps/multiplatform/README.md:86` and `local.properties.example:4` was left
for a separate ruling the same day, which moved it - see "The quick-install path was pointed at this
repository" below.

### The quick-install path was pointed at this repository (2026-11-13)

`README.md` told readers to run **upstream's** installer - `curl -o-
https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh | bash` - and then, one line
below, to run `popopx-chat`, which that script never installs. The script this repository ships had the same
defect from the inside: `APP_NAME="simplex-chat"` is not a label but the download value, interpolated at
`:82`/`:84` into `https://github.com/$APP_NAME/$APP_NAME/releases/$DOWNLOAD/$APP_NAME-$PLATFORM` (owner,
repository, asset prefix) and at `:7` into the path of the installed binary, so our own installer fetched
**upstream's binary from upstream's releases** and named it `simplex-chat`. The next release would have
appeared in our releases list as `popopx-chat-*` (`build.yml:1020`, `:1027`, `:1431`, and
`popopx-chat-ubuntu-22_04-x86_64` from the matrix at `:291`/`:292` plus the derivation at `:568`), so the
script could never have installed this fork.

`APP_NAME` moved to `popopx-chat`, which carries the binary lookup at `:33`/`:34`, the release listing at `:26`
and the success line at `:92` with it, because they read the variable; the three strings that named the product
without reading it (`:13`, `:17`, `:61`) moved in the same step, since after the retarget they would have
described our own build as SimpleX Chat. The README line now fetches `master` of this repository - `master` is
the only branch here, measured against the remote, so there is no `stable` to point at. Verified statically:
`bash -n`, the URL recomposed from the moved variable, and the asset names diffed against the CI matrix. Not
verified end to end, because this repository has published no release yet (#56) - `releases/latest` answers 404
for both owners today.

Left as they are, with reasons: `$HOME/.simplex/simplex.agent.db` at `:43` probes upstream's v0 agent database
before offering to move an old binary aside, and it names something that is genuinely upstream's, so it stays
spelled that way; the Darwin branch at `:20`-`:24` selects only `macos-x86-64`, so an Apple Silicon machine
installs the Intel build through Rosetta - a pre-existing upstream gap in a path that is not yet testable, and
widening it is a separate decision from pointing the installer at this repository.

The same ruling closed the debug app label: `app.name=SimpleX Debug` became `POPOPX Debug` in
`apps/multiplatform/README.md:86` and `local.properties.example:4` (2 occurrences). It is a live value -
`build.gradle.kts:19` reads it, `android/build.gradle.kts:57` puts it in the manifest placeholder,
`AndroidManifest.xml:45`/`:60` render it as the launcher name - but only for a developer who sets it, since the
default is `@string/app_name`, which is already `POPOPX`. No compatibility reading, per "this is a new
application".

### The iOS crowdfunding funnel was restored, with the round named as upstream's (2026-11-13)

> **Superseded 2026-11-14** by "The crowdfunding funnel is deleted" above. Kept as the record of why the funnel was
> asymmetric, and of the `project.pbxproj` four-entry hazard, which still applies to every iOS source file.

The funnel was asymmetric. The Kotlin app showed a card titled "Invest in POPOPX Chat!" whose only action opens
`wefunder.com/simplex.chat`; iOS had no such card at all, because the view was removed in the inherited commit
`9c8df8f09` and its banner slot carries `SupportPOPOPXBanner`. The destination was never the problem - the label
was: a card in our brand recruiting investors for another company's round, on the platform that still had it.
Ruled 2026-11-13: restore the iOS funnel, so the two platforms show the same thing, and move both platforms' copy
to name the round as SimpleX Chat Ltd's.

Restored on iOS as one new file, `Shared/Views/ChatList/GetStakeBanner.swift` (82 lines): `GetStakeBanner` (`:15`)
and `GetStakeView` (`:48`), with fork-authored copy - headline "Upstream's crowdfunding round", subheadline "The
round is run by SimpleX Chat Ltd - POPOPX receives none of it", and a detail paragraph that says this fork is not
part of the round and receives none of the money. The destination is unchanged:
`https://wefunder.com/simplex.chat?utm_source=app_ios` (`:13`), held verbatim including the `utm_source`, because it
names where the user goes rather than who we are. The wiring moved with it: `.getStake` in `ChatListBanner`
(`ChatModel.swift:389`), the chat-list branch as the last arm of the banner-slot chain (`ChatListView.swift:554`) and
the onboarding branch under the same `bannerSlotFree` check (`:463`), the sheet (`:227`) and `openGetStake()`
(`:454`), `DEFAULT_GET_STAKE_BANNER_TAPPED`/`DEFAULT_GET_STAKE_BANNER_DISMISSED` (`SettingsView.swift:65`/`:66`)
registered in `appDefaults` (`:132`/`:133`) and `hintDefaults` (`:168`/`:169`) - so "Reset all hints" restores the
banner - and the `isInUS`-gated section in settings (`:427`).

Two things upstream had in this view were deliberately not restored. The slide artwork is SimpleX's proprietary
illustration, absent from this tree, and dressing a third party's campaign with POPOPX marks would restate the very
claim we removed in text - so the card is chrome only, no image. And the "or ask the SimpleX team" contact route,
which would send our users into upstream's support chat under our brand.

The Kotlin side kept its destination and lost the claim: `invest_banner_title` in
`moko-resources/base/strings.xml` and the two `WhatsNewView.kt` strings (3 occurrences) now read "Upstream's
crowdfunding round", and the slide body says SimpleX Chat Ltd plan to make *their* network profitable. That first
pass was a half-move, and the rest of the same card said so, so the non-translatable copy went as one unit
(`tools/r7/r58_kt_funnel_relabel.py`, 7 lines / 2 files): the four slides now name SimpleX Chat Ltd, SimpleX Chat
and SimpleX Network instead of this fork - the user growth, the donation total, the developer ecosystem and the
revenue plan are upstream's, and they are what a Wefunder subscriber is buying - and the row under the button reads
"or ask the SimpleX Chat team", because `CROWDFUNDING_CONTACT_URI` (`WhatsNewView.kt:1074`) is a contact on
`smp11.simplex.im`, upstream's address, not ours. `invest_settings_title` went the same way ("Own a part of SimpleX
Chat"). Three `POPOPX` mentions remain in that file, all build identity (`POPOPX_ASSETS`, `POPOPXTheme`,
`generalGetString`).

Verified: `xcodebuild` **BUILD SUCCEEDED** for the device target and the arm64 simulator. The first attempt failed
with 25 `cannot find type` errors across the module - `UserPickerSheet`, `PresetTag`, `ActiveFilter`,
`SaveableSettings`, all declared in `ChatListView.swift` - because the scripted `project.pbxproj` edit *replaced*
the two `ChatListView.swift` lines instead of inserting beside them, so the file left the target while its Sources
phase entry dangled. The repair is 4 pure insertions (`git diff --numstat` = `4 0`), and membership was then
cross-checked file by file: `GetStakeBanner.swift` appears exactly 4 times (build file, file reference, group
child, Sources phase), and the only disk files with no file reference are a playground `Contents.swift` and
`Shared/Views/Helpers/Keyboard.swift` - both already absent in `HEAD`, so they are pre-existing dead files, not part
of this change.

Snapshots: `SnapshotScene(GetStakeBanner_Previews.self)` is back in the harness (`POPOPX Snapshots/SnapshotTests.swift:280`)
and the set was re-rendered on the iPhone 17 Pro simulator - **264 renders, 258 byte-identical** to the committed
baselines (the determinism proof), **6 replaced**: `GetStakeBanner-{light,dark}-large.png`, which the removal had
orphaned and are now our own renders of our own copy, `ChatListView-{light,dark}-large.png`, because the banner
occupies a list row, and `SettingsView-{light,dark}-large.png`, because `SKStorefront` answers `""` under the
simulator and `isInUS` counts that as the US. Nothing is new and nothing is missing, so the set stays at 376 files.
Android/desktop: no desktop scene renders `GetStakeView`, and the what's-new card reads the *localized* `v7_1_invest`
key, which this commit does not touch - so the only way the 210 desktop baselines are affected is if
`SettingsView.PreviewSettingsLayout` renders the crowdfunding row, and that is a CI question (`desktopTest` is
`workflow_dispatch`-only) that cannot be answered before the push. It was answered the same day, and the answer is
yes - see the next section.

The documentation that had described the removal went back in the same step: `spec/client/chat-list.md` §10 lost its
"Removed from POPOPX iOS builds" note and now describes the shipped view - the placement table says what the code
does (the chat-list arm is the *last* of the banner-slot chain, reached only when no badge banner holds it), the
chrome paragraph points at `SupportPOPOPXBanner.swift:94` where `BannerCard` and `BannerDismissButton` are actually
declared, and the Source Files row links the file with `GetStakeBanner` at `:15`. `product/views/chat-list.md` (3
lines) and `spec/impact.md:55` followed, and `SupportPOPOPXBanner.swift:93`'s comment no longer says the chrome
"lived in `GetStakeBanner.swift` until the invest tier removed it". The insertions moved every later line in three
source files, so **65** `#L<n>` anchors across `spec/state.md`, `spec/client/chat-list.md` and `spec/architecture.md`
were remapped from the diff's insertion hunks (`tools/r7/r58_anchor_remap.py`, logged to
`r58_anchor_remap_20261113.jsonl`); the remap is content-preserving by measurement, not by argument - for all 65,
the source line at the new number is byte-identical to the line at the old number in `HEAD`. The same pass repaired
three doc lines that contradicted shipped copy (the stale-mirror class): "You can support **SimpleX** later in
Settings." -> POPOPX (the code says POPOPX at `ChatListView.swift:434`), "create a SimpleX address" -> POPOPX, and
"pasted SimpleX links" -> POPOPX (`:812` renders "Search or paste POPOPX link").

What was measured and left alone. `apps/popopx-badge-service` says "Learn more on Wefunder" beside the Wefunder
wordmark, and `packages/popopx-chat-mcp/README.md:74` says "SimpleX Chat, the company that builds SimpleX Network,
is raising a community round" - both name the destination and its owner, so neither misattributes. The rest of the
crowdfunding copy does claim the round for us, and it comes in two shapes that decide the size of the fix. Part 2 of
this commit could move the untranslated line: moko key `invest_settings_title` is `translatable="false"`, so naming
the round's owner there is 1 line in 1 file. Its localized sibling `v7_1_invest` - base "Own a part of POPOPX Chat!
🚀", read at `WhatsNewView.kt:961`, `:988` and `:1130`, where the third is the `InvestInSimpleXChatView` heading - is
20 files and 20 lines. The same split on the other two claims: `badge_invested` (23 files, 23 lines) and
`popopx_name_sales_footer` (21 files, 21 lines) on the Kotlin side, and on iOS the literals at
`Shared/Views/Helpers/NameBadge.swift:152` ("%@ invested in POPOPX Chat crowdfunding.") and
`Shared/Views/UserSettings/UserAddressView.swift:924` ("Crowdfunding investors can reserve names before the sale
starts.") - 1 line each, the first with 12 localized `.strings` rows behind it, the second with none, so it renders in
English in every language. Naming whose round it is therefore puts "SimpleX Chat" back into 78 shipped string lines
(64 moko + 12 iOS `.strings` rows + the 2 Swift literals) - the opposite direction from the copy tier - so the whole
set is listed for ruling rather than carried by this commit. Measured alongside it, a case where the key itself carries
upstream's address: 11 `.strings` rows keyed on "Crowdfunding investors can reserve names before the sale starts:
[simplex.domains](https://simplex.domains/)", the retired English source of that line - a URL inside the lookup key,
which is why it matches nothing in the app today. The iOS localization catalogs also still hold 34 rows in 12 `.lproj`
files whose key is the retired "Invest in POPOPX Chat!"
(plus 118 rows in the exported `.xcloc` bundles, which are not build inputs - `project.pbxproj` never mentions them);
they translate a string no longer in the app, and our new English copy has no key there at all, so a non-English
user sees the restored banner in English until localizations are exported again.

### The 2 desktop baselines the crowdfunding copy moved, twice (CI runs 43423298339 and 43430543180, 2026-11-13)

The crowdfunding question the previous section left to CI is answered: run `43423298339`, dispatched on `master` at
`562b28f93`, rendered all **210** desktop baselines (the 211 counted above was wrong - the committed set is 210 PNGs,
and the artifact's `index-desktop.json` has exactly 210 entries with no name-set difference in either direction).
`scripts/ci/snapshots-compare.py` judged them **208 `equal`, 2 `changed`**, and the 2 are
`SettingsView.PreviewSettingsLayout-{light,dark}-font-100.png` - 504 changed pixels each, `maxDelta` 121, every one of
them inside `x 101-180, y 831-843` of the 402x874 image. That rectangle is the crowdfunding section header:
`SettingsView.kt:143` titles the section with `MR.strings.invest_settings_title`, and the restore moved that
non-translatable string to "Own a part of SimpleX Chat". The row is reached on desktop because
`crowdfundingAvailable()` (`WhatsNewView.kt:1109`) returns `true` for anything that is not a Google Play build.

So the render was right and the committed baseline was stale, which is the opposite of the case for a normal
residue install and the reason the diff was read before it was copied. The install rule did not change: only the 2
files the comparator called `changed` were replaced, the 208 `equal` ones were left as they are (they are byte-identical
to this run's renders, which is also the determinism proof for the runner), and after the copy all 210 committed
baselines are byte-identical to the artifact. The job's only red step was `Compare snapshots` - the comparator exits 1
on any failure - while `Run desktop tests`, `Run smoke test` and every upload were green.

`ef2e906b7`'s 3 `SettingsView.kt` edits pass URLs to `uriHandler.openExternalLink` and draw no text, so they move no
preview: a dispatch on `ef2e906b7` alone would have reported 210 `equal`. The install is driven by
the comparator's own `compare.json` (`tools/r7/r63_install_desktop_baselines.py`, 2 rows logged to
`r63_desktop_baselines_20261113.jsonl`) rather than by a second, independently written pixel diff - a second
implementation is how this pass nearly went the wrong way: a hand-transcribed copy of the Paeth predictor reported
2755 changed pixels across the full image width instead of the real 504 in one text row.

Ruled the same day, so these 2 baselines are stale again: the header should not have named upstream's product at all.
The same commit gave the identical iOS slot the wording `SettingsView.swift:429` - "Upstream's crowdfunding" - and the
Kotlin side had kept "Own a part of SimpleX Chat", so the two platforms described the same section differently and only
one of them avoided the brand name. `invest_settings_title` now reads "Upstream's crowdfunding" (1 line, 1 holder, the
only reader being `SettingsView.kt:143`, no test mirror), which matches iOS rather than the banner's
"Upstream's crowdfunding round" - the banner pair (`invest_banner_title` and `GetStakeBanner.swift:26`) already agreed
with each other, and this restores the settings pair the same way. The reader carries the iOS commit's reason as a
comment. Run `43430543180`, dispatched on the pushed `b614b38d9`, reported exactly that and closed it: **208 `equal`,
2 `changed`** - the same two previews, 933 and 927 pixels inside the same 12-row band (`x 20-177, y 831-843`), the crop
reading "Upstream's crowdfunding" where the baseline still read "Own a part of SimpleX Chat". Only those 2 were
replaced, and all 210 committed baselines are again byte-identical to a CI render. `Compare snapshots` was the run's
only red step; `Run desktop tests` and `Run smoke test` were green.

### The bug-report and repository CTAs now point at this repository (2026-11-13)

The test is the one the crowdfunding pass used: a **label that is ours with a destination that is
upstream's** is ours to move, and a value that only *resolves* in upstream's history stays. 14 lines in
12 files moved:

- `StartupError.kt` `ISSUES_URL` - the desktop crash dialog. Its own HELD comment read "until our own is
  set up", so the premise was re-measured before the comment went: `gh api repos/popopx-chat/popopx-chat`
  is `fork:false` with `has_issues:true`. One constant, two readers - the Linux dialog opens it, the Win32
  dialog **draws it as the link text** - so on Windows the address is shown, not only clicked.
- `SettingsView.kt` x3: Contribute (the deep link `#contribute` needs our README to carry that heading -
  it does, `## Contribute` at :103), Star on GitHub, Install the terminal app.
- the `bugtracker` URL in the AppImage AppStream and in the flatpak metainfo, the F-Droid fastlane
  description, and `packages/popopx-chat-mcp/README.md`.
- `bugs.url` in four package manifests plus `[project.urls] Issues` in the Python one.
  `packages_release.py test-names` was read before deciding the layer: it rewrites only `name` and
  `repository.url` (`:902-936`), so `bugs` ships **as committed** and belongs in the source, not in the
  release step. All three new URLs measured HTTP 200.

Measured and left, with the reason written into `FORK.md`: the `homepage` and `repository.directory` of
those same manifests, which still name paths inside upstream's tree
(`.../tree/stable/packages/simplex-chat-nodejs#readme`) and are derived by nothing - that is a decision
about where our published packages advertise their own documentation, not a text move. It was ruled the
same day, and moved: see the next section. Held as upstream's:
`defaultConditionsLink` and the `conditionsCommit` URLs in `OperatorView.kt` / `NetworkAndServers.kt` and
their Swift twins (a server-supplied SHA resolves only in upstream's history, and the document is SimpleX
Chat Ltd's), `CIVoiceView.kt:29`'s PR citation, and the badges-rpc citations pinned at `db0768c21`.

Verified: static only for Kotlin (no gradle or Android SDK on this machine); the four edited
`package.json` files re-parsed with `json.load` and the single TOML line checked in context (`tomllib` is
absent from this `python3`); `ding_wire_audit` sweep 0, pairs 0/0/0/0, audit FORWARD 0 / REVERSE 0 /
BARE 16; the markdown dead-link gate unchanged at 1 broken outside the generated typedoc dirs (upstream's
`CHANGELOG.md`). The desktop baselines are unaffected - none of these strings is drawn in a previewed
composable, and the crash dialog is not a snapshot subject.

### The packages' own homepages, directories and repository URLs name this repository (2026-11-13)

21 lines in 11 files: the five Node manifests, the Python `pyproject.toml`, three package READMEs, the
AppImage AppStream translate URL and the flatpak metainfo `vcs-browser`. What they had been advertising
was upstream's tree - `.../tree/stable/packages/simplex-chat-nodejs#readme` - on the pages a registry or
a store renders next to our published artifact.

The layer question had to be answered before editing, because the previous pass in this same file was
blocked by it. `packages_release.py test-names` (`:901-936`) rewrites **`name`, `repository.url`, the
`npm:` cross-package aliases and the PyPI `name`** - it touches `homepage`, `repository.directory` and
`bugs.url` not at all, so those ship exactly as committed and belong in the source. The alias hazard that
made hand-editing dangerous is narrower than it looked: `MCP_PINNED` (`:47`), `npm_key` (`:690`) and
`unreleased_pins` (`:587`) read only `name` and `dependencies`, which are the fields the generator pairs.
Moving the three it ignores cannot desynchronise `check-pins`.

Per-value decisions, each measured rather than patterned:

- `tree/stable/` became `tree/master/`, not `tree/stable/` with our org. Our remote has **one branch**
  (`ls-remote` returns `refs/heads/master` alone), so a stable pin would name a ref that does not exist
  here; these links age with the branch, which is the trade.
- `packages/popopx-chat-client/typescript/package.json` `directory` was `"/packages/simplex-chat-client/typescript"` -
  with a **leading slash**, which is not the shape npm expects, since it joins the directory onto the
  repository URL to build the link. It became `packages/popopx-chat-client/typescript`.
- `packages/popopx-chat-webrtc` has no `directory` at all (parsed: `dir=None`), so it moved 2 lines, not 3;
  its `homepage` was also missing the `#readme` half the other four carry, and now has it.
- the translate URL became `{repo}#help-translating-popopx-chat`. A 200 does not prove a fragment -
  GitHub answers 200 for any anchor on an existing page - so the heading was read instead: our
  `README.md:111` is `## Help translating POPOPX Chat`, which is the slug that anchor needs. Same method
  as the `#contribute` check in the previous pass.

Verified: 5 `package.json` re-parsed with `json.load`, 2 XML documents through `ET.parse`, the TOML by
diff (`tomllib` absent here); the 8 distinct new URLs each measured **HTTP 200** through the proxy;
after-counts leave exactly the planned residue - the appdata donation line (1 - deleted by the pass below),
the `blob/stable/docs/CLI.md`
link in `packages/popopx-chat-client/typescript/README.md` (1), the quoted download log in `mcp/PLAN.md` (2),
the upstream release tags in `metainfo.xml` (2) and the root `README.md` (8, with #62 - that 8 is now 4,
because the following pass rewrote the build badge and deleted the two release-feed links). Gates unchanged:
sweep 0, pairs 0/0/0/0 over 127 scanned, audit FORWARD 0 / REVERSE 0 / BARE 16, dead-link gate 1.
Nothing renders these fields, so no snapshot, build or archive is affected - static verification only.

**One inconsistency surfaced, and is left for ruling.** The two AppStream files now disagree about where
to translate: the desktop `appdata.xml` points at our README anchor, which resolves, while
`scripts/flatpak/com.popopxchat.popopx.metainfo.xml:952` still points at
`https://popopx.chat/docs/translations`, which measures **404** (`/docs` too; `/` is 200). That value was
moved to our host by the display-host tier, so the 404 is our own missing page rather than upstream
residue - the same class as #61's `popopx.chat/blog/…` links, and it closes when the site has a docs tree,
not with another text move. The metainfo `donation` (`opencollective.com/simplex-chat`) and the appdata
`donation` were untouched at that moment, still awaiting the donation ruling - it came the same day, and
both `<url type="donation">` elements were deleted: see the next section.

### The front page stops recruiting, funding or identifying for SimpleX Chat Ltd (2026-11-13)

`README.md` 10 inserted / 19 deleted, plus one `<url type="donation">` line out of each AppStream file.
One label test did all the work: **a first-person label whose destination is upstream's account, feed or
wallet is a claim this fork cannot make.**

- **Deleted, because there is nothing to substitute.** The F-Droid button (`app.simplex.chat` = upstream's
  APK repo, under their id, and this fork publishes no APK) and the TestFlight badge + its bullet
  (`testflight.apple.com/join/DWuT2LQu` = upstream's beta group, capped at 10,000) - 2 badges ×2 blocks +
  1 bullet, each removed together with the `&nbsp;` separator that followed it, or the row would have
  rendered as two paragraphs. The downloads and release badges went for the same reason: measured, our own
  equivalents answer **"no releases"** and **"no releases found"** until #56 publishes something.
- **`rel="me"` is not a link.** `README.md:17` asserted to Mastodon's verified-links machinery that this
  page *is* the web identity of `@simplex` - the same protocol-level claim as a `.well-known` file, on our
  host, about another company's account. The element went whole, because "Follow on Mastodon" under our
  badges would still read as ours.
- **The build badge moved rather than went**: `…/popopx-chat/popopx-chat/actions/workflows/build.yml/badge.svg?branch=master`
  measured 200 and describes *this* repository's CI. `branch=master` because our remote has one branch.
- **N1a: the AppStream donation URL was deleted, not relabelled.** `<url type="donation">` has **no label
  slot** - every store renders it as "support this application", and the application described is POPOPX.
  `appdata.xml:55` (upstream's README anchor) and `metainfo.xml:951` (`opencollective.com/simplex-chat`)
  therefore cannot be made true by wording. Verified 0 readers of the element in this repository.
- **N2a: the donation section was relabelled and its text left verbatim.** Heading
  `## Please support us with your donations` → `## Donate to the upstream project`, with a framing line
  naming SimpleX Chat Ltd as the author ("the \"we\" and \"us\" in them are upstream"). The five
  paragraphs, all nine wallets and `donate.simplexchat.eth` are unchanged - it is upstream's own copy,
  signed by upstream's founder, and rewriting their prose would fight the next upstream re-sync for no
  attribution gain. This follows the Wefunder block at `:18-19`, which already did exactly this.
  The anchor moved with the heading; its referrers were measured as **2** (`README.md:34` and the
  `appdata.xml` donation line, which N1a deletes), and `## Contents` does not list the section, so nothing
  else needed the new slug.

Verified: the new anchor re-derived from the new heading by the same algorithm as the A2 heading pass
(`donate-to-the-upstream-project`), and every in-page `](#…)` in README now matches a real heading; both
XML documents still parse (appdata url types `bugtracker/contact/homepage/translate`, metainfo
`vcs-browser/translate/faq/details/home/bugtracker`); the badge row and the bullet list came out with the
right separator counts, which is why each deletion carried its trailing newline; zero-checks on
`app.simplex.chat` (outside its two parser fixtures), `testflight.apple.com`, `rel="me"`,
`type="donation"`, `#please-support-us-with-your-donations`, `alt="SimpleX logo"`,
`simplex-chat/simplex-chat/actions/workflows/build.yml` and the subreddit badge = **0 each**.
Gates unchanged: sweep 0, pairs 0/0/0/0, audit FORWARD 0 / REVERSE 0 / BARE 16, dead-link 1.

**The gap that this pass exposed, and what it now owes a ruling.** The hero alt (`alt="SimpleX logo"`)
was fixed because the file behind it was redrawn by `9c8df8f09` - the alt had simply never followed the
artwork. But my 必改 list was built by grepping the *badge strings* rather than the *class*, and the class
grep (`reddit.com/r/SimpleXChat`, `twitter.com/SimpleXChat`, `mastodon.social/@simplex`) found the three
holders below, none of which this pass touched because none of them were in the ruled set:

- `src/Popopx/Chat/Help.hs:55-57` - the CLI's first-run welcome: **"Follow our updates:"** then
  `reddit.com/r/SimpleXChat/` and `twitter.com/SimpleXChat`. Same file, adjacent lines already say
  "Thank you for installing POPOPX Chat", so the first person is ours and the destinations are theirs.
  **The cost claimed here was wrong and is retracted:** it was written as "a compiled core string, so the
  shipped iOS archives keep the old text until the next archive rebuild", but measured afterwards the
  `Help` module is **not linked into the iOS archives at all** - `ar -t` on the device slice lists no Help
  object, and both Help-only strings ("Follow our updates", "Thank you for installing") read 0 there while
  the control from `Library/Internal.hs` (`smp6.simplex.im`) reads 6. The welcome is CLI-only: the cost was
  `cabal build`, nothing more, and no archive rebuild and no snapshot re-render were ever owed for it.
- `README.md:79-81` "**We publish our updates and releases via:**" with five upstream accounts (Reddit,
  Twitter, Lemmy `c/simplex`, Mastodon `@simplex`, Nostr), and
  `fastlane/metadata/android/en-US/full_description.txt:24-25` - "Follow us on" the same three accounts,
  plus a `simplex.chat/contact#…` group link that joins **upstream's user group** from the listing of our
  app. Measured holders: Reddit 3 lines / 3 occurrences, Twitter 3 / 3, Mastodon 2 / 2, Lemmy 1 / 1,
  Nostr 1 / 1.

All three are the identical misattribution as the badges, so leaving them would have been an inconsistency
this file should not hide - they are executed in the section below. `fastlane/…/images/` (icon + 8
screenshots) was checked rather than assumed: `9c8df8f09` already redrew them, so the F-Droid artwork is
ours and only its text is at issue. Root `README.md`'s upstream-repo links went 8 → 4 as a side effect (the
two rewritten build URLs and the two deleted release links); the 4 left are the AGPL attribution at `:2`,
the two `docs/lang/{cs,fr}` links that belong to the weblate class (H), and upstream's `TRADEMARK.md`, which
governs *their* mark and is correct.

### The remaining first-person labels that pointed at upstream's accounts went, or were attributed

Ruling: `执行 A B C D + F删 + E/G/H hold`. This section is the A/B/C/D half plus where the holds are
recorded; the news entry point (F) is its own commit below, because it was the part expected to carry a
snapshot cost - and measured, it carries none.

The class is **a first-person label whose destination is an account, feed or contact that SimpleX Chat Ltd
operates**. Where the text carries a label slot the label moves to whoever owns the destination; where the
sentence exists only to advertise a destination that is not ours, the sentence goes.

- `README.md:77-83` - "We publish our updates and releases via:" over their Reddit, Twitter, Lemmy
  `c/simplex`, Mastodon `@simplex` and Nostr. The heading became `## Follow the upstream project's updates`
  and the lead-in names SimpleX Chat Ltd; the five accounts stay, because with the attribution they are
  true. A heading is an anchor, so the one in-page referrer (`README.md:28`) moved with it - the new slug
  was **derived** by the same algorithm as the A2 and donation-heading passes and asserted against the
  written link, not guessed. The "POPOPX Chat team profile" bullet went: it pointed at the contact that the
  next bullet re-attributes, and it is not a channel anyone publishes updates on. The "mailing list" bullet
  went too, for a measured reason rather than an editorial one: `https://popopx.chat/#join-simplex` is a
  **dead anchor** - the hosted homepage is a single 18 KB `index.html` whose only `id` is `langDropdown`,
  and `join-simplex` appears nowhere in it (`grep -c` = 0), so a sentence about where this fork announces
  things cannot point there. It now points at `CHANGELOG.md`, which is in this repository and is the
  only release narration that exists today; the site-side anchor belongs to item #61.
- `README.md:50/56/58` - "via **our** SimpleX address", "**We** are replying the questions manually … up to
  24 hours", "joining **our** team". That address is the same `smp6.simplex.im/a#lrdvu2d8…` contact the app
  opens for "Send questions and ideas", so the front page was promising *our* turnaround for messages that
  arrive at SimpleX Chat Ltd. The paragraph now says whose team answers, that nothing sent there reaches
  this repository, and routes anything about the fork itself to `github.com/popopx-chat/popopx-chat/issues` -
  the one destination that is both ours and live. `chat@popopx.chat` was deliberately **not** added to the
  front page: FORK.md's first open item records that it is not yet reachable, and an unreachable route in
  place of a wrong one is not a fix.
- `fastlane/metadata/android/en-US/full_description.txt:24-25` - "Follow us on" their Mastodon, Twitter and
  Reddit, and "Once you install SimpleX Chat, join the group of users via this link": a store listing that
  recruited for their social accounts and joined **their** user group from the page of **our** app. Both
  sentences are deleted rather than re-worded (the second carries a percent-encoded
  `simplex.chat/contact#…` group payload, so re-hosting the text would still open upstream's group). The
  mailto subject in the sentence that stays became "POPOPX Chat on F-Droid".
- `src/Popopx/Chat/Help.hs:55-57` - the CLI welcome's "Follow our updates:" with their Reddit and Twitter
  lines, deleted together with the blank line that separated the block.

Held, reason written at each holder as `HOLD (task #66)` - 4 sites, no line numbers quoted because the
notes themselves shifted them: `popopxTeamURL`
(`apps/ios/Shared/Views/UserSettings/SettingsView.swift`), `popopxTeamUri`
(`…/usersettings/SettingsView.kt`), `ChatHelp.swift`'s "connect to POPOPX Chat developers." and
`Help.hs`'s "Connect to POPOPX Chat developers … type /simplex". They name **our** developers and reach
SimpleX Chat Ltd's contact; the only honest fix is to mint our own, which first needs a relay that POPOPX
operates. Re-wording the 31 localized values of `you_can_connect_to_popopx_chat_founder` (`base` plus 30
locales - re-counted here; the plan said 32) and the iOS catalogs now, only to move them back with the
value, would churn the translations twice - so value and labels move together, later.
`adminContactReq` already carried this ruling in a comment; the four new notes point at it rather than
repeating it. The other string in that paragraph, `follow_popopx_network_news`, did not get held: the row
it labels was deleted instead (F, below), which is why it is absent from the 7 moko locale files, the 4
`.lproj` catalogs and the 5 `.xcloc` units rather than re-worded.

Verified: `cabal build lib:popopx-chat`; the new anchor re-derived from the new heading and asserted equal
to the referrer that was written; zero-checks outside the record files on "We publish our updates",
`#follow-our-updates`, "via our [SimpleX address]", "We are replying the questions manually", "in joining
our team, please get in touch", `"Follow our updates:"`, `> Reddit: https://www.reddit.com/r/SimpleXChat/`,
`> Twitter: https://twitter.com/SimpleXChat`, `<p>Follow us on Mastodon (`, `<p>Once you install SimpleX
Chat, join the group` and `subject=SimpleX Chat on F-Droid` = **0 each**; the Mastodon/Lemmy/Nostr/Reddit/
Twitter URLs survive only inside the attributed README list. No CI job reads the README, the fastlane text
or the AppStream metadata, so those checks and the HTTP measurements are the whole gate; nothing in this
half is rendered, which is why it carries no snapshot cost.

Found by the same predicate after the ruling, **not** in the ruled set, awaiting one:
`README.md:62` offers upstream's directory bot (`smp4.simplex.im/a#lXUjJW5v…`); `README.md:64-68` says "The
groups below are created for the users to be able to ask questions … about **POPOPX Chat** only" over two
groups that SimpleX Chat Ltd created (`#SimpleX users group`, `#simplex-devs`), which puts a statement about
this fork in their moderators' mouths; and `full_description.txt:21-23` still says "**our** servers do not
have access to this information", "routed via **our** servers" and "send **us** any questions via the app
(connect to the team via settings!)" - a store listing that states who holds the user's data, in the first
person of a relay operator this fork is not. The privacy sentence is the one that matters.

### The settings row that subscribed this fork's users to upstream's news channel is deleted (F)

Ruling: `F删`. `popopxNewsURL` / `popopxNewsUri` are
`popopx:/c#grcfG3ulVI4Sh6ow33qBsmSk7uEy3gRSl2KkJ5ER6tA?h=smp18.simplex.im` - a broadcast channel on SimpleX
Chat Ltd's relay - drawn as "Follow POPOPX Network News" in both settings screens.

Why this one was deleted when the team contact next to it was held: the contact is a value this fork
intends to replace, so the row becomes true the day POPOPX runs a relay and mints its own address. A news
channel is not a state to re-word into - subscribing our users to another company's announcements is the
misattribution itself, and when POPOPX has its own channel that row gets written then, with its own
address. A hold here would have kept the wrong thing live and merely labelled it.

20 sites in 18 files, 51 deletions, 0 insertions: the row and the constant in
`apps/ios/Shared/Views/UserSettings/SettingsView.swift` and in
`apps/multiplatform/common/src/commonMain/kotlin/chat/popopx/common/views/usersettings/SettingsView.kt`,
then the key `follow_popopx_network_news` in the 7 moko locale files (`base`, `de`, `fr`, `hu`, `it`, `pt`,
`pt-rBR` - the plan counted 8, re-measured), the 4 `.lproj` catalogs (`fr`, `de`, `it`, `hu`) and the 5
`.xcloc` translation units (`fr`, `de`, `hu`, `it`, `en`). The destination had exactly these two holders
and no core, SDK or automation side, so removing the presentation removes it: outside the record files,
`popopxNewsURL`, `popopxNewsUri`, `follow_popopx_network_news`, `Follow POPOPX Network News` and the channel
hash `grcfG3ulVI4Sh6ow33qBsmSk7uEy3gRSl2KkJ5ER6tA` are **0 occurrences each**. `ic_bigtop_updates` keeps 13
occurrences - the imageset plus its other readers - so the image asset was not touched.

**No iOS baseline changes, which is not why I split this into its own commit.** The `large` set was
re-rendered (264 PNGs, `** TEST SUCCEEDED **`) and `scripts/ci/snapshots-compare.py` reports **264 `equal`,
0 `changed`, 0 `size`**; the controls `ChatHelp-light/dark-large` and `NetworkServersView-light-large` are
byte-identical to the committed files. The reason is structural, not a tolerance: the Contact section is
not in the settings list at all, it is the destination of the "Help & support" `NavigationLink`
(`SettingsView.swift:351`, the list body being `settingsView()` at `:327`), and the only scene that reads
this file renders `SettingsView(versionText: "7.1")` - the top level. `SettingsView` also carries no
`allSizes: true`, so its two `-large` files are the whole coverage and there is nothing else to re-render.
The desktop set is settled the same way, without rendering it: its only settings scene is
`SnapshotScene("SettingsView.PreviewSettingsLayout")` (`common/src/desktopTest/kotlin/chat/popopx/app/SnapshotTest.kt:118`),
which composes `SettingsLayout`, and the deleted row was in `HelpAndSupportView` - reached by
`showSettingsModal { HelpAndSupportView(...) }` on a tap, so it is in no snapshot tree on either platform.
Task #67 closes as no-change on that argument.

Two measurement facts that cost a round trip each: `snapshots-compare.py` derives the rendered set from
`index-*.json`, so a collection step that copies only the PNGs reports every reference as `missing` and
runs **no** pixel comparison - the first run of this pass looked like a total failure and meant "index
absent"; and `-extra-extra-extra-large.png` itself ends in `-large.png`, so a suffix count over
`References/` reads 320 where the `large` set is 264 (264 + 56 + 56 = 376 PNGs, plus `ASSETS_LICENSE.md`).

The localization catalogs were gated by the repo's own tooling rather than assumed:
`scripts/ios/localizations.py check` exits 0 with 514 pre-existing warnings (5 in code, 3 duplicate, 506
stale) and none of them names the deleted key; `check-kotlin` exits 1 with 202 placeholder problems and
109 outdated translations, all on other keys - the Weblate-lag class recorded as item H, not this pass.

### What was removed from this repository

`docs/` (592), `website/` (585), `blog/` (248) and `plans/` (229) — 1654 files — are deleted: upstream's
protocol and product documentation, its announcements and roadmap notes, and the simplex.chat site
front-end. They are SimpleX Chat Ltd's editorial content about SimpleX Chat, and this fork publishes no
site from this tree (`popopx.chat` is built and published elsewhere). The one fork-authored file inside
them, `docs/TRADEMARK-POPOPX.md`, was moved out first and is now `TRADEMARK-POPOPX.md` at the root, and
the notices that cited upstream's `docs/TRADEMARK.md` now cite it where it lives instead of at a deleted
path. What the removal took with it: the six `website/src/.well-known/` files, which were never served
from here but were the only copy of the Android/iOS association work in this tree — serving them now means
authoring them in the site's own repository. `.github/workflows/web.yml` was deleted with them: its build
step ran `./website/web.sh` and its Deploy step was gated to upstream's repository name, so from this
repository it could only ever go red, and the five members of the `website` CI scope went with it
(`build.yml` PR paths, `SCOPE_CHANGES` in `scripts/ci/packages_release.py`, `scripts/ci/scope-tests.sh`,
its test, and the `#### website` section of `scripts/ci/README.md`). `assets/` was deliberately
**not** removed although it was named in the same ruling: it is a gradle build input
(`-Ppopopx.assets.dir`, checked by `verifyPopopxAssets`), so deleting it would change the artwork
compiled into the Android and desktop apps rather than trim a folder.

`README.md` was repaired in the same pass — 81 lines removed, 25 rewritten, and **0** relative links into
`docs/`, `blog/`, `website/` or `plans/` survive the change (measured). What went: the whole
`News and updates` blog list (15 links) and the `User guide` section, the translated-README row, and the
`popopx.chat` sub-path pointers that 404 on our own host (`/blog/`, `/feed.rss`, `/llms.txt`,
`/llms/agents.md`, `/docs/simplex.md`, `/why.md`). Sentences that carried only a dead pointer were deleted;
sentences that carried information were de-linked; the two protocol references that still have a live
target now name the `protocol/` documents of `popopxmq` (`popopx-messaging.md`, `agent-protocol.md`,
`xftp.md`, `pqdr.md`). Two rewrites are copy, not link surgery, and are listed for review: the FAQ item
whose answer was only a blog link was dropped and its list renumbered, and "Security contact" now says the
fork publishes no security policy yet and points at the in-app team contact (upstream's `docs/SECURITY.md`
describes *their* intake process and is not ours to claim).
`packages/popopx-chat-nodejs/README.md`'s `./docs/*.md` links were left alone — they
are package-relative typedoc files, not the root `docs/`.

The citations the removal left behind were then swept: **26 files / 178 occurrences** named a deleted path
(`README.md` excluded, repaired above). Each was fixed by what it actually refers to, not by one rule. The
badge service's wire protocol had no specification left in the fork, so this fork **wrote one** —
`apps/popopx-badge-service/protocol/badges-rpc.md`, derived from the implementation with a file:line for every
spelling, covering only the RPC layer because the HTTP checkout is already documented in the service README.
Its eight readers were repointed with it (`README.md` ×3, `src/Popopx/Chat/Badges/Ledger.hs:182`,
`src/Popopx/Chat/Library/Commands.hs:6363`, `tests/BadgeTests.hs:949` and `:1072`, and the `#commands` anchor
line 284 uses). Citations to documents that are upstream's and that this fork will never publish
(the `plans/badges-codes/*` designs, `docs/CONTRIBUTING.md`, `docs/rfcs/2026-03-28-group-identity-binding.md`,
`docs/protocol/badges-rpc.schema.json`) now name `simplex-chat@db0768c21` — the commit this fork imported from,
in which each blob is verified to exist here — rather than a branch that can move or a local path that is gone.
Two live instructions were moved into the fork instead: `apps/ios/CODE.md` and `apps/multiplatform/CODE.md`
required plans to be stored in the root `plans/`, and they now require `apps/ios/plans/` and
`apps/multiplatform/plans/`, the convention `apps/popopx-support-bot/plans/` already uses. `CLAUDE.md` was
deleted (its four `@`-imports pointed at three deleted files, nothing referenced it, and the fork does not use
it). `scripts/docs/frame-guide-images.py` was deleted with the directory: it wrote into `docs/guide/images`,
had no CI consumer, and its sibling `scripts/docs/frame-ios-renders.py` is not in this repository. 25 inert
`website/**` patterns and their 7 orphaned comments left `.gitignore` (measured: 0 tracked paths matched them).
The two items that sweep deliberately left for a ruling are ruled and executed. `PRIVACY-POPOPX.md` no
longer cites deleted local paths: upstream's `docs/SIMPLEX.md` and `docs/SECURITY.md` are published
**byte-for-byte** in the fork's site directory — `popopx.chat/docs/SIMPLEX.md` (9356 bytes, blob
`e24275d6`) and `popopx.chat/docs/SECURITY.md` (6633, blob `73c050c1`), each `cmp`-verified against
`db0768c21` — beside `docs/UPSTREAM-DISCLAIMER.md`, which states what they are: upstream's texts, not
POPOPX's, carrying SimpleX Chat Ltd's report address `chat@simplex.chat` and its OpenPGP fingerprint, with
internal links (`/docs/lang/…`, `../blog/…`) that resolve upstream and not here. `PRIVACY-POPOPX.md` cites
those URLs and keeps the fact visible that **POPOPX publishes no security policy of its own** and that a
POPOPX report goes to `chat@popopx.chat`. Nothing in this repository deploys that directory — it is not a
checkout of anything here — so the two paths 404 until the fork's host serves them, the same pending item
as the certificate SAN and the `.well-known` files (`FORK.md`); the citation is therefore also given
against the pinned upstream blob, which is verifiable today.
`AGPL-COMPLIANCE.md` was **re-measured, not relinked** — its four figures are claims about this tree:
`simplexChatCore` 37 → **32 occurrences / 15 files**, `simplex-chat-nodejs` 17 → **23** (4 of them the
`-<platform>` asset name), `simplex-chat-libs` 100 → **6** (2 asset names), "322 tracked paths whose name
contains simplex" → **67**. The last one changed *class*, which is why the file now says so: 250 of the 322
were `website/`, `plans/`, `docs/` and blog paths that the removal took, so what survives is 20 package
paths (the Python module `src/simplex_chat/**`, whose declared name `simplex-chat` is rewritten at publish
time by `packages_release.py test-names`), 21 under `apps/` (13 Kotlin type/file names, the 4 desktop
launcher artifacts wired in `desktop/build.gradle.kts:68,73,82`, 2 snapshot baselines, 2 jest mocks), 24
artwork files and 2 scripts — and those 24 were provenance-checked as well: **all** are POPOPX bytes (11
differ from the same path in `db0768c21`, 13 have no upstream counterpart), i.e. our pictures under
upstream filenames, which is trademark ruling #43 rather than an AGPL item. The §3 blocker naming
`website/src/img/**` and "the 93 tracked files under `assets/**`" closed with measurements: `assets/**` is
now 89 tracked files, and of the 103 tracked files under `assets/**` plus root `images/**` exactly **4**
still carry upstream's bytes — `assets/ASSETS_LICENSE.md` (a notice, kept) and the 3 third-party audit
logos that `README.md:26` links, none of them a SimpleX mark.

**A second class the citation sweep could not see: markdown links.** 17 links in 4 files still pointed
into `docs/` and `blog/` - `PRIVACY.md` ×12, `apps/popopx-directory-service/README.md` ×3,
`bots/README.md` ×1, `media-logos/README.md` ×1. They survived the 26-file sweep because that pass looked
for *citations* (a path named in prose, retargetable at a pinned upstream blob) and these are link
targets, and `PRIVACY.md` was in the held-as-records list. Attributed before touching them: resolving
every relative link in 202 tracked `.md` files against **both** trees gives 17/17 broken here and 0/17
broken upstream, so all 17 are ours to repair, not inherited. Ruled per kind, not per file: **9
de-linked** - the seven terminology links (`/docs/GLOSSARY.md`, `/docs/DIRECTORY.md`), `bots/README.md`'s
"POPOPX Chat CLI" and `media-logos/README.md`'s "blog posts"; the sentence and its claim stay, only the
dead pointer goes. **4 sentences deleted** - the ones whose whole purpose was to point at something *SimpleX
Chat Ltd published* (two Trail of Bits announcements, the iOS push-notification post, the transparency
report), because that promise is not ours to restate without its source; the seventeenth, the
reproduce-builds sentence at `PRIVACY.md:189`, had already gone in `687f7273f`. **3 repointed inside `apps/popopx-directory-service/README.md`** - two to `#building` and
`#2-registering-a-group`, the sections of that same README that actually contain what they promised, and the
third ("see DIRECTORY.md for full details") to nothing, since it sat inside the section it named. Measured
after: **0** links into `docs/` or `blog/` remain, and no `### ` heading was renamed, so the two new anchors
resolve. Re-measured with the same script afterwards: 254 relative links in the 202 tracked `.md` files still
do not resolve, **0** of them into `docs/` or `blog/` - 238 are the generated `packages/*/docs/**` typedoc files
(`../util.ts#L79` targets, identically broken upstream) and 16 are prose citations, 7 of which are equally broken
in the upstream checkout. The remaining 9 are ours and were **not** in this ruling's scope, so they are recorded
rather than touched: 5 in `packages/popopx-chat-mcp/spec/*.md` still say `../../simplex-chat-nodejs/src/…` after
that package's directory moved, 2 in `apps/ios/spec/client/chat-list.md` cite `GetStakeBanner.swift`, deleted with
the operator cards, and 2 are `-?[a-z0-9]` inside a code span - a regex, not a link.

### Deliberately not changed

Upstream GitHub URLs that name something upstream — `CHANGELOG.md`, `PRIVACY.md` and the other surviving
records — copyright and attribution lines,
the asset licence files, the preset operator
that remains (SimpleX Chat) and its relay addresses, the badge service and directory hosts, the names-service
namespace prefix `simplex_domain_v1` (it is a persisted record and a wire value), the upstream
artwork that is still in the repository (545 files, measured in
`ASSETS_LICENSE.md`). The dependency references that resolve in `popopxmq`
moved instead (`FORK.md` item 7). Full list with the authority for each:
[`FORK.md`](./FORK.md).

### The library pins are now judged by who recorded them, not by who hosts them (2026-11-17, rulings 执行B + 2 选(b) 重置成我们自己的空账 + 3 版本 设置 7.1.0-beta.9.2 + 4 删掉)

`packages/popopx-chat-nodejs/src/release.ts:3` and `packages/popopx-chat-python/src/simplex_chat/_version.py:8` pin
`core-7.1.0.20` and `core-7.1.0.14` of `popopx-chat/popopx-chat-libs`. Both releases are published, every pinned digest
matches, and the bytes are upstream's — the archive in `core-7.1.0.20` carries `libHSsimplexmq-7.1.0.16` and
`SimpleXX3DH`/`SimpleXService`/`SimpleXRootRatchet` with no `POPOPX` spelling anywhere, which is why the mcp end-to-end job
reaches our broker and times out. A mirror matches its own digests, so `check-pins` could not see the difference.

- `popopx-chat-libs/releases.toml` is a comments-only file now (`2b5e7046c82a0bc20070500ff50f372fd00095ab`, blob `3294f730…`):
  no `[core.master]` row, so nothing is recorded as published here. The inherited rows stay retrievable as blob `aa35f4be…`
  (23 lines, 1030 B).
- `check-pins` also requires each pinned `core-<version>` to be recorded — `recorded_pin_problems()` (`packages_release.py:788`)
  called from `check_pins()` (`:969`). Run against the real pin files it reports `core-7.1.0.20 is not recorded…` and
  `core-7.1.0.14 is not recorded…`, and nothing once those versions are in the ledger. Add-on tags are not covered: `record` takes
  only `--types/--nodejs/--mcp/--python`, so a `nodejs-addon-<hash>` release has no ledger row to be judged against.
- The check needed a lane. It appeared once in `build.yml` (`:1817`, inside `publish`, which starts only on a planned package
  release); it is the `libs-pins` scope now (`SCOPE_CHANGES` at `packages_release.py:86`, `scripts/ci/scope-tests.sh:14-16`), so
  `Test changed scopes` runs it for any pull request touching either pin file — and those two globs joined `build.yml`'s
  `pull_request` paths, because `test_build_yml_runs_for_the_paths_of_its_builds` holds the paths list and the change tables to one set.
  A push is not path-gated, which is what the run below had to find out.
- The guard's first CI run (`43913834179`, client `master` at `75ad2ca61`, `completed/failure`) measured why that distinction matters:
  `Check changes` only narrows scopes for `pull_request` and `workflow_dispatch` (`build.yml:160`/`:165`). Its `*)` branch — every push —
  prints `haskell=true` and, when `env.release_branch` is set (`build.yml:61`: this fork's `master` and `stable`), runs
  `packages_release.py scopes` (`build.yml:172`), which emits **every** key of `SCOPE_CHANGES` (`packages_release.py:1072`). The step header
  read `SCOPES: badge-web ci-scripts libs-pins mcp` on a push that touched neither pin file. `badge-web` passed, `ci-scripts` passed
  (`Ran 94 tests … OK` on the runner's python), `libs-pins` then reported the two unrecorded releases and exited 1, and since
  `Test changed scopes` (`build.yml:733`) loops the scopes in one `shell: bash` step — which Actions runs with `-e -o pipefail` — `mcp`
  never started. The log held **0** `BROKER` lines: the guard had masked the defect it was written beside.
- Ruling C on that finding: `check_pins()` judges the pins against the ledger only once the ledger records a core release
  (`has_recorded_core()`, `packages_release.py:427`). While it records none — our state until the lane's first release — every unrecorded
  pin becomes a `::warning title=Unrecorded pin::` annotation and the scope exits 0, so `mcp` runs and reports its own failure again;
  the guard arms itself with no second edit, because arming it is what publishing our own `core-7.1.2.0` means. The success line names
  the count (`the pins match the published releases; 2 pinned core release(s) are unrecorded`) instead of claiming a clean check.
  Master stays red at `mcp`, for the original reason, until the pins move.
- C verified on the push that carried it (`43982143632` at `d361ba1a2`, `completed/failure`, one failing step — `Test changed scopes` on
  `ubuntu-22.04-x86_64 (CLI,Desktop)`): the step header read `SCOPES: badge-web ci-scripts libs-pins mcp` again, `ci-scripts` printed
  `Ran 95 tests in 0.803s` / `OK` on the runner, `libs-pins` emitted **2** `##[warning]` lines — `core-7.1.0.20` and `core-7.1.0.14`, each
  ending `- fatal as soon as the ledger records a core release` — and exited 0, and `mcp` then ran to `Tests: 11 failed, 2 passed, 13
  total`, the same summary as the preceding push `43904789237`. Count `BROKER` as occurrences (13 here, 11 there), not as failed tests;
  the summaries are identical. `macos-latest (iOS)` completed successfully in 7 steps, so the `cancelled` zero-step leg of
  `43913834179` was not this change either.
- The types package moves `7.1.0-beta.9.1` → `7.1.0-beta.9.2` because the claim gate could not be opened while the version was
  upstream's: `claim-core` → `types_problem` → `npm_released(…)`, and the registry answers **200** for `.9.1` (upstream's `beta`
  dist-tag) and **404** for `.9.2`. That held under both ledgers, so the ledger contents were never what blocked the lane.
  `popopxChatCore` already matched `popopx-chat.cabal:8` (`7.1.2.0`), and the dependents keep `^7.1.0-beta.9.1` (7 occurrences in 4
  files): they name the npm artifact upstream published, and `scope-tests.sh` installs the types source by path, not by version.
- Verified here, not only promised to CI: the suite ran on this machine after all — 95 green with ruling C, 93 in the untouched tree,
  and the runner agrees (`Ran 95 tests … OK` inside `ci-scripts` at `d361ba1a2`). Running it without python ≥ 3.11 took a
  `__future__.annotations` compile and a stand-in TOML parser, the same route used to exercise the guard against the real pin files and
  the real `releases.toml` fetched from `popopx-chat-libs`.
- Still open, in order: `secrets.NODEJS_REPO_TOKEN` (`gh secret list` for this repository is empty — the user provisions it), then the
  lane's first `core-7.1.2.0` and add-on release, then both pin files re-derived from GitHub's own asset digests in one commit, then the
  three mirror releases deleted (ruling 4) — last, so no window leaves the pins naming a 404 with no path back to green.

## 2026-11-23 — the factory presets move onto this fork's own dual-stack cluster

- **What shipped as preset:** 8 SMP hosts `smp1..8.popopx.im`, the cluster's relay node
  `relay1.popopx.im` (9 enabled rows in `Presets.hs`), 3 XFTP `xftp1/6/8.popopx.im` and 3 NTF
  `ntf1/2/3.popopx.im`. The 15 addresses came from the operator as one list; the gate is a whole-string
  comparison, not a count, and it is re-runnable:
  `grep -hoE '(smp|xftp|ntf)://[^"]+@(smp|relay|xftp|ntf)[0-9]*\.popopx\.im(,[a-z2-7]+\.onion)?(:[0-9]+)?'`
  over `src/Popopx/Chat/Operators/Presets.hs` and `src/Popopx/Chat/Library/Commands.hs`, `comm`-ed against
  column 2 of the operator's list — 15 matched, 0 extra, 0 missing. Fingerprints and `.onion` locals are
  wire values: a single changed character makes a queue address the server will not recognise, so no row
  here was retyped for style.
- **Ports were the trap.** `443` on every one of these hosts is **Caddy serving a web page**
  (`curl -I https://smp1.popopx.im/` answers `HTTP/2 502` with `server: Caddy`; `xftp1` answers
  `200 text/html`), so an open 443 with a leaf certificate is not evidence of an SMP endpoint, and the
  first reading of this cluster was wrong in exactly that way. The protocol ports are the ones the
  operator deploys: SMP **5223**, relay **5227**, XFTP **8443**, NTF **5226**. SMP rows therefore carry *no*
  port, which routes them to `defaultSMPPort = 5223` over TLS. The decision is `useTransport` at
  `popopxmq src/Popopx/Messaging/Client.hs:636-640`: an empty port with `SPSMP` takes 443 **only when**
  `web` (`= useWebPort networkConfig presetDomains srv`, `:645`), otherwise it falls through to
  `defaultTransport`, and `defaultSMPClientConfig` sets that to `(show defaultSMPPort, transport @TLS)` at
  `:518` with `defaultSMPPort = 5223` at `Transport/Client.hs:221`. `presetDomains` deliberately still lists only
  `[".simplex.im"]` (`Chat.hs:102`) — adding `.popopx.im` would rewrite every dial to 443 with the
  http/1.1 ALPN and point the whole install at Caddy. XFTP is the opposite case and needs its port
  written down: `FileTransfer/Client.hs:141` dials `usePort = if null port then "443" else port`, so a
  port-less XFTP row goes to 443 regardless of `presetDomains`.
- **The upstream rows were kept, not deleted.** 3 rows stay enabled-but-disabled
  (`disabledSimplexChatSMPServers`), 11 more move to `legacySimplexChatSMPServers`, and all of them remain
  in `allPresetServers`, which is what `shortLinkPresetServers` uses. The check is that the set of
  `smpN.simplex.im` hosts named by `git show HEAD:src/Popopx/Chat/Operators/Presets.hs` (15 hosts,
  smp4–smp19, no smp13) is still named by this file — a host dropped from that list silently makes every
  short link already issued on it unresolvable.
- **XFTP is defined here now** (`popopxXFTPServers`), because what this fork builds against does not contain
  these servers: `cabal.project:24` fetches `popopxmq` at tag `13df615df789…` (= `popopx-pin-7`), and the
  source cabal actually fetched — `dist-newstyle/src/popopxmq-*/src/Popopx/FileTransfer/Client/Presets.hs`,
  both copies — names `xftp1`–`xftp6.simplex.im` and no `popopx.im` host
  (`find dist-newstyle/src -path '*FileTransfer/Client/Presets.hs' | xargs grep -c xftp1.popopx.im` → 0).
  `defaultXFTPServers` is therefore no longer imported anywhere in `src/`. The dependency *repository* is
  out of scope here and was changing while this edit ran, so nothing below claims what its current HEAD
  contains. `chatRelays` is empty: the relay the operator listed is an SMP server identity
  (`smp://<key hash>@host`), while a chat relay is a `https://host/r#<LinkKey>` short link, and this version
  refuses relay links at `Commands.hs:4621`.
- **Signed-config ceilings raised to 10 SMP and 4 NTF** (`PopopxServerClusterConfig.swift:71,73`, mirrored
  in `server-config-mint.swift:90` and asserted at `SnapshotTests.swift:1747-1756, 2321, 2329`). The old
  ceilings of 6 and 2 were sized to the *upstream* roster; presets are compiled in so nothing broke today,
  but the channel the operator signs would have rejected its own full roster — including the TURN entries
  that are the only way credentials reach a public repository's clients without their passwords being
  published.
- **Not verified, and not claimed:** reachability of the protocol ports from this machine. `nc -z` reads
  here are unreliable (its `-G` form produced false negatives), and with plain TCP connects only
  `xftp6.popopx.im:8443` answered while the upstream `*.simplex.im` controls timed out too, so this is a
  gap in the measurement, not a finding about the cluster. Two behaviours also need an operator decision:
  `useSMP = 4` (`Chat.hs:88`) shuffles and enables a random 4 of the 9 enabled rows at first start
  (`Chat.hs:324-329`), so no specific preset including `relay1` is guaranteed active; and the group-relay
  picker lists `op.chatRelays` (`apps/ios/Shared/Views/Chat/Group/AddGroupRelayView.swift:96` — the path here
  was abbreviated and wrong, corrected when the file was re-opened on 2026-11-24), which is empty, so `relay1` is not
  selectable there until a real `/r#` LinkKey is supplied for it.

- **Correction, 2026-11-24 — three claims in this entry are superseded** by the relaunch-crash entry above,
  and one of them was simply wrong rather than merely out of date. (1) `relay1.popopx.im` is **not** an SMP
  server: it is this cluster's **chat relay** (`:5227`), which the dependency's own cluster record already
  counted as `8 SMP + 1 chat relay + 3 file + 3 notification`; the row is therefore out of
  `enabledSimplexChatSMPServers`, and the sentence here that called the operator's relay "an SMP server
  identity" was the mistake - the address on record for it was SMP-form because it was supplied that way, not
  because that is its role. (2) "9 enabled rows in `Presets.hs`" is now **8** (`smp1..8.popopx.im`), and the
  offered SMP list no longer includes the three `disabledSimplexChatSMPServers` rows either, because rows
  outside `serverDomains` are what made the app abort on the second launch. (3) The "15 addresses" census of
  `Presets.hs` + `Commands.hs` re-run with the recipe above now answers **14**; every other number in this
  entry - the ports, the `useTransport`/`usePort` reasoning, the retained upstream hosts, the signed-config
  ceilings - is untouched by the fix and still stands.

## Template for a release

The first release filled these fields above, at `v7.1.2-popopx.1`. Fields that are decided: the
publisher is **POPOPX** and the contact is **chat@popopx.chat**. The
angle-bracket fields below are per-release facts that cannot be known until a release is built and
signed, so they are left as template slots, not as open decisions.

```markdown
## vX.Y.Z — <date>

- upstream commit this build starts from: <commit>
- iOS: <App Store id / build number, signing identity and Team ID>
- Android: <applicationId suffix, signing certificate fingerprint, F-Droid or Play channel>
- servers this release presets, and whose terms the user is asked to accept: <list>
- link domain actually serving this release: `popopx.chat` — certificate SANs present
  (`popopx.chat`, `popopxchat.com`, `www.popopxchat.com`), `/.well-known/assetlinks.json` and
  `/.well-known/apple-app-site-association` reachable over HTTPS with no redirect: <yes/no>
- relay domain `popopx.im`: which hosts are listening, and their fingerprints in the presets: <list>
- every upstream-operated host still named in the build (badge contact, notification preset,
  directory, badge embed, TURN) — each replaced or left, with the reason: <list; the checklist and
  the failure mode of each is in FORK.md "Upstream-operated hosts, and how each one fails">
- publisher and contact address shipped in the app and in these files: POPOPX, chat@popopx.chat
```
