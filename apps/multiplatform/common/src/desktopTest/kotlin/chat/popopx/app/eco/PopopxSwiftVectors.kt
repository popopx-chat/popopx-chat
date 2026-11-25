package chat.popopx.app.eco

// GROUND TRUTH FROM APPLE'S OWN CryptoKit — generated 2026-11-25, do not edit a value by hand.
//
//   /usr/bin/swift 6.4.2 (swiftlang-6.4.2.1.9, arm64-apple-macosx27.0.0) /tmp/ppx_vectors.swift
//   jdk-17.0.13+11 + bcprov-jdk18on-1.79     /tmp/Vec.java        (the KOTLIN_* values below)
//   /usr/bin/swift 6.4.2                     /tmp/ppx_reverse.swift (iOS verifying BC's output)
//
// The script transcribes the byte constructions of ChannelKeyRotationManager.swift:134-203,
// PopopxH5Launcher.swift:130-141 and PopopxBadgeCreditsModels.swift:1565-1578. Editing a value here turns
// the test from "the port agrees with the framework iOS uses" into "the port agrees with this file".
//
// MEASURED, and the reason two directions are pinned instead of one: CryptoKit's Ed25519 signing is
// RANDOMIZED. Two runs with the same seed and the same preimage produced the same public key, the same
// AAD and the same preimage but different signatures (`gbhdjwpX…` then `jrh8N+RS…`), so Kotlin's Ed25519
// output can never be byte-compared with iOS's. What can be proved, and is: iOS accepts Kotlin's signature
// (IOS_VERIFIES_KOTLIN_ED25519 = true, and false for one flipped byte) and Kotlin accepts iOS's (see the
// envelope test). ECDSA is pinned the same way, and the P-256 public key derived from one scalar is
// byte-identical on both sides, which is what makes a self-issued credential re-verifiable.
//
// ChaCha20-Poly1305 IS comparable because the key and the nonce are fixed: the sealed box below opens
// here, and it refuses another channel id, another epoch key and a flipped tag.
internal object SwiftVectors {
  /** 32-byte Ed25519 seed given to CryptoKit; the same seed must yield the same public key on both platforms. */
  const val ED25519_SEED_HEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
  /** the public key CryptoKit derived from that seed. */
  const val ED25519_PUB_HEX = "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
  /** AAD of popopx.channel.enc.v1: proto|channelId|epoch|identityPub. */
  const val CHANNEL_AAD_HEX = "706f706f70782e6368616e6e656c2e656e632e76317c6368616e2e377c377c03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
  /** signed byte string: proto|channelId|epoch|nonce|ciphertext. */
  const val CHANNEL_PREIMAGE_HEX = "706f706f70782e6368616e6e656c2e656e632e76317c6368616e2e377c377c6465666768696a6b6c6d6e6f7cff899d4faac530a8fc9dca78578f0c62900bfbac2ca6360bd15171f93690776a6b9ef66b8b4286e17bf07975afa447c653f0037f8836e1e4b8a28629d5b1439cdde8ed74a7c91f025a1521c17358563d2d9fac92b492966182990756cdf6a68f605a3f03e9155c6915309293b33877b1ba6fc1979fa6578b5fd143fe396a5051889ad6d8153cffaec4c51e4ae7e9ad91e732a354292e0a3d142398"
  /** the 32-byte epoch key the box was sealed under. */
  const val EPOCH_KEY_HEX = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
  /** the fixed 12-byte nonce, standard base64. */
  const val NONCE_B64 = "ZGVmZ2hpamtsbW5v"
  /** ciphertext || tag(16), standard base64 — the wire form of `ciphertext`. */
  const val CT_TAG_B64 = "/4mdT6rFMKj8ncp4V48MYpAL+6wspjYL0VFx+TaQd2prnvZri0KG4XvweXWvpEfGU/ADf4g24eS4ooYp1bFDnN3o7XSnyR8CWhUhwXNYVj0tn6yStJKWYYKZB1bN9qaPYFo/A+kVXGkVMJKTszh3sbpvwZefpleLX9FD/jlqUFGImtbYFTz/rsTFHkrn6a2R5zKjVCkuCj0UI5g="
  /** CryptoKit's `combined` layout, kept only to show it is nonce-first and NOT what the wire carries. */
  const val COMBINED_B64 = "ZGVmZ2hpamtsbW5v/4mdT6rFMKj8ncp4V48MYpAL+6wspjYL0VFx+TaQd2prnvZri0KG4XvweXWvpEfGU/ADf4g24eS4ooYp1bFDnN3o7XSnyR8CWhUhwXNYVj0tn6yStJKWYYKZB1bN9qaPYFo/A+kVXGkVMJKTszh3sbpvwZefpleLX9FD/jlqUFGImtbYFTz/rsTFHkrn6a2R5zKjVCkuCj0UI5g="
  /** Ed25519 signature over CHANNEL_PREIMAGE, raw 64 bytes. */
  const val ED25519_SIG_B64 = "1NlsUs9NqUiiTC2zo0WtBFIicEvoTnITXo818EshpZZFBBu9G4T28BNxS+hZ0oWB6dpp/bZbyoGkfDYkSgiMCw=="
  /** the plaintext that was sealed: an epoch-secret JSON. */
  const val ENVELOPE_PLAINTEXT = "{\"epoch\":7,\"keyBase64URL\":\"yMnKy8zNzs_Q0dLT1NXW19jZ2tvc3d7f4OHi4-Tl5uc\",\"publicKeyBase64URL\":\"A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg\"}"
  /** (chan.1, epoch 0) with the separator kept. */
  const val AMBIG_WITH_SEPARATOR_HEX = "706f706f70782e6368616e6e656c2e656e632e76317c6368616e2e317c307c6465666768696a6b6c6d6e6f7cff899d4faac530a8fc9dca78578f0c62900bfbac2ca6360bd15171f93690776a6b9ef66b8b4286e17bf07975afa447c653f0037f8836e1e4b8a28629d5b1439cdde8ed74a7c91f025a1521c17358563d2d9fac92b492966182990756cdf6a68f605a3f03e9155c6915309293b33877b1ba6fc1979fa6578b5fd143fe396a5051889ad6d8153cffaec4c51e4ae7e9ad91e732a354292e0a3d142398"
  /** the same bytes as a channel literally named chan.10 would be read with, if the epoch separator were dropped. */
  const val AMBIG_WITHOUT_SEPARATOR_HEX = "706f706f70782e6368616e6e656c2e656e632e76317c6368616e2e31307c6465666768696a6b6c6d6e6f7cff899d4faac530a8fc9dca78578f0c62900bfbac2ca6360bd15171f93690776a6b9ef66b8b4286e17bf07975afa447c653f0037f8836e1e4b8a28629d5b1439cdde8ed74a7c91f025a1521c17358563d2d9fac92b492966182990756cdf6a68f605a3f03e9155c6915309293b33877b1ba6fc1979fa6578b5fd143fe396a5051889ad6d8153cffaec4c51e4ae7e9ad91e732a354292e0a3d142398"
  /** the session secret. */
  const val HMAC_KEY_HEX = "0708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20212223242526"
  /** uid=<pairwise>&ts=<unix seconds>. */
  const val HMAC_PREIMAGE = "uid=popopx1abcdefghijklmnopqrstuvwxyz&ts=1700000000"
  /** HMAC-SHA256 of HMAC_PREIMAGE, lower-case hex. */
  const val HMAC_HEX = "e1e9b4af9dc3aef8cbc910b5edfc431bdea2473fd2bf7f4dccdb1f0cf66ed351"
  /** the P-256 scalar CryptoKit generated (random per run, pinned once). */
  const val P256_PRIV_HEX = "84f02161784be3a32f5d5f7b5fe2a7cb0d9fccb7e8acbebadbb37c1bc5badc20"
  /** x9.63 uncompressed point, base64url unpadded. */
  const val P256_X963_BASE64URL = "BKumNgeKNXF5SeQp8csJZt3fMysOwkF845A8tAnGayU8Y2gcy5jVzRj31IWDyvAn9znPkQaOimwZjy5kDUjIwiw"
  /** the canonical voucher bytes that were signed. */
  const val P256_CANONICAL = "popopx|badge|PPX-BADGE-0001|3|POPOPX Founding Member|1780000000"
  /** CryptoKit's DER signature over P256_CANONICAL. */
  const val P256_DER_BASE64 = "MEQCIBLeXl0GdVohgtYYmaqfbgWuukLAicwOXdvAQ7JRUOUEAiAL1LMHmNlnaGjtgezNHTWY8FOi5k1PnWurN2rqD1/nFg=="
  /** SHA-256 of P256_CANONICAL. */
  const val P256_CANONICAL_SHA256_HEX = "1cc823a39449f8752af7c329014bbd7f4859f0f5c8b30aea4bb7f6a4456a9eeb"
  /** BouncyCastle's Ed25519 signature over the same seed and the same preimage. CryptoKit ACCEPTS it (measured below), and BC is deterministic, so this value is reproducible here. */
  const val KOTLIN_ED25519_SIG_HEX = "7245eb8843489d6431fb7833f68bd906ef12dc72545f498423a26190502f5c203463cd752b4c789f0ffbe3a835a7d96ab9d9ac10468391b389015746c938c80a"
  /** BouncyCastle's DER signature over P256_CANONICAL with P256_PRIV (RFC 6979 deterministic k). CryptoKit ACCEPTS it. */
  const val KOTLIN_ECDSA_DER_BASE64URL = "MEUCIQCOWM2RwRLItBBkekjzkNHFJuYNoL1mH4bdqnF2SsGa4AIgIT_eFOdFniTb_0OBTWUMRFym9QIh_n1MRww90RjgArI"
  /** x9.63 point derived by BouncyCastle from P256_PRIV — byte-identical to P256_X963_BASE64URL. */
  const val KOTLIN_ECDSA_X963_BASE64URL = "BKumNgeKNXF5SeQp8csJZt3fMysOwkF845A8tAnGayU8Y2gcy5jVzRj31IWDyvAn9znPkQaOimwZjy5kDUjIwiw"
}
