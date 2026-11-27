package chat.popopx.app.discover

//
//  PopopxNodeFeedVectors.kt
//  desktopTest
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Pinned `popopx.discover.feed.v1` envelopes, shared byte-for-byte with
//  apps/ios/PopopxMeshKit/Tests/PopopxMeshKitTests/PopopxNodeFeedVectors.swift. This file is generated
//  from that one (generator: /tmp/ppxkt/gen_vectors.py, 2026-11-27): every carrier is copied verbatim at
//  the same indentation, so Kotlin's trimIndent() strips what Swift's raw-multiline delimiter strips and
//  the two sources hold identical UTF-8. Sizes and digests below are asserted, not assumed.
//
//  What that buys: if this receiver rebuilds the same canonical bodies and opens the same signatures, the
//  two platforms agree on the wire rather than each agreeing with itself. A Kotlin serializer that escaped
//  a forward slash, normalized an accent, or sorted a key differently fails a digest before it ever reaches
//  Ed25519.
//
//  Honest provenance, because it limits what these vectors can prove (the full account is in the Swift
//  header; this file must never be read without it):
//   - Minted by a scratch script (/tmp/ppxvec/mint.swift, 2026-11-27) that transcribes the node's own
//     signing bodies verbatim — DiscoverModels.swift:226-236 and :280-301 — encoded with
//     JSONSerialization([.sortedKeys, .withoutEscapingSlashes]), signed with Curve25519.Signing, and written
//     with JSONEncoder([.prettyPrinted, .sortedKeys]) as NodeJSON.encoder(prettyPrinted: true) does
//     (MacNodeModels.swift:426-437). That is the producer's API and options, NOT the producer running.
//   - There is no real feed.json to compare against: this machine's PopopxMacNode support directory has no
//     discover/ folder, because the aggregator was never switched on here.
//   - Every signature was re-checked with OpenSSL 4.1.0 `pkeyutl -verify -rawin` against the SPKI DER of the
//     same key, independent of CryptoKit.
//   - The signing identity comes from a published literal, so the vectors can be re-minted; it is a test
//     key and guards nothing.
//   - Each carrier is the producer's file bytes with every non-ASCII scalar rewritten as a backslash-u
//     escape, so the same text can live in a Swift and a Kotlin source literal without either lexer
//     normalizing it. Decoded values, canonical bodies and signatures are unchanged.
//
//  A LEXER ASSUMPTION, therefore asserted rather than trusted: a Kotlin raw string must not decode a
//  backslash-u escape. NodeFeedVectorsTest.carriersKeepTheirEscapesLiteral is the must-be-true control. If
//  a future lexer ever did decode them, that test fails instead of the digest comparisons quietly becoming
//  self-consistency checks.
//

import chat.popopx.common.crypto.sha256Hex
import kotlin.test.Test
import kotlin.test.assertEquals

internal object NodeFeedVectors {
  /** The key `plain`, `escaping`, `unicode` and `empty` are signed by. */
  const val SIGNING_PUBLIC_KEY = "Dp7P9JZAKRp4X0hMpnC3cLi7lKbhxUpWvV6jeEoSs-o"

  /** The key `foreignKey` is actually signed by, while its envelope declares the one above. */
  const val OTHER_PUBLIC_KEY = "3-LxHV5kqjJyFYMAgP_jSerYc6db9MMHtevbRSLY1xY"

  const val GENERATED_AT = "2026-11-27T09:05:00Z"
  const val ITEM_TIMESTAMP = "2026-11-27T09:00:00Z"

  /** sha256 of the canonical bodies and of the file bytes, measured by the mint. */
  object Digest {
    /** plain fileBytes: sha256 of the producer's `feed.json` bytes */
    const val PLAIN_FILE_BYTES = "82687c06849957738cf18672ffc3af7282afd3832efb6c9cf45c53975683ff92"

    /** plain envelopeBody: sha256 of the canonical envelope signing body */
    const val PLAIN_ENVELOPE_BODY = "375d3d67c87fd14abc2b5e48a28b7123c2fd09aebbc9a3bcf88906c2b533fb42"

