# POPOPX badge service RPC

This fork's own specification of the **chat-side service RPC** of `popopx-badge-service`. It is derived from
the implementation, line by line, at the file:line cited in every table; it is not a copy of upstream's
longer document, which is upstream's
[`docs/protocol/badges-rpc.md`](https://github.com/simplex-chat/simplex-chat/blob/db0768c21/docs/protocol/badges-rpc.md)
cited at the commit this fork imported from.

The HTTP checkout (`/api/invoice`, the webhooks, the poller) is **not** specified here — this repository's
[`../README.md`](../README.md#the-checkout-endpoints) already documents it, and duplicating it would give two
files to keep in step.

## Transport

- The service is reached at a contact address the client connects to as `ConnectTarget 'CMContact`
  (`src/Popopx/Chat/Controller.hs:152`, default `src/Popopx/Chat.hs:74`). The address is created on first start
  and **does not accept contact requests**: it exists for RPC only.
- Service RPC requires the double ratchet, so the request is sent as the bytes of one JSON object on that
  contact (`src/Popopx/Chat/Library/Commands.hs:5592`, `:6229`, via `sendServiceRequestBytes` `:6383`).
- The agent verifies the signature with the sender's connection key; the service then refuses any request whose
  `purchaseKey` is not the key that signature was made against
  (`apps/popopx-badge-service/src/BadgeService/Service.hs:425`, error path `:417`).
- Version: `version` is a `Word` `VersionBadgeService`; this build sends `1` and the service accepts `1..1`
  (`src/Popopx/Chat/Badges/Service.hs:62-68`). Anything else is answered `unsupported_version`.

## JSON encoding rules

Every spelling below is produced by `aeson` derive calls, not written by hand, so changing a Haskell field
changes the wire value. The options are `taggedObjectJSON` in `popopxmq`
(`src/Popopx/Messaging/Parsers.hs:120-129`): tag key `"type"`, contents key `"data"`,
`tagSingleConstructors`, `nullaryToObject`, `omitNothingFields`, and `dropPrefix` lower-casing the first
letter (`:95-100`). Concretely, for these types:

- a **nullary** constructor is a bare tag: `{"type":"getBadgeCatalog"}` (asserted `tests/BadgeTests.hs:1086`);
- a **record** constructor carries its fields beside the tag:
  `{"type":"redeemBadgeCode","masterKey":…,"code":…}` (asserted `tests/BadgeTests.hs:1079-1088`, `:1111`);
- every type in this protocol is declared with braces, so **no message in it uses `"data"`**;
- `Maybe` fields are **omitted when absent** (`omitNothingFields`), never sent as `null`;
- field labels are the record labels verbatim in camelCase (`defaultJSON`).

The two tags that name commands and responses:
`$(JQ.deriveJSON (taggedObjectJSON $ dropPrefix "BSC") ''BadgeServiceCommand)` and
`… $ dropPrefix "BSP") ''BadgeServiceResponse)` (`src/Popopx/Chat/Badges/Service.hs:254`, `:264`).

## Envelope

`BadgeServiceRequest` (`src/Popopx/Chat/Badges/Service.hs:71-75`, derived `:256`):

```json
{ "version": 1, "purchaseKey": "<ed25519 public key, hex>", "request": { "type": "…" } }
```

`purchaseKey` is omitted for `getBadgeCatalog` and required for every other command.

## Commands

Fields from `src/Popopx/Chat/Badges/Service.hs:77-106`; the answer column from `:115-135`.

| `request.type` | fields | answers |
| --- | --- | --- |
| `getBadgeCatalog` | — | `badgeCatalog` |
| `getBadgeInvoice` | `priceId`, `offerId?`, `badgeInfo`, `paymentVia`, `upgrade?` | `badgeInvoice` |
| `redeemBadgeCode` | `masterKey`, `code` | `badgeCredential` |
| `purchaseBadge` | `masterKey`, `payment`, `upgrade?` | `badgeCredential` |
| `upgradeBadgeSubscription` | `payment`, `balance` | `badgeCredential` |
| `transferBadge` | `masterKey`, `payment` | `badgeCredential` |
| `issueBadge` | `balance` | `badgeCredential` |
| `pauseBadge` | — | `badgeCredential` |

A code carries no tier, and a store purchase states no tier either: the receipt decides it, so neither command
has a `badgeRequest` (`:85-92`). `offerId` absent means one month at the badge price (`:81`).

## Responses

| `response.type` | fields |
| --- | --- |
| `badgeCatalog` | `catalog`, `badgeStatement?` |
| `badgeInvoice` | `invoice`, `badgeType`, `months` |
| `badgeCredential` | `credential?`, `receipt?`, `statement`, `subscription?` |
| `error` | `code`, `message?`, `retryAfter?` |

`credential` is `Nothing` when `issueBadge` has no balance to issue and when `pauseBadge` has no current
credential; `receipt` is not provided for lifetime badges; `subscription` is present exactly when a store
subscription funds the purchase (`:115-135`).

## Value types

- `badgeType`: `supporter`, `legend`, `investor`, anything else decoding as `BTUnknown`
  (`src/Popopx/Chat/Badges.hs:109-118`).
- `catalog`: `{prices: [BadgePrice], offers: [BadgeOffer]}`; `BadgePrice` = `priceId`, `badgeType`,
  `monthPrice`, `currency`, `status`, `createdAt`; `BadgeOffer` = `offerId`, `priceId?`, `months`, `discount`,
  `status`, `createdAt` (`Badges/Service.hs:137-161`). `priceId` absent on an offer applies it to any price.
- `status`: `active`, `deprecated` (`disabled` is never sent — `Badges/Types.hs:79`).
  `discount`: `{"type":"freeMonths","freeMonths":n}` or `{"type":"discount","discount":pct}` (`:83-86`).
- `payment` (`ServicePayment`, `src/Popopx/Chat/PaymentService.hs:49-54`, derived `:110`):
  `apple{jws}` · `google{productId,token}` · `invoice{invoiceId}` · `receipt{receipt}`.
- `paymentVia` (`ServicePaymentMethod`, `PaymentService/Types.hs:92-95`, derived `:183`): `card{provider}` ·
  `crypto{currency}`; `provider` = `stripe` (`:86-88`), `currency` = `btc`, `xmr` (`:90-92`). The paid
  destination `ServicePaymentDestination` (`:97-107`, derived `:185`) is `card{provider,url}` ·
  `crypto{currency,address,cryptoAmount}`.
- `invoice` (`ServiceInvoice`, `PaymentService.hs:37-46`, derived `:108`): `invoiceId`, `price`, `discount?`,
  `credit?`, `amount`, `currency`, `expiresAt`, `paymentTo`.
- `statement`: `{entries: [StatementEntry], previousEntryId?}`; `previousEntryId` matches the client's asserted
  `entryId` and is absent for the full ledger (`Badges/Service.hs:163-167`). `balance` = `{lastEntry: …}` (`:169-172`).
- `StatementEntry`: `entryId`, `changeMonths`, `balanceMonths`, `balanceStartTs`, `balanceAnchorTs`,
  `balanceBadgeType`, `wasPausedSince?`, `createdAt`, `entryType` (`:174-187`). `balanceAnchorTs` is the start
  of the current run of months, so a day-of-month survives a short month.
- `entryType`: `credit{credit}` · `debit{debit}` (`:189`, derived `:244`). Credit tags `payment{invoiceId?}`,
  `code`, `charge{chargeId}`, `support`, `transferIn{fromPurchaseKey}`, `opening` (`:192-200`); debit tags
  `refund`, `upgrade{toPurchaseKey}`, `transferOut{toPurchaseKey}`, `support`, `badge`, `lapse` (`:202-210`).
  An unknown tag round-trips as `{tag, json}` instead of failing the whole statement.

## Errors

`code` is the snake_case string of `BadgeServiceErrorCode` (`src/Popopx/Chat/Badges/Types.hs:363-385`):
`bad_request`, `unsupported_version`, `unknown_purchase_key`, `unknown_offer_id`, `offer_disabled`,
`offer_mismatch`, `product_unavailable`, `payment_not_entitled`, `payment_pending`, `provider_unavailable`,
`provider_not_configured`, `rate_limited`, `code_invalid`, `code_used`, `code_expired`, `receipt_invalid`,
`receipt_used`, `transfer_limited`, `test_purchase`, `internal`, plus any unknown string passed through.

`retryAfter` is set for exactly three of them (`apps/popopx-badge-service/src/BadgeService/Service.hs:416-422`):
`payment_pending` 300, `provider_unavailable` 300, `rate_limited` 60. Every other code is terminal for that
request, and the client must not present the same purchase again on a retry timer — that distinction is what
`tests/BadgeTests.hs:949` asserts.

## Changing any of this

Renaming a record field or a constructor changes a value the *client* writes and the *service* reads, in two
processes that are built separately: the Haskell derives both ends, so nothing fails to compile. The gate is
`tests/BadgeTests.hs` (`:1073-1110`, `:1275-1332`), which asserts the literal JSON. The store tables behind it
are `sx_badge_service_`-prefixed with their own migrations table
(`apps/popopx-badge-service/src/BadgeService/Store/Migrate.hs:29-33`).
