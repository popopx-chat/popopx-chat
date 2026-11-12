# POPOPX Chat — release history of this fork

> This file records **this fork**. [`CHANGELOG.md`](./CHANGELOG.md) is upstream's release history and
> is kept unmodified; the versions below are the fork's own state, not upstream releases.

## Unreleased — as of 2026-11-12 (`b4aae6d3d`, 45 commits after the import point `db0768c21`)

Forked from `github.com/simplex-chat/simplex-chat` at `db0768c21` (2026-11-11), code version
`7.1.2.0` (`v7.1.2`). No POPOPX binaries have been published from this repository yet: the store
links, the APK/F-Droid artifacts and the website are all still upstream's or absent, so there is no
"installed version" of this fork to upgrade or downgrade.

Everything below is a **name and identity** change. Nothing in this list alters the protocol, the
cryptography or the wire format.

### Data locations — treat this as a new application

An installation that ever used a SimpleX-named build does **not** see its chats in this one, and no
migration is provided on purpose. The moved locations are the iOS bundle id / App Group / keychain
access group, the Android `applicationId`, notification-channel and preference-store ids, the
on-disk database prefixes `popopx_v1*`, the macOS `bundleID` and Windows registry capabilities, the
AppImage/AppStream ids and `.appdata.xml` filename, and the CLI/bot per-user data directory
(`~/.popopx`, `%APPDATA%\popopx`, `getAppUserDataDirectory "popopx"`).

### What the user sees

Display copy in every iOS catalogue, Kotlin/Swift string and locale, terminal output and live
documentation says POPOPX. The link namespace the app recognizes and emits is `popopx.chat`
(`.well-known`, universal links, Android `autoVerify`) — **which is inert until that domain is
owned, served and configured**, so link previews and profile/domain resolution do not work against
a domain this fork does not yet run.

### Interfaces that other code reads

The FFI library is `libpopopx` (a dual lookup for `libsimplex*` is retained); the Node/Python/Rust
SDK mirrors, the MCP tool outputs (`popopx_name`) and the `.popopx-mcp` data directory moved with
them; the SMP dependency is `github.com/popopx-chat/popopxmq`.
The npm and PyPI names in the committed manifests are upstream's on purpose: `packages_release.py
test-names` rewrites them, with `npm:` aliases for the cross-package dependencies, from the
repository variables `NPM_SCOPE` and `PYPI_PROJECT` at publish time — see
[`NODE-PACKAGES-POPOPX.md`](./NODE-PACKAGES-POPOPX.md). Environment variables that third
party tooling may set are read under both spellings (`SIMPLEX_ASSETS`/`POPOPX_ASSETS`,
`SIMPLEX_LIBS_DIR`, `SIMPLEX_ADDON_PATH`).

### Deliberately not changed

Upstream GitHub URLs, copyright and attribution lines, the asset licence files, the preset server
operators and their relay addresses, the badge service and directory hosts, the names-service
namespace prefix `simplex_domain_v1` (it is a persisted record and a wire value), and the upstream
artwork and 376 iOS snapshot baselines. Full list with the authority for each:
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
- link domain actually serving this release, with .well-known and AASA live: <domain>
- every upstream-operated host still named in the build (badge contact, notification preset,
  directory, badge embed, TURN) — each replaced or left, with the reason: <list; the checklist and
  the failure mode of each is in FORK.md "Upstream-operated hosts, and how each one fails">
- publisher and contact address shipped in the app and in these files: POPOPX, chat@popopx.chat
```