    /** plain itemBody: sha256 of the canonical body of the vector's first item */
    const val PLAIN_ITEM_BODY = "28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286"

    /** escaping fileBytes: sha256 of the producer's `feed.json` bytes */
    const val ESCAPING_FILE_BYTES = "c1d8e1b3962b7cfe50437006c58590c29f07c899ef053c074bc52d9af477e1d0"

    /** escaping envelopeBody: sha256 of the canonical envelope signing body */
    const val ESCAPING_ENVELOPE_BODY = "86753396a1b74e7df9c5f13ca5e4679d74c1b7700efbdf0ecab8a95ab7f73da6"

    /** escaping itemBody: sha256 of the canonical body of the vector's first item */
    const val ESCAPING_ITEM_BODY = "75009d746879c4fc86785e7f6dbcd2914d0520f0f2601766f4b9ed27576a8af9"

    /** unicode fileBytes: sha256 of the producer's `feed.json` bytes */
    const val UNICODE_FILE_BYTES = "d650ae60aea5f5d0f1bb77a602f2d692809a87ce83ed050b6453b8fc8a409307"

    /** unicode carrierBytes: sha256 of this pinned carrier (escaped non-ASCII) */
    const val UNICODE_CARRIER_BYTES = "f515c7d8395e7cde2fffbcdb8d09b568f41e3338ede9745e9e55f000eb265055"

    /** unicode envelopeBody: sha256 of the canonical envelope signing body */
    const val UNICODE_ENVELOPE_BODY = "1e79c24ef38f3febacab7b755968e9fc91a4ebd9684e5942c804df62184a240c"

    /** unicode itemBody: sha256 of the canonical body of the vector's first item */
    const val UNICODE_ITEM_BODY = "3ab5f5123068e1beed7b4c3c0b91319e4ac93b70385997787b837a3e4f96a82e"

    /** empty envelopeBody: sha256 of the canonical envelope signing body */
    const val EMPTY_ENVELOPE_BODY = "f2810eca50605341c7572c8dac1957b53ebd15c6d77ba2381d893bcc98cb579c"
  }

  /** 1220 bytes, pinned verbatim from the mint, copied from the Swift carrier of the same name. */
  val plain: String = """
        {
          "generatedAt" : "2026-11-27T09:05:00Z",
          "items" : [
            {
              "id" : "item-1",
              "link" : "https:\/\/popopx.example\/blog\/1-2-0?x=a\/b",
              "sha256" : "28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286",
              "signature" : "vYYV07D9i_H2A4fwhvh1zBVhnzpB4hbg8UyMmbCkI0DZFHNHJywgTAh2eUV524bPUnt18gslp91p_u0hBBRoBg",
              "source" : "rss",
              "sourceLabel" : "Example Blog",
              "summary" : "Changelog published.",
              "timestamp" : "2026-11-27T09:00:00Z",
              "title" : "Release notes for 1.2.0"
            },
            {
              "id" : "item-2",
              "link" : "",
              "sha256" : "411eb4aa04244c255440468e3e56220cae6c50e7782375da079b1dddb4054492",
              "signature" : "cqf_Mq2lhNbMi9y2lQGACwOLkzetFqbVPHg3gpFDYdVZ8NGAIAdTIsrKm5CvswCiW-R2edbxKgG0jFP76RfVCg",
              "source" : "folder",
              "sourceLabel" : "~\/Documents",
              "summary" : "No link travels to the phone.",
              "timestamp" : "2026-11-27T09:00:00Z",
              "title" : "Local file"
            }
          ],
          "nodeId" : "node-7f2a",
          "publicKey" : "Dp7P9JZAKRp4X0hMpnC3cLi7lKbhxUpWvV6jeEoSs-o",
          "schema" : "popopx.discover.feed.v1",
          "signature" : "3BSMU0k5e2EXPX0zu0WUSp4uY2FAHhP9bri5RK1mRtCwyp_Npbl_0n8lpOt-OivnxYedsIpM4hGXjwW4vBqLCA"
        }
        """.trimIndent()

