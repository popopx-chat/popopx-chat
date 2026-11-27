//
//  PopopxNodeFeedVectors.swift
//  PopopxMeshKitTests
//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
//  Pinned `popopx.discover.feed.v1` envelopes, shared byte-for-byte with
//  desktopTest/.../discover/PopopxNodeFeedVectors.kt.
//
//  Honest provenance, because it limits what these vectors can prove:
//   - Minted by a scratch script (/tmp/ppxvec/mint.swift, 2026-11-27) that transcribes the node's
//     own signing bodies verbatim — `DiscoverModels.swift:226-236` and `:280-301`, encoded with
//     `JSONSerialization(…, [.sortedKeys, .withoutEscapingSlashes])`, signed with
//     `Curve25519.Signing`, and written to disk with `JSONEncoder([.prettyPrinted, .sortedKeys])`
//     exactly as `NodeJSON.encoder(prettyPrinted: true)` (MacNodeModels.swift:426-437) does.
//     That is the producer's API and options, **not the producer running**.
//   - There is no real `feed.json` to compare against: `~/Library/Application Support/PopopxMacNode/`
//     has no `discover/` directory, because the aggregator was never switched on on this machine.
//   - Every signature was re-checked with `OpenSSL 4.1.0 pkeyutl -verify -rawin` against the SPKI
//     DER of the same key, independent of CryptoKit. The four honest vectors verify; the tampered
//     ones fail exactly where the decoder is expected to stop. The system `/usr/bin/openssl` is
//     LibreSSL 3.3.6 and has no `-rawin`, so the Homebrew binary is the one that was used.
//   - The signing identity is derived from a published literal
//     (`sha256("popopx.discover.feed.v1 vector mint 2026-11-27")`), so the vectors can be re-minted;
//     it is a test key and guards nothing.
//   - Each carrier is the producer's file bytes with every non-ASCII scalar rewritten as a `\u`
//     escape, so the same text can live in a Swift and a Kotlin source literal without either lexer
//     normalizing it. Decoded values, canonical bodies and signatures are unchanged.
//
//  Measured at mint time (sha256 of the disk bytes vs sha256 of the signature body — a receiver that
//  hashed what it was handed would fail every one of these):
//   plain: items=2 pretty.sha=82687c06849957738cf18672ffc3af7282afd3832efb6c9cf45c53975683ff92 envelopeBody.sha=375d3d67c87fd14abc2b5e48a28b7123c2fd09aebbc9a3bcf88906c2b533fb42 itemBody.sha=28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286 wireSha=28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286 carrier.sha=82687c06849957738cf18672ffc3af7282afd3832efb6c9cf45c53975683ff92 prettyHasEscapedSlash=true
//   escaping: items=2 pretty.sha=c1d8e1b3962b7cfe50437006c58590c29f07c899ef053c074bc52d9af477e1d0 envelopeBody.sha=86753396a1b74e7df9c5f13ca5e4679d74c1b7700efbdf0ecab8a95ab7f73da6 itemBody.sha=75009d746879c4fc86785e7f6dbcd2914d0520f0f2601766f4b9ed27576a8af9 wireSha=75009d746879c4fc86785e7f6dbcd2914d0520f0f2601766f4b9ed27576a8af9 carrier.sha=c1d8e1b3962b7cfe50437006c58590c29f07c899ef053c074bc52d9af477e1d0 prettyHasEscapedSlash=true
//   unicode: items=1 pretty.sha=d650ae60aea5f5d0f1bb77a602f2d692809a87ce83ed050b6453b8fc8a409307 envelopeBody.sha=1e79c24ef38f3febacab7b755968e9fc91a4ebd9684e5942c804df62184a240c itemBody.sha=3ab5f5123068e1beed7b4c3c0b91319e4ac93b70385997787b837a3e4f96a82e wireSha=3ab5f5123068e1beed7b4c3c0b91319e4ac93b70385997787b837a3e4f96a82e carrier.sha=f515c7d8395e7cde2fffbcdb8d09b568f41e3338ede9745e9e55f000eb265055 prettyHasEscapedSlash=true
//   empty: items=0 pretty.sha=b6b594e64a67d8068ceef817a8582e246279a8901048ce4822146cc75c9944fd envelopeBody.sha=f2810eca50605341c7572c8dac1957b53ebd15c6d77ba2381d893bcc98cb579c
//   digest-drift: items=1 pretty.sha=c295d8412fdf4a400b79046c732515300e04491f48113dc8d90959940f66a30f envelopeBody.sha=aace1d9920b1cf0968984017a6a084f7fd029e0e0bea7da32f5b69589beba743 itemBody.sha=e4b8a72c247021ad5c82bbfe2032512b88eb8640ce62030c1d3fbd0218c438d6 wireSha=28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286 carrier.sha=c295d8412fdf4a400b79046c732515300e04491f48113dc8d90959940f66a30f prettyHasEscapedSlash=true
//   item-signature: items=1 pretty.sha=d8d128486f002343337f6b2995d2178dd08976e61248391795a1e699ddfd8df8 envelopeBody.sha=1ef3b14dcd66df3ead6d0f410b1c4a435261063cf344af28edea65ac8cc27d1e itemBody.sha=e4b8a72c247021ad5c82bbfe2032512b88eb8640ce62030c1d3fbd0218c438d6 wireSha=e4b8a72c247021ad5c82bbfe2032512b88eb8640ce62030c1d3fbd0218c438d6 carrier.sha=d8d128486f002343337f6b2995d2178dd08976e61248391795a1e699ddfd8df8 prettyHasEscapedSlash=true
//   envelope-signature: items=1 pretty.sha=8922e5520ef321eadd6057aa0533e70e80e24b0144e006119f263d0a1a2f9bc9 envelopeBody.sha=39d0d4d0378993019475358d618ba6e61c1b7c1c3e36da70f05b1e66d6b404fc itemBody.sha=28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286 wireSha=28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286 carrier.sha=8922e5520ef321eadd6057aa0533e70e80e24b0144e006119f263d0a1a2f9bc9 prettyHasEscapedSlash=true
//   foreign-key: items=1 pretty.sha=8eb08d7fb8f4f78e7be76b1a6ab53e17bfbcc3795a910282e8907b7510968452 envelopeBody.sha=d98550bc31c93aebabf13e67c173cba5b2cda21021bd7be70c0a072ddb39dbaa itemBody.sha=28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286 wireSha=28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286 carrier.sha=8eb08d7fb8f4f78e7be76b1a6ab53e17bfbcc3795a910282e8907b7510968452 prettyHasEscapedSlash=true
//   lone-surrogate: derived from plain by rewriting one title to carry a \ud800 escape. Measured, not
//     assumed: JSONSerialization refuses to parse it (NSCocoaErrorDomain 3840, "expected low-surrogate
//     code point"), so the refusal this receiver reports is .malformedJSON. The test asserts only
//     'refused', because that error code is Foundation's behaviour rather than anything the wire says.
//
//  One trap the `unicode` vector exists to spring, measured while writing the Swift test: a Swift
//  `String.contains("é")` is **true** for a decomposed `e` + U+0301, because string comparison here is
//  Unicode canonical equivalence, not bytes. A receiver that normalized every decoded string would
//  still pass a text-level check and then fail the digest, looking like a signature bug. So the
//  non-normalization claim is asserted on UTF-8 bytes and on scalar values, never with `contains`.
//


