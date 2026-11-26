# POPOPX Chat — Privacy Policy

**Applies to:** POPOPX Chat — the application in this repository and the `popopx.im` relays it presets.
**Operator:** POPOPX, the distributor of this fork. Contact **chat@popopx.chat**.
**Last measured:** 2026-11-25. Every "verified" statement below names the file or the measurement it
rests on, so a reader with the source can re-check it without trusting this document.

POPOPX Chat is derived from SimpleX Chat; the protocol and the core implementation are upstream's, and
upstream publishes its own policy for the servers *it* operates. This document describes this fork and
its own infrastructure. See [PRIVACY-POPOPX.md](./PRIVACY-POPOPX.md) for the companion record.

## 1. What we never collect

There is nothing to hand over, because nothing is taken:

- **No phone number, no email address, no name.** The app has no registration, no sign-in and no
  verification step. No `createAccount`, SMS or email-verification call exists in the client or the
  server code presets.
- **No global user ID.** Your POPOPX address is a link to a queue on a relay. There is no directory that
  maps a person to an identifier, so there is no directory to disclose.
- **No contact list.** The address book is never read: `CNContactStore`, `ABAddressBook` and
  `NSContactsUsageDescription` do not appear in the iOS target, and the Android manifest requests no
  contacts permission. Contacts exist only in your own encrypted database.
- **No analytics, no crash reporting, no advertising SDK.** The iOS app's package dependencies are
  CodeScanner, SwiftyGif, lzstring-swift, WebRTC, Yams, ink and Elegant-Emoji-Picker
  (`apps/ios/POPOPX.xcodeproj/project.pbxproj:3241-3297`) — no Firebase, Sentry, Segment or equivalent.
  On Android there is no Firebase/FCM dependency at all: `apps/multiplatform/spec/services/notifications.md:27`
  records that background delivery uses a foreground service or WorkManager instead of push, and the
  `INSTANT` mode that would need Firebase is an enum case that the platform code never selects
  (`common/src/commonMain/kotlin/chat/popopx/common/model/PopopxAPI.kt:8731`).
- **No profile data on any server.** The protocol carries no profile to the relay. Profile names,
  preferences and the encryption state live in your database, and the peer that shares a conversation
  with you learns what you choose to send in it.

## 2. What the relays necessarily know

This is the part a privacy policy for a decentralised messenger has to state rather than wave at. When
you use a relay POPOPX operates:

- **It sees the IP address that dials it**, unless you route through a proxy or a `.onion` endpoint
  (section 5). The relay needs to reach your queue; it does not need to know who you are.
- **It sees metadata:** which queues exist on it, when a queue is polled or written to, the size of each
  encrypted message, and how many recipients a queue has. It cannot see message content, who the sender
  or recipient is, or which of your queues belong to you — unidirectional queues are separate
  connections, and the sender's relay and the recipient's relay can be different machines.
- **It holds ciphertext, never plaintext.** Message bodies are encrypted end to end before transmission.
  What the server software can persist is configurable: the SMP server holds queue records in memory or
  in a database, with an append-only store log whose option parsing defaults to enabled
  (`popopxmq src/Popopx/Messaging/Server/Main.hs:820`, `Main/Init.hs:80-85`). **The exact persistence and
  retention settings this fork's live relays run are not recorded in this repository**, because this
  repository is the client; a self-hosting operator controls those switches and owes the same disclosure
  to their users that we make here.

Nothing in section 2 is a claim of absolute anonymity against a traffic-analysis adversary. The protocol
design and the audits it describes are upstream's; where an adversary can correlate timing and volume
end to end, metadata is the exposure, and the mitigations are the ones in section 5.

## 3. What stays on your device