  /** 1211 bytes, pinned verbatim from the mint, copied from the Swift carrier of the same name. */
  val escaping: String = """
        {
          "generatedAt" : "2026-11-27T09:05:00Z",
          "items" : [
            {
              "id" : "item-3",
              "link" : "https:\/\/example.invalid\/a\\b",
              "sha256" : "75009d746879c4fc86785e7f6dbcd2914d0520f0f2601766f4b9ed27576a8af9",
              "signature" : "YmY2RfMMsc2EgjkO3kE4sjwpGhlFryKjRL4eKMZ4k8mD2j-5qb1okaOkzJ_FBgdfFNYjypHShWYMk_hFZdluAg",
              "source" : "json",
              "sourceLabel" : "Ctl\u0001",
              "summary" : "tab\tnewline\nCR\rBS\bFF\fSOH\u0001",
              "timestamp" : "2026-11-27T09:00:00Z",
              "title" : "He said \"no\" \\ maybe \/ yes"
            },
            {
              "id" : "item-4",
              "link" : "",
              "sha256" : "b6f9ccd8d586709207ba457065da5fadfd38b828afd2fa4da34c5ecd919bee7f",
              "signature" : "KjGbabc4RUrzWG2O8h7qUeH37eZ8Th2I83-aZ91hrROO4hml66hcobPIOxx4vUnSYrVlmj4SGSiYvfMZ-s8fDw",
              "source" : "mcp",
              "sourceLabel" : "tool",
              "summary" : "control-only title",
              "timestamp" : "2026-11-27T09:00:00Z",
              "title" : "\t\n\r\b\f\u0001"
            }
          ],
          "nodeId" : "node-7f2a",
          "publicKey" : "Dp7P9JZAKRp4X0hMpnC3cLi7lKbhxUpWvV6jeEoSs-o",
          "schema" : "popopx.discover.feed.v1",
          "signature" : "rlMrlZVrkJ3kUwsB4mlAABZbxxnsjw99sFwLmU-jcXEzl-2ixB6NqLp1sYg771HmZGfeokmegIIAVqpTOj7pBQ"
        }
        """.trimIndent()

  /** 804 bytes, pinned verbatim from the mint, copied from the Swift carrier of the same name. */
  val unicode: String = """
        {
          "generatedAt" : "2026-11-27T09:05:00Z",
          "items" : [
            {
              "id" : "item-5",
              "link" : "https:\/\/example.invalid\/\u4E2D\u6587",
              "sha256" : "3ab5f5123068e1beed7b4c3c0b91319e4ac93b70385997787b837a3e4f96a82e",
              "signature" : "yAEPxJSuZKhSB0Byp3jpx0bUm_S3KvwGlmAmfXYGvzO8RVOHuJtmNuMotDxcBVhcYES9LIiQrYzy7VPeT0rIAQ",
              "source" : "rss",
              "sourceLabel" : "\u4FE1\u606F\u6E90",
              "summary" : "decomposed accent: e\u0301",
              "timestamp" : "2026-11-27T09:00:00Z",
              "title" : "\u4E2D\u6587 \u2028 \u007F \uD83D\uDE00"
            }
          ],
          "nodeId" : "node-7f2a",
          "publicKey" : "Dp7P9JZAKRp4X0hMpnC3cLi7lKbhxUpWvV6jeEoSs-o",
          "schema" : "popopx.discover.feed.v1",
          "signature" : "0bJ-2yLDmQUC2Xt2LJZgN9GKX3K2ARqsX05uwp9cw7qF6U8wZk86pcHMj-ckEL0Uiti5FccyVmH57sHYO21SAg"
        }
        """.trimIndent()

  /** 299 bytes, pinned verbatim from the mint, copied from the Swift carrier of the same name. */
  val empty: String = """
        {
          "generatedAt" : "2026-11-27T09:05:00Z",
          "items" : [

          ],
          "nodeId" : "node-7f2a",
          "publicKey" : "Dp7P9JZAKRp4X0hMpnC3cLi7lKbhxUpWvV6jeEoSs-o",
          "schema" : "popopx.discover.feed.v1",
          "signature" : "Dtf7nwWAEwtsj7BNRs8RzpiEXBZlbNfq3OQfaX3nFdfQNWl_fHCxCOXfo_hg9fqqjx1cFi-w4K-Zu7s8On5gCg"
        }
        """.trimIndent()