enum PopopxNodeFeedVectors {
    /// The key `plain`, `escaping`, `unicode` and `empty` are signed by.
    static let signingPublicKey = "Dp7P9JZAKRp4X0hMpnC3cLi7lKbhxUpWvV6jeEoSs-o"
    /// The key `foreign-key` is actually signed by, while its envelope declares the one above.
    static let otherPublicKey = "3-LxHV5kqjJyFYMAgP_jSerYc6db9MMHtevbRSLY1xY"
    static let generatedAt = "2026-11-27T09:05:00Z"
    static let itemTimestamp = "2026-11-27T09:00:00Z"

    /// sha256 of the canonical bodies and of the file bytes, measured by the mint. These are
    /// what make the cross-language test a byte gate rather than a self-consistency check: a
    /// receiver whose serializer differs by one byte cannot reproduce them, and `verify` would
    /// refuse its own digest before ever reaching the signature.
    enum Digest {
        /// `plain` and `escaping` contain no non-ASCII, so their carrier *is* the producer file bytes.
        /// `unicode` is not: its carrier escapes what the node wrote raw, which is why it has both.

        /// plain fileBytes: sha256 of the producer's `feed.json` bytes
        static let plainFileBytes = "82687c06849957738cf18672ffc3af7282afd3832efb6c9cf45c53975683ff92"
        /// plain envelopeBody: sha256 of the canonical envelope signing body
        static let plainEnvelopeBody = "375d3d67c87fd14abc2b5e48a28b7123c2fd09aebbc9a3bcf88906c2b533fb42"
        /// plain itemBody: sha256 of the canonical body of the vector's first item
        static let plainItemBody = "28c8ea786c12dadd7cc9671c57c344f5fa45ca8cbc7e91371a04e07daaf25286"
        /// escaping fileBytes: sha256 of the producer's `feed.json` bytes
        static let escapingFileBytes = "c1d8e1b3962b7cfe50437006c58590c29f07c899ef053c074bc52d9af477e1d0"
        /// escaping envelopeBody: sha256 of the canonical envelope signing body
        static let escapingEnvelopeBody = "86753396a1b74e7df9c5f13ca5e4679d74c1b7700efbdf0ecab8a95ab7f73da6"
        /// escaping itemBody: sha256 of the canonical body of the vector's first item
        static let escapingItemBody = "75009d746879c4fc86785e7f6dbcd2914d0520f0f2601766f4b9ed27576a8af9"
        /// unicode fileBytes: sha256 of the producer's `feed.json` bytes
        static let unicodeFileBytes = "d650ae60aea5f5d0f1bb77a602f2d692809a87ce83ed050b6453b8fc8a409307"
        /// unicode carrierBytes: sha256 of this pinned carrier (escaped non-ASCII)
        static let unicodeCarrierBytes = "f515c7d8395e7cde2fffbcdb8d09b568f41e3338ede9745e9e55f000eb265055"
        /// unicode envelopeBody: sha256 of the canonical envelope signing body
        static let unicodeEnvelopeBody = "1e79c24ef38f3febacab7b755968e9fc91a4ebd9684e5942c804df62184a240c"
        /// unicode itemBody: sha256 of the canonical body of the vector's first item
        static let unicodeItemBody = "3ab5f5123068e1beed7b4c3c0b91319e4ac93b70385997787b837a3e4f96a82e"
        /// empty envelopeBody: sha256 of the canonical envelope signing body
        static let emptyEnvelopeBody = "f2810eca50605341c7572c8dac1957b53ebd15c6d77ba2381d893bcc98cb579c"
    }

