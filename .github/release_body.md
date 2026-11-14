POPOPX Chat 7.1.2 — the first release from this repository.

POPOPX Chat is a fork of SimpleX Chat 7.1.2 (upstream tag `v7.1.2`, commit `50a575e44`), redistributed under the same AGPL-3.0 licence. SimpleX Chat and SimpleX Chat Ltd are the authors of the upstream project; the POPOPX name, identifiers, domain and artwork are ours.

## What POPOPX changes

- **Its own application identity.** Bundle and package ids, app groups, keychain and preference namespaces, the database namespace and the update channel all belong to POPOPX. This is a new application: it does not read, import or share state with any other chat app, and no migration path is offered.
- **`popopx.chat`** as its link and website domain.
- **Removed features:** the crowdfunding and promotion surfaces, and the in-app blog links.
- **Redrawn artwork:** application icons, illustrations and store images made for POPOPX.
- The protocol, the encryption and the relay behaviour are upstream's and unchanged.

## Binaries in this release

Built by this repository's CI from the tagged commit:

| Platform | Assets |
| --- | --- |
| Linux (Ubuntu 22.04, x86_64) | `popopx-chat-ubuntu-22_04-x86_64`, `popopx-chat-ubuntu-22_04-x86_64.deb`, `popopx-desktop-ubuntu-22_04-x86_64.deb`, `popopx-desktop-x86_64.AppImage` |
| Linux (Ubuntu 24.04, x86_64) | `popopx-chat-ubuntu-24_04-x86_64`, `popopx-chat-ubuntu-24_04-x86_64.deb`, `popopx-desktop-ubuntu-24_04-x86_64.deb` |
| Linux (Ubuntu 22.04, aarch64) | `popopx-chat-ubuntu-22_04-aarch64`, `popopx-chat-ubuntu-22_04-aarch64.deb`, `popopx-desktop-ubuntu-22_04-aarch64.deb`, `popopx-desktop-aarch64.AppImage` |
| Linux (Ubuntu 24.04, aarch64) | `popopx-chat-ubuntu-24_04-aarch64`, `popopx-chat-ubuntu-24_04-aarch64.deb`, `popopx-desktop-ubuntu-24_04-aarch64.deb` |
| Windows (x86_64) | `popopx-chat-windows-x86-64`, `popopx-desktop-windows-x86_64.msi` |
| macOS (aarch64, x86_64) | `popopx-chat-macos-aarch64`, `popopx-chat-macos-x86-64` — command line only |

The AppImage is built once per architecture, from the 22.04 leg, so its name carries no Ubuntu version.

The SHA-256 of each asset is appended below by the build that produced it.

Not published in this release: the macOS `.dmg` (it needs a Developer ID signing and notarization credential that this repository does not have configured yet), Android APKs, and iOS builds.

## Known limits

- **Relays.** The built-in SMP and XFTP servers are still the ones operated by SimpleX Chat Ltd, and `simplex.im` still appears in the shipped server configuration, until POPOPX operates its own relays. Nothing about how a message is routed has changed.
- **Link verification on mobile.** `https://popopx.chat/.well-known/apple-app-site-association` and `https://popopx.chat/.well-known/assetlinks.json` are not served yet, so tapping an invite link does not open the app automatically.
- **In-app updates on desktop.** This tag is `v7.1.2-popopx.1`, and the updater's version grammar reads the `-popopx.1` label as a pre-release, so the stable update channel will not offer it; only the beta channel will.