  /** 782 bytes, pinned verbatim from the mint, copied from the Swift carrier of the same name. */
  val digestDrift: String = """
        {
          "generatedAt" : "2026-11-27T09:05:00Z",
          "items" : [
            {
              "id" : "item-1",
              "link" : "https:\/\/popopx.example\/blog\/1-2-0?x=a\/b",
              "sha256" : "28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286",
              "signature" : "OEo0Cq8QT1HgHQyN0T02J3YIv1WEkvlAq727Ve4A3C7Ru7xYeF2WxdzayF3ZvJEfgN1dQNFq-FHLIWMxX5iKAw",
              "source" : "rss",
              "sourceLabel" : "Example Blog",
              "summary" : "Changelog published.!",
              "timestamp" : "2026-11-27T09:00:00Z",
              "title" : "Release notes for 1.2.0"
            }
          ],
          "nodeId" : "node-7f2a",
          "publicKey" : "Dp7P9JZAKRp4X0hMpnC3cLi7lKbhxUpWvV6jeEoSs-o",
          "schema" : "popopx.discover.feed.v1",
          "signature" : "430LKHmNDqgf-t8wNbydvUv6X46B8IlaRHA7Kh-UE-KAe5RC1_i1itEH-BpGrXqATAIlPxYPG33fNYQkFDLUAA"
        }
        """.trimIndent()

  /** 782 bytes, pinned verbatim from the mint, copied from the Swift carrier of the same name. */
  val itemSignature: String = """
        {
          "generatedAt" : "2026-11-27T09:05:00Z",
          "items" : [
            {
              "id" : "item-1",
              "link" : "https:\/\/popopx.example\/blog\/1-2-0?x=a\/b",
              "sha256" : "e4b8a72c247021ad5c82bbfe2032512b88eb8640ce62030c1d3fbd0218c438d6",
              "signature" : "OEo0Cq8QT1HgHQyN0T02J3YIv1WEkvlAq727Ve4A3C7Ru7xYeF2WxdzayF3ZvJEfgN1dQNFq-FHLIWMxX5iKAw",
              "source" : "rss",
              "sourceLabel" : "Example Blog",
              "summary" : "Changelog published.!",
              "timestamp" : "2026-11-27T09:00:00Z",
              "title" : "Release notes for 1.2.0"
            }
          ],
          "nodeId" : "node-7f2a",
          "publicKey" : "Dp7P9JZAKRp4X0hMpnC3cLi7lKbhxUpWvV6jeEoSs-o",
          "schema" : "popopx.discover.feed.v1",
          "signature" : "430LKHmNDqgf-t8wNbydvUv6X46B8IlaRHA7Kh-UE-KAe5RC1_i1itEH-BpGrXqATAIlPxYPG33fNYQkFDLUAA"
        }
        """.trimIndent()

  /** 781 bytes, pinned verbatim from the mint, copied from the Swift carrier of the same name. */
  val envelopeSignature: String = """
        {
          "generatedAt" : "2026-11-27T09:05:00Z",
          "items" : [
            {
              "id" : "item-1",
              "link" : "https:\/\/popopx.example\/blog\/1-2-0?x=a\/b",
              "sha256" : "28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286",
              "signature" : "s17uuk7DEU2R75vr7W0h0JKBElMJm3m3iFDz7ymJa7TxgNx2Yl9yAe23WA6BZixZjpVSg6EXjuYh607GLfixDA",
              "source" : "rss",
              "sourceLabel" : "Example Blog",
              "summary" : "Changelog published.",
              "timestamp" : "2026-11-27T09:00:00Z",
              "title" : "Release notes for 1.2.0"
            }
          ],
          "nodeId" : "node-evil",
          "publicKey" : "Dp7P9JZAKRp4X0hMpnC3cLi7lKbhxUpWvV6jeEoSs-o",
          "schema" : "popopx.discover.feed.v1",
          "signature" : "-21KG0F06UR4whTPP9HPPsX1_aa3TtIBtsxl6GQ2d08MjuR-BmVGUMg4GJ3mufDqkhobA5suED7GS9nszibIDA"
        }
        """.trimIndent()