    /// 1220 bytes, pinned verbatim from the mint.
    static let plain = #"""
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
        """#

    /// 1211 bytes, pinned verbatim from the mint.
    static let escaping = #"""
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
        """#

    /// 804 bytes, pinned verbatim from the mint.
    static let unicode = #"""
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
        """#

    /// 299 bytes, pinned verbatim from the mint.
    static let empty = #"""
        {
          "generatedAt" : "2026-11-27T09:05:00Z",
          "items" : [

          ],
          "nodeId" : "node-7f2a",
          "publicKey" : "Dp7P9JZAKRp4X0hMpnC3cLi7lKbhxUpWvV6jeEoSs-o",
          "schema" : "popopx.discover.feed.v1",
          "signature" : "Dtf7nwWAEwtsj7BNRs8RzpiEXBZlbNfq3OQfaX3nFdfQNWl_fHCxCOXfo_hg9fqqjx1cFi-w4K-Zu7s8On5gCg"
        }
        """#

    /// 782 bytes, pinned verbatim from the mint.
    static let digestDrift = #"""
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
        """#

    /// 782 bytes, pinned verbatim from the mint.
    static let itemSignature = #"""
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
        """#

    /// 781 bytes, pinned verbatim from the mint.
    static let envelopeSignature = #"""
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
        """#

    /// 781 bytes, pinned verbatim from the mint.
    static let foreignKey = #"""
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
        """#

    /// 1217 bytes, pinned verbatim from the mint.
    static let loneSurrogate = #"""
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
        """#
}
