# POPOPX Chat — the record behind the policy

> This file is the companion to **[PRIVACY.md](./PRIVACY.md)**, which is **POPOPX's own policy** for this
> application and the relays it presets. It is no longer a mirror of upstream's text: until 2026-11 the
> policy file here was SimpleX Chat Ltd's, kept unmodified because this fork had no servers of its own to
> describe. That premise is gone, so the policy was written for the reality and this file records who
> operates what, which texts remain upstream's, and the measurement each claim rests on. Upstream's own
> policy continues to exist in upstream's repository, for the servers upstream operates.

## Who operates what

**POPOPX** — the distributor of this fork — operates the entire cluster the app presets. Security and
privacy contact: **chat@popopx.chat**.

| Component | Operator | Evidence |
|---|---|---|
| SMP queues `smp1..8.popopx.im:5223` | POPOPX | `src/Popopx/Chat/Operators/Presets.hs:69-76` |
| Chat relay `relay1.popopx.im:5227` | POPOPX | `Presets.hs:105,115` |
| XFTP files `xftp1/xftp6/xftp8.popopx.im:8443` | POPOPX | `Presets.hs:91-93` |
| Notifications `ntf1..3.popopx.im:5226` | POPOPX | `src/Popopx/Chat/Library/Commands.hs:164-169` |
| STUN `stun1.popopx.im:5349` | POPOPX | `apps/ios/Shared/Views/Call/WebRTCClient.swift:93` |
| TURN `turn1.popopx.im:5349` | POPOPX | the host is a build-time constant (`apps/ios/Shared/Views/Call/WebRTCClient.swift:98`); the credentials are injected at build time from `apps/ios/Local.xcconfig`, which this repository ignores, so **no credential is shipped here** and a build without that file resolves to STUN only (`WebRTCClient.swift:113-130`) — the ICE parser has always accepted `turn:`/`turns:` (`Shared/Views/Call/WebRTC.swift:469-487`) |
| Apple App Store, APNs, StoreKit 2 | Apple | platform services, outside this fork's control |
| Google Play | Google | distribution only — Android has no Firebase/FCM in the message path |

The operator entry the app shows on the consent screen is POPOPX's own, written in `Presets.hs:17-29`:
`tradeName = "POPOPX Chat"`, `legalName = Just "POPOPX"`, `serverDomains = ["popopx.im"]`,
`conditionsAcceptance = CARequired Nothing`, `enabled = True`. Upstream's and third-party relays are not
presets of this build: `grep simplex.im Presets.hs` and `grep simplexonflux.com Presets.hs` both return
nothing. The Flux operator, which was a second preset upstream, is **not** an operator here — it is not
offered, not described, not linked, and no traffic goes to it; its host-and-key pairs were removed from
the source with the other non-POPOPX servers, which is a deliberate break with previously issued short
links rather than an oversight.

What that costs, stated once and plainly: because a relay address is part of an SMP connection, a POPOPX
relay learns the metadata described in [PRIVACY.md §2](./PRIVACY.md) — the dialing IP unless you route
elsewhere, queue identifiers, polling times, message sizes. It never learns plaintext, a profile, or a
contact graph.

## Infrastructure measurements

Re-measurable with the commands in the right-hand column; recorded 2026-11-25 and **re-measured the same
day** after the site's redirect rules were added (the earlier reading of this row said the policy paths
answered `404`; that is superseded below, and the `404`s that remain are the ones that still hold).