  /** 781 bytes, pinned verbatim from the mint, copied from the Swift carrier of the same name. */
  val foreignKey: String = """
        {
          "generatedAt" : "2026-11-27T09:05:00Z",
          "items" : [
            {
              "id" : "item-1",
              "link" : "https:\/\/popopx.example\/blog\/1-2-0?x=a\/b",
              "sha256" : "28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286",
              "signature" : "fmv2IYKCX4G_6uR5EKQx0BSLbfunZZrmhIv9s3qivUXgYu98JXL6bjrDF9nKu6M98ijdRSbE3IeoPJcD10k1DQ",
              "source" : "rss",
              "sourceLabel" : "Example Blog",
              "summary" : "Changelog published.",
              "timestamp" : "2026-11-27T09:00:00Z",
              "title" : "Release notes for 1.2.0"
            }
          ],
          "nodeId" : "node-7f2a",
          "publicKey" : "Dp7P9JZAKRp4X0hMpnC3cLi7lKbhxUpWvV6jeEoSs-o",
          "schema" : "popopx.discover.feed.v1",
          "signature" : "j5ykss0Q_lzLMPCDbsOdLEzZGF9uG_fYa-Xsil5ZnHysRChwIPDqLF1Oij34CeeKhaOFNt0QyL0ErccT--n3DQ"
        }
        """.trimIndent()

  /** 1217 bytes, pinned verbatim from the mint, copied from the Swift carrier of the same name. */
  val loneSurrogate: String = """
        {
          "generatedAt" : "2026-11-27T09:05:00Z",
          "items" : [
            {
              "id" : "item-1",
              "link" : "https:\/\/popopx.example\/blog\/1-2-0?x=a\/b",
              "sha256" : "28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286",
              "signature" : "vYYV07D9i_H2A4fwhvh1zBVhnzpB4hbg8UyMmbCkI0DZFHNHJywgTAh2eUV524bPUnt18gslp91p_u0hBBRoBg",
              "source" : "rss",
              "sourceLabel" : "Example Blog",
              "summary" : "Changelog published.",
              "timestamp" : "2026-11-27T09:00:00Z",
              "title" : "Release \ud800 notes"
            },
            {
              "id" : "item-2",
              "link" : "",
              "sha256" : "411eb4aa04244c255440468e3e56220cae6c50e7782375da079b1dddb4054492",
              "signature" : "cqf_Mq2lhNbMi9y2lQGACwOLkzetFqbVPHg3gpFDYdVZ8NGAIAdTIsrKm5CvswCiW-R2edbxKgG0jFP76RfVCg",
              "source" : "folder",
              "sourceLabel" : "~\/Documents",
              "summary" : "No link travels to the phone.",
              "timestamp" : "2026-11-27T09:00:00Z",
              "title" : "Local file"
            }
          ],
          "nodeId" : "node-7f2a",
          "publicKey" : "Dp7P9JZAKRp4X0hMpnC3cLi7lKbhxUpWvV6jeEoSs-o",
          "schema" : "popopx.discover.feed.v1",
          "signature" : "3BSMU0k5e2EXPX0zu0WUSp4uY2FAHhP9bri5RK1mRtCwyp_Npbl_0n8lpOt-OivnxYedsIpM4hGXjwW4vBqLCA"
        }
        """.trimIndent()

  /** The sizes the mint measured, so a source-lexer difference is caught before any digest is compared. */
  val byteSizes = mapOf(
    "plain" to 1220,
    "escaping" to 1211,
    "unicode" to 804,
    "empty" to 299,
    "digestDrift" to 782,
    "itemSignature" to 782,
    "envelopeSignature" to 781,
    "foreignKey" to 781,
    "loneSurrogate" to 1217
  )
}
