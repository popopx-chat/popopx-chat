# POPOPX Chat — privacy statement for this fork

> This file describes **this fork**. The upstream project publishes its own policy at
> [`PRIVACY.md`](./PRIVACY.md) (SimpleX Chat Ltd, "Operators Privacy Policy and Conditions of
> Use"); that text is upstream's and is kept here unmodified — see
> [FORK.md](./FORK.md). Anything marked `[FILL]` below is a decision the distributor of this
> build still has to make; nothing here asserts a fact about an entity that has not been named.

## Who operates this build

`[FILL]` — legal entity (or "an individual acting in their own name") that publishes POPOPX Chat,
the jurisdiction it is in, and the contact address users can write to. Until this is filled, this
fork does not claim to operate any service and no service address is advertised by it.

## What the application sends, and to whom

The protocol itself carries no profile: there is no account, no phone number, no email and no
contact graph on any server. Message routing metadata is separated per connection, so no server
that the app talks to learns both who you talk to and what you say. For the protocol-level detail
the upstream design document describes, see [`docs/SIMPLEX.md`](./docs/SIMPLEX.md) and
[`docs/SECURITY.md`](./docs/SECURITY.md) — both are upstream's text, kept unmodified here.

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
  | Flux | InFlux Technologies Limited | `simplexonflux.com` | `conditionsAcceptance = CARequired` |

  Both require the user to accept *their* conditions before the app uses them. The fork inherits
  these presets unchanged; it does not have its own servers and therefore cannot offer its own
  terms in their place. `conditionsAcceptance`, the operator names and the relay addresses move
  together with whatever the distributor decides to run — never one at a time.

## Data this fork holds

Nothing. This repository contains no backend for user data, no push gateway, no update server and
no telemetry collector. `[FILL]` — if POPOPX later operates the link-unfurling proxy, the badge
service, the directory, an F-Droid/APK distribution endpoint or a push gateway, each of them needs
a section here describing what it stores and for how long, before it is enabled in the app.

## Contact

`[FILL]` — security and privacy contact address. Until then, `chat@simplex.chat` (which appears in
upstream's files) must not be presented as the contact for this fork: it reaches SimpleX Chat Ltd.