| Claim | Measurement |
|---|---|
| `popopx.chat` and the three portal hosts resolve | `dig +short A popopx.chat node.popopx.chat mp.popopx.chat bot.popopx.chat` → `43.129.40.33` for all four |
| The sites answer | `curl -o /dev/null -w '%{http_code}'` → `200` at each site root; `https://node.popopx.chat/badge` → `200` |
| Policy pages are **redirects into this repository**, not site content | `curl -s -o /dev/null --noproxy '*' -w '%{http_code} -> %{redirect_url}' https://popopx.chat<path>` measured 2026-11-25: `/privacy`, `/privacy/`, `/security`, `/security/` → **301 → `https://github.com/popopx-chat/popopx-chat/blob/master/PRIVACY.md`**; `/terms`, `/terms/` → **301 → `https://github.com/`** (the GitHub front page — no terms text is served anywhere, so the license is this repository's `LICENSE`); `/node`, `/docs/simplex.html`, `/docs/upstream-disclaimer.html`, `/docs`, `/.well-known/security.txt` → **404**. The policies are the files in this repository |
| No mail is accepted for the domain | `dig +short MX popopx.chat` → empty, while the domain resolves and the site answers `200` |
| "Dual-stack" means public host + onion, not IPv6 | `dig +short AAAA popopx.chat smp1.popopx.im` → empty for every host; the `.onion` half of each address is the second channel (`Presets.hs:69-76,91-93,115`, `Commands.hs:164-169`) |
| The relay hosts are separate machines | `dig +short A smp1.popopx.im` → `43.156.118.222`, `relay1.popopx.im` → `43.156.154.228` |

The earlier version of this file recorded `43.129.4.33` and marked the `/security/` and `/docs/…` pages
`200`. Both measurements are superseded by the rows above.

## Reporting: what exists and what does not

A security report has to reach an operator confidentially. Right now this fork has **an address and no
verified route to it**:

- **No MX record** is published for `popopx.chat`, so delivery to **chat@popopx.chat** is unverified —
  mail may simply never arrive, with no bounce to tell the sender.
- **No OpenPGP key** is published for that address, so a report travels unencrypted unless the reporter
  brings a key from elsewhere.
- **There is no `security.txt`** at `popopx.chat/.well-known/security.txt` (measured 404), and there is
  no `SECURITY.md` in this repository, so no policy page describes a disclosure process. The sentences in
  earlier drafts that pointed at `popopx.chat/security/` pointed at a page that no longer exists; they
  are removed here rather than re-worded around a dead link.

Closing the gap is **a working mail route, a published key and a written disclosure process** — three
pieces of infrastructure, not more wording. Until then: send to the address, and if nothing comes back
and the matter is not a vulnerability, the [issue tracker](https://github.com/popopx-chat/popopx-chat/issues)
is the fallback. `chat@simplex.chat`, which upstream's texts name, must never be presented as this fork's
contact: it reaches SimpleX Chat Ltd, a company that does not distribute these builds.

## What remains upstream's

- **The protocol, the cryptography and the core implementation** are SimpleX Chat's design. The
  assessments of them are upstream's process, and should be read as that rather than as a POPOPX claim
  about these builds: an implementation security assessment of the cryptography and networking by
  Trail of Bits in October 2022, and a cryptographic review of the protocols by Trail of Bits in July
  2024.
- **Attribution** is recorded in [NOTICE](./NOTICE), and the fork's relationship to upstream — what was
  renamed, what was rebuilt, what licence terms apply to whose artwork — is recorded in
  [FORK.md](./FORK.md). Neither is a privacy document; both are where a claim about provenance is checked.
- **Upstream's privacy policy** continues to describe upstream's services and is published there. It is
  not mirrored in this repository, and this fork's app does not use upstream's relays, so mirroring it
  would be describing a service nobody here operates.

## Telemetry

The iOS and Android builds bundle no analytics or crash-reporting SDK — no Firebase, Sentry, Segment or
equivalent appears in the app dependency manifests (`apps/ios/POPOPX.xcodeproj/project.pbxproj:3241-3297`
is the complete remote-package list) — and no push service is used **for message delivery**: on Android
there is no FCM in the path at all (`apps/multiplatform/spec/services/notifications.md:27`), and on iOS a
push only wakes the app to fetch, carrying encrypted metadata that is decrypted on the device
(`apps/ios/POPOPX NSE/NotificationService.swift:381-386,414-430`). If a future release adds either, it
belongs in [PRIVACY.md](./PRIVACY.md) before it ships, not after.

## What this fork holds

No user database, no directory, no contact graph, no analytics store, no update server, no link-unfurling
proxy, no push gateway of its own beyond the notification relays above — the badge, calculator,
broadcast-bot and directory services that once lived in this repository were deleted, not hidden. What
this fork *does* run is the relay cluster in the table at the top: queue storage, file storage and
notification delivery, all holding ciphertext and the metadata that ciphertext movement unavoidably
creates.

If POPOPX later operates a proxy, a distribution endpoint or any other service that receives a user
identifier, each one needs a section here describing what it stores and for how long — before it is
enabled in the app.
