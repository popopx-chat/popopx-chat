# POPOPX Chat — privacy statement for this fork

> This file describes **this fork**. The upstream project publishes its own policy at
> [`PRIVACY.md`](./PRIVACY.md) (SimpleX Chat Ltd, "Operators Privacy Policy and Conditions of
> Use"); that text is upstream's and is kept here unmodified — see
> [FORK.md](./FORK.md).

## Who operates this build

**POPOPX** — the distributor of this fork, contact **chat@popopx.chat**.

`popopx.chat` serves this project's website: measured 2026-11-17, the domain resolves to
`43.129.4.33` and `https://popopx.chat/`, `/security/` and the two `/docs/…` pages linked below all
answer `200`. It publishes **no MX record**, so delivery to **chat@popopx.chat** is not verified.
Send the report either way, and for anything that is **not** a security report the fallback is the
issue tracker ([`popopx-chat/popopx-chat/issues`](https://github.com/popopx-chat/popopx-chat/issues),
`has_issues: true`, measured the same day). A security report has no fallback to offer: the security
policy at [`/security/`](https://popopx.chat/security/) asks reporters to stay off public channels
while a fix is unreleased, so it goes to the address and nowhere else - which means this fork
currently has **no confirmed confidential reporting path**, and closing that gap is a working mail
route or a published OpenPGP key, not more wording. The servers this fork does **not** operate are
listed below; this statement describes an application, not a service POPOPX runs.

## What the application sends, and to whom

The protocol itself carries no profile: there is no account, no phone number, no email and no
contact graph on any server. Message routing metadata is separated per connection, so no server
that the app talks to learns both who you talk to and what you say. For the protocol-level detail the
upstream design document describes, see [the platform document](https://popopx.chat/docs/simplex.html),
and for the audit history [the security policy](https://popopx.chat/security/) — upstream's texts,
disclaimed as upstream's at
[`docs/UPSTREAM-DISCLAIMER.md`](https://popopx.chat/docs/upstream-disclaimer.html). POPOPX authors no
policy of its own: four lines of the security policy are ours — its two Trail of Bits links made
absolute when the blog left this fork, its report address changed to **chat@popopx.chat**, and the
sentence telling the reader to encrypt with upstream's published key replaced by one saying **POPOPX
publishes no key for that address**. The platform document differs from upstream's by one word used
twice: its whitepaper link names the `stable` branch, not `master`. So report a POPOPX issue to
**chat@popopx.chat**, unencrypted unless you have a key from elsewhere, and read the cited assessments
as SimpleX Chat Ltd's process rather than a POPOPX claim about these builds. The text as imported is
verifiable at
`https://github.com/simplex-chat/simplex-chat/blob/f8776692dfedc27dc3e723231b2ca11e02bedd06/docs/` —
this fork's own import commit `db0768c21` carries that same tree but is not a ref in upstream's
repository, so a `blob/db0768c21` URL answers 404.

Two things a privacy statement normally has to disclose are worth stating explicitly for a fork:

- **Telemetry.** The iOS and Android builds bundle no analytics or crash-reporting SDK — no
  Firebase, Sentry, Segment or equivalent appears in the app dependency manifests — and no push
  service is used for message delivery, so a message is only ever stored on the relays the user's
  app is configured against. This is the design upstream documents too, see
  `apps/multiplatform/spec/services/notifications.md`. If a future release adds either, it goes
  here before it ships.
- **The servers the app is configured to use on first run.** These are **third parties**, listed in
  the source at `src/Popopx/Chat/Operators/Presets.hs`:

  | Operator (trade name) | Legal name in source | Domains | Consent |
  |---|---|---|---|
  | SimpleX Chat | SimpleX Chat Ltd | `simplex.im` | `conditionsAcceptance = CARequired` |

  The operator requires the user to accept *its* conditions before the app uses them. The fork
  inherits this preset unchanged; it does not have its own servers and therefore cannot offer its
  own terms in their place. `conditionsAcceptance`, the operator names and the relay addresses move
  together with whatever the distributor decides to run — never one at a time.

  Flux (InFlux Technologies Limited, `simplexonflux.com`) was a second preset operator upstream and
  **is not an operator of this fork**: it is not offered, not described, not linked from the app, and
  no traffic is configured to it on first run. Its `smp://…@smpN.simplexonflux.com` host-and-key pairs
  stay in `Presets.hs` for one reason only — previously issued short links encode the host they were
  created on, so removing them would make other people's links unresolvable.

## Data this fork holds

Nothing. This repository contains no backend for user data, no push gateway, no update server and
no telemetry collector. If POPOPX later operates the link-unfurling proxy, the badge service, the
directory, an F-Droid/APK distribution endpoint or a push gateway, each of them needs a section
here describing what it stores and for how long, before it is enabled in the app.

## Contact

**chat@popopx.chat** — security and privacy contact for this fork.

No MX record is published for `popopx.chat` - measured 2026-11-17, `dig +short MX popopx.chat` is
empty while the domain resolves and its website answers `200` - so delivery to this address is not
verified. If a report gets no acknowledgement, open an issue at
[`popopx-chat/popopx-chat/issues`](https://github.com/popopx-chat/popopx-chat/issues) instead.
`chat@simplex.chat`, which is the address upstream's files name, must not be presented as the contact
for this fork: it reaches SimpleX Chat Ltd. The two are not interchangeable, and a report sent there
about a POPOPX build is a request to a company that does not distribute it.
