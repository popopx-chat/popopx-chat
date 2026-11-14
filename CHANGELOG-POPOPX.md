# POPOPX Chat — release history of this fork

> This file records **this fork**. [`CHANGELOG.md`](./CHANGELOG.md) is upstream's release history and
> is kept unmodified; the versions below are the fork's own state, not upstream releases.

## Unreleased — as of 2026-11-14 (133 commits after the import point `db0768c21`)

Forked from `github.com/simplex-chat/simplex-chat` at `db0768c21` (2026-11-11), code version
`7.1.2.0` (`v7.1.2`). No POPOPX binaries have been published from this repository yet: the store
links, the APK/F-Droid artifacts and the website are all still upstream's or absent, so there is no
"installed version" of this fork to upgrade or downgrade.

Everything below is a **name and identity** change. Nothing in this list alters the protocol, the
cryptography or the wire format.

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
`GetStakeBanner|GetStakeView|getStake|GetStake|crowdfundingAvailable|Wefunder` outside `CHANGELOG-POPOPX.md` and
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
→ 0 hits outside `CHANGELOG-POPOPX.md`, `FORK.md` (record) and `packages/popopx-chat-mcp/README.md:74` (awaiting its
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
  that silently ships the default icon.
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
(`ASSETS_LICENSE-POPOPX.md`: 565 → 545). This run also shows what the class above costs: because
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
[`ASSETS_LICENSE-POPOPX.md`](./ASSETS_LICENSE-POPOPX.md): UI glyphs that are not brand marks, third-party
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
Because `popopx.chat` does not yet serve the certificate or the `.well-known` files, the apps now name a
domain that cannot answer them: universal links and `autoVerify` will not claim until the SAN covers
`popopx.chat` and our Android signing fingerprints replace upstream's three in `assetlinks.json`.
Ruled 2026-11-13 as use-first-and-record; the gap is written up in `FORK.md`.
The npm and PyPI names in the committed manifests are upstream's on purpose: `packages_release.py
test-names` rewrites them, with `npm:` aliases for the cross-package dependencies, from the
repository variables `NPM_SCOPE` and `PYPI_PROJECT` at publish time — see
[`NODE-PACKAGES-POPOPX.md`](./NODE-PACKAGES-POPOPX.md). Environment variables that third
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
`build.yml:556`, `:612`, `:638`), the CLI the container builds (`popopx-chat.cabal:607`), the two package
paths (`build-cli-deb.sh:12`, `make-deb-linux.sh:57`), and the sums directory in the workflow, which is now
read out of the script instead of written a second time. One of those was invisible to every token sweep:
`mv release/main/*imple*.AppImage` is a glob, not a word, and would have matched nothing in our build - it
now derives the file the way `build.yml:629` does.

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
appeared in our releases list as `popopx-chat-*` (`build.yml:1012`, `:1019`, `:1423`, and
`popopx-chat-ubuntu-22_04-x86_64` from the matrix at `:280`/`:281` plus the derivation at `:556`), so the
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
  `repository.url` (`:891-926`), so `bugs` ships **as committed** and belongs in the source, not in the
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
blocked by it. `packages_release.py test-names` (`:890-926`) rewrites **`name`, `repository.url`, the
`npm:` cross-package aliases and the PyPI `name`** - it touches `homepage`, `repository.directory` and
`bugs.url` not at all, so those ship exactly as committed and belong in the source. The alias hazard that
made hand-editing dangerous is narrower than it looked: `MCP_PINNED` (`:47`), `npm_key` (`:691`) and
`unreleased_pins` (`:588`) read only `name` and `dependencies`, which are the fields the generator pairs.
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
  things cannot point there. It now points at `CHANGELOG-POPOPX.md`, which is in this repository and is the
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
`AGPL-COMPLIANCE-POPOPX.md` was **re-measured, not relinked** — its four figures are claims about this tree:
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
`ASSETS_LICENSE-POPOPX.md`). The dependency references that resolve in `popopxmq`
moved instead (`FORK.md` item 7). Full list with the authority for each:
[`FORK.md`](./FORK.md).

## Template for the first real release

Fields that are decided: the publisher is **POPOPX** and the contact is **chat@popopx.chat**. The
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
