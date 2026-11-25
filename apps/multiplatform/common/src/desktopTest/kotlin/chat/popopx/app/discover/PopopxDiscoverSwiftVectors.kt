package chat.popopx.app.discover

// GROUND TRUTH FROM APPLE'S OWN CryptoKit — generated 2026-11-25, do not edit a value by hand.
//
//   /usr/bin/swift 6.4.2 (swiftlang-6.4.2.1.9, arm64-apple-macosx27.0.0) /tmp/ppx_discover_vectors.swift
//   openssl 3.6.4 `pkeyutl -verify -rawin`   — independent RFC 8032 re-verification of every pinned
//                                              signature, over BOTH candidate preimages (see below).
//
// The script signs with `Curve25519.Signing.PrivateKey.signature(for:)`, the construction
// `PopopxNodePairingOffer.decode` uses (DiscoverCatalogModels.swift:560-591): signature over the
// DECODED body bytes, self-declared 32-byte key INSIDE the body, `iat`/`exp` as unquoted seconds.
// Editing a value here turns the test from "the port agrees with the framework iOS uses" into
// "the port agrees with this file".
//
// MEASURED, and it shapes this whole file: CryptoKit's Ed25519 signing is RANDOMISED per call — a
// second run over identical bytes produced a different signature — so these strings are pinned to
// THIS run, and cross-platform byte-equality of signatures is unprovable (and irrelevant). What is
// provable is WHICH PREIMAGE counts, and the three codes separate exactly that:
//
//   GOOD            CryptoKit's signature over the JSON BODY BYTES, body declaring its own key.
//                   openssl: over_BODY=true,  over_TEXT=false.   → port must ACCEPT.
//   WRONG_PREIMAGE  the same key signing the base64url TEXT of the body instead (:570-574 read as
//                   a String and re-encoded). openssl: over_BODY=false, over_TEXT=true — a REAL
//                   signature, wrong preimage. This is the trap a port falls into by verifying
//                   `bodyPart` instead of `bodyBytes`; the strings decode identically either way.
//   WRONG_KEY       a real signature over the exact body bytes, made by a DIFFERENT key than the
//                   one the body declares. openssl: false/false against the declared key. It pins
//                   that verification happens against the key the body NAMES (:597), and that any
//                   other signer is a silent drop — the self-declared-key weakness, documented at
//                   PopopxNodePairing, visible: a wrong key never upgrades to trust.
internal object DiscoverSwiftVectors {
  /** The 32-byte Ed25519 seed handed to CryptoKit — the same seed the eco vectors pin. */
  const val ED25519_SEED_HEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

  /** The public key CryptoKit derived from it; equals Kotlin's `ed25519PublicKey(seed)` byte for byte. */
  const val ED25519_PUB_HEX = "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"

  /** CryptoKit's base64url of that key, exactly as the body declares it. */
  const val PUB_BASE64URL = "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg"

  /** The exact JSON body that was signed, UTF-8 — `iat`/`exp` in SECONDS as on the wire. */
  const val BODY_JSON =
    "{\"v\":1,\"node\":\"ppx-mac-7f3a9c21\",\"key\":\"A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg\"," +
      "\"link\":\"popopx://invite?one-time=Kf3mQ8xR2v\",\"iat\":1760000000,\"exp\":1760000900,\"once\":true}"

  const val IAT_SECONDS = 1_760_000_000L
  const val EXP_SECONDS = 1_760_000_900L

  /** The base64url body segment, shared by all three codes — only the signature differs. */
  private const val BODY_SEGMENT =
    "eyJ2IjoxLCJub2RlIjoicHB4LW1hYy03ZjNhOWMyMSIsImtleSI6IkE2RUh2X1BPRUw0ZGNOMFk1MHZBbVdmazFq" +
      "Q2JwUTFmSGR5R1pCSlZNYmciLCJsaW5rIjoicG9wb3B4Oi8vaW52aXRlP29uZS10aW1lPUtmM21ROHhSMnYiLCJpYXQiOjE3" +
      "NjAwMDAwMDAsImV4cCI6MTc2MDAwMDkwMCwib25jZSI6dHJ1ZX0"

  /** The accepted offer: `PPXNODE1-<body>.<signature over the BODY BYTES>`. */
  const val GOOD_OFFER =
    "PPXNODE1-$BODY_SEGMENT.0adm7o878GB3j9tFJSaC1zZRzgphHtDNXPpdxHeWdDjr6dLeg-JPvrOwmW4mr0Gpwx89Y27EMFM8BJ2lwGUGCA"

  /** Same body; the signature is CryptoKit's over the base64url TEXT of the body instead. */
  const val WRONG_PREIMAGE_OFFER =
    "PPXNODE1-$BODY_SEGMENT.ZTasY6zUprso0kNch_-xiTOOZSzE6N8DIu3xoWHeXrLXBwUvTRbrqDNmDoP3p6XYLIIfyStpBNijFu0PUaPHBg"

  /** Same body, signed over those exact bytes by a key the body does NOT declare. */
  const val WRONG_KEY_OFFER =
    "PPXNODE1-$BODY_SEGMENT.FMnKb4_xYASd1765Fdm3W7JQLZutedeQieK9xvoO0Td0vxLapg215Rfay360cgsjqPjHOAE8S-KuUToBggOlAQ"

  /** `shortDigest(GOOD_OFFER)`: first 8 SHA-256 bytes of the code's UTF-8, lower hex. */
  const val GOOD_FINGERPRINT = "68217b992faa5332"
}