- **The conversation database** is SQLCipher: `direct-sqlcipher ==2.3.*` / `sqlcipher-simple ==0.4.*`
  (`popopx-chat.cabal:428-429`), and the runtime version in the built binary is SQLCipher 4.5.2 over
  SQLite 3.39.2 from `cbits/sqlite3.c`. The crypto provider is a **manual flag that defaults off** in the
  package, so encryption is a build choice, not a given: every shipped target sets it —
  `flags.commoncrypto = true` for the four Apple targets (`flake.nix:561,578,598,614`, covering the iOS
  device, iOS simulator and macOS libraries) and `flags.openssl = true` for Android and Windows
  (`flake.nix:188,220,348,426`). A build that sets neither would produce a **no-encryption** library, so
  this line is the one to re-check after any dependency or flake change.
- **The database key lives in the iOS Keychain**, not in a file: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
  in the app's keychain access group (`apps/ios/POPOPXChat/KeyChain.swift:13,120-124`; the access group
  is set in both entitlements files). "This device only" means the key is not in an iCloud Keychain
  sync, so an iCloud backup of your phone does not give a reader of that backup your messages.
- **iOS file-level protection** (`FileProtectionType.complete`, which makes a file undecryptable while
  the device is locked) is applied to: the server-configuration store
  (`Shared/Features/ServerConfigSync/PopopxServerConfigStore.swift:458-459,503-505`), compressed outgoing
  media (`MediaCompression/PopopxMediaEngine.swift:349,356,919`), the personal profile store
  (`PersonalProfile/ProfileStorageManager.swift:204-214`), the decoy profile
  (`AntiTheftDuress/PopopxDecoyProfileGenerator.swift:378-381`) and the mesh store
  (`PopopxMeshKit/.../Core/PopopxMeshStorage.swift:112`).
  **It is not applied to the SQLCipher chat database or to logs**, and the entitlements set no
  app-wide data-protection class — the database file itself (`POPOPXChat/FileUtils.swift:76` sets only
  `isExcludedFromBackup`) is protected by its cipher and its Keychain-held key rather than by the
  file-protection class. We state the gap rather than papering over it.
- **Backups:** the chat database is excluded from the device backup, so your message history is not
  sitting in an iCloud or iTunes backup you did not think about. If you want a copy you control, export
  one deliberately and protect it yourself.
- **Duress erasure** is a real deletion, not a hide: the duress passphrase path stops the chat, closes
  the store, wipes the mesh identity, deletes the databases, backups, exports, temporary and migration
  directories, wallpapers and the stored database password, removes the app/duress/mnemonic/lockout
  keychain items, and then builds a fresh profile (`AntiTheftDuress/PopopxDuressAuthManager.swift:831-905`,
  `POPOPXChat/FileUtils.swift:143-163`). The alternate strategy keeps one chosen profile and deletes the
  others including their **server queues**. The mesh panic wipe is a different tool: it clears the mesh
  keys, the mesh records and the temporary media copies this app kept unpacked or recompressed, then
  closes the app. It does not delete the chat database, so your chats, contacts and received files stay
  on the device.

## 4. Push notifications, precisely

Message delivery does not depend on a push service: a message waits in your queue until the app fetches
it. Where push is used — iOS only — it is a wake-up, not a transport:

- The notification extension reads **only** `userInfo["notificationData"]`, whose fields are `nonce` and
  `message` (`apps/ios/POPOPX NSE/NotificationService.swift:381-386`), decrypts it **on the device** with
  the local core (`:414-430`, `apiGetNtfConns`), and only then fetches the conversation.
- No message text, sender name or conversation title is in the payload that Apple's service carries, and
  the text you see on the lock screen is produced locally after that decryption.
- The notification relays that make this possible, `ntf1..3.popopx.im:5226`
  (`src/Popopx/Chat/Library/Commands.hs:164-169`), are operated by POPOPX. They hold an encrypted
  subscription token and a nonce-carrying ciphertext, not a message.
- **Android uses no push provider.** Background delivery is a foreground service or periodic
  WorkManager work (`spec/services/notifications.md:27`), so there is no Google-side hop at all.

## 5. Network identity, Tor and proxies

The relays are dual-addressed: every SMP, XFTP, NTF and chat-relay entry carries a public host **and** a
V3 `.onion` host (`Operators/Presets.hs:69-76,91-93,115`, `Commands.hs:164-169`). Using the hidden
service hides your IP from the relay's public interface, and the client exposes two switches for it on
iOS (`Shared/Views/UserSettings/NetworkAndServers/AdvancedNetworkSettings.swift:112,142,182-187,365-378`):
a SOCKS5 proxy setting and a `.onion`-preference toggle, plumbed through as `socksProxy`
(`POPOPXChat/AppGroup.swift:362,392`).

Be exact about the limits: **no Tor is bundled**. The iOS SOCKS5 path requires a proxy you provide (the
setting states "Requires compatible VPN") and is **off by default**, so an ordinary install reveals your
IP to whichever relay it dials. The CLI has the corresponding options (`src/Popopx/Chat/Options.hs:127-150`).
Anyone who tells you a messenger protects your IP "automatically" while shipping no Tor is describing a
choice you still have to make.

## 6. Calls

Calls are WebRTC. Every client that ships a bundled ICE list presets one entry, STUN only:
`stun:stun1.popopx.im:5349` (`apps/ios/Shared/Views/Call/WebRTCClient.swift:92-94`,
`packages/popopx-chat-webrtc/src/call.ts:355`,
`apps/multiplatform/common/src/commonMain/resources/assets/www/call.js:70`).

A relay exists and POPOPX operates it — `turn1.popopx.im:5349` — but its credentials are **not in this
repository**, and no build made from this source tree reaches it unless someone supplies them. iOS reads
`POPOPX_TURN_USERNAME` / `POPOPX_TURN_CREDENTIAL` from its `Info.plist`
(`apps/ios/POPOPX--iOS--Info.plist`), and those values come from `apps/ios/Local.xcconfig` — a file this
repository ignores (`apps/ios/.gitignore:74`), optionally included by `Debug.xcconfig` and
`Release.xcconfig`. The resolver refuses to build a TURN entry from a missing, empty or unexpanded `$(…)`
value rather than offer a relay that cannot authenticate (`WebRTCClient.swift:113-130`), so a clone —
including every CI build — is STUN-only. Servers you enter yourself outrank the injected relay
(`WebRTCClient.swift:144`), and the parser has always accepted `turn:` / `turns:`
(`Shared/Views/Call/WebRTC.swift:469-487`).

Routing on iOS is **peer-to-peer first**: the transport policy is `.all` unless you turn on "Force calls
through a relay" (`Shared/Views/UserSettings/SettingsView.swift:111`, applied at
`WebRTCClient.swift:208`). That toggle trades one observer for another: with the default the peer can see
your IP address, with it on the relay sees both endpoints' addresses plus the timing and volume of the
call. **The other clients do not share this default yet** — the core's `defaultAppSettings`
(`src/Popopx/Chat/AppSettings.hs:96`) and Android's stored preference
(`apps/multiplatform/common/src/commonMain/kotlin/chat/popopx/common/model/PopopxAPI.kt:122`) both still
select relay-only, which alongside a STUN-only preset means a call that cannot go direct simply fails.

Some disclosure applies to every route: a STUN request tells `stun1.popopx.im` your public address, and
ICE candidates exchange your private and public addresses **with the peer** — a party you chose to talk
to, not a third party. A relay forwards packets and never holds the media keys: media is encrypted between
the peers, and where both sides negotiated the per-call key each frame is encrypted before it reaches the
transport (`WebRTCClient.swift:163-173`), which is what the call screen reports as
"e2e encrypted" (`Shared/Views/Call/WebRTC.swift:54-63`). There is no conference service in this product:
nothing mixes, records or stores call media.

## 7. Purchases and the node badge

Badge purchases are StoreKit 2 products (`com.popopx.badge.node.*`, 13 SKUs —
`Shared/Features/BadgeCredits/PopopxStoreKitManager.swift:197-272`, `PopopxBadgeCreditsModels.swift:171-191`).
The ledger this app consults is **on your device, in the Keychain** (`PopopxBadgeManager.swift:69,136,215`),
and there is no POPOPX store service: *"taking an entitlement back across devices would need a server,
and this feature has none"* (`PopopxCreditsManager.swift:285`). Therefore:

- **POPOPX sees no purchase.** No order, no receipt, no email, no name reaches us from a purchase.
- **Apple sees the purchase**, under its own privacy policy, as the store operator — the payment record,
  your Apple account and the tax receipt are Apple's to hold, not ours.
- **Entitlements do not sync between your devices**, and a badge cannot be revoked by us or remotely
  transferred. Restoring is a reconciliation with Apple (`PopopxStoreKitManager.swift:456`).
- Because there is no server, the upstream policy's store-side retention (order keys held by a store
  service) does not describe this build, and the "7 or 21 days for files sent with a badge" behaviour
  that depends on a server credential is not what this app ships.

## 8. Third parties, named

| Who | Why they are in the path | What they can learn |
|---|---|---|
| Apple | App Store distribution, APNs wake-ups, StoreKit 2 | Your Apple account, purchase records, the push token, the size/timing of an opaque payload |
| Google | Play distribution for the Android build | Your Google account and purchase record; **no FCM in the message path** |
| POPOPX relays | Queue storage and delivery | The metadata in section 2, never plaintext |
| Your ISP / network | Carrying the traffic | That you connect to `popopx.im` hosts (unless you use the onion endpoints) |
| Certificate authority | TLS certificates | That the domains exist; the app pinning and certificate transparency are the operator's configuration |

There is no advertising network, no analytics vendor and no CDN in front of the message path.

## 9. Your choices

1. **Change or add relays** in Settings. You are not tied to POPOPX's cluster, and the addresses are
   plain `smp://<key>@<host>` strings.
2. **Route over `.onion` or your own SOCKS5 proxy** (section 5) to keep your IP from the relay.
3. **Self-host.** The same server software runs the cluster; `https://node.popopx.chat/` documents running
   it on your own Mac, and then you are the operator and this policy becomes the checklist of what to
   tell your users.
4. **Leave.** Deleting the profile removes your local data; queues on a relay age out per that relay's
   configuration, and there is no account to close because there was no account to open.

## 10. Retention

Message bodies exist in a queue until the recipient fetches them, and files exist on an XFTP relay until
retrieved or the server's configured retention removes them — the numbers are a per-relay configuration
choice in the server software, and section 2 says what we can and cannot attest for this deployment.
POPOPX holds no profile, no contact graph, no message copy outside those queues, and no analytics store,
so there is no separate retention schedule to publish for data we do not keep.

## 11. Requests, disclosure and this policy's limits

There is no user database to subpoena: no email, no phone number, no name, no contact list and no
plaintext message is held anywhere by this fork. What a request could reach is relay metadata, and only
for whatever the operating relay persisted under section 2 — which is why that section is written as a
description rather than a promise.

This policy describes the software in this repository and the relays POPOPX presets, and is revised by
commit. Changes are not announced by push, because the app has no channel that would require one: check
this file's history in the repository.

## 12. Contact

**chat@popopx.chat** for privacy and security reports. **Delivery is not verified:** `popopx.chat`
publishes no MX record (measured 2026-11-25), and no OpenPGP key is published for that address, so a
report travels unencrypted unless you bring a key. For a non-security privacy question you can also use
the [issue tracker](https://github.com/popopx-chat/popopx-chat/issues) — but never for an unreleased
vulnerability. The gap between "we have an address" and "we have a confidential reporting path" is
recorded in [PRIVACY-POPOPX.md](./PRIVACY-POPOPX.md) and is open work, not a solved problem.
