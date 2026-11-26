package chat.popopx.app.mesh


/*
 * GROUND TRUTH FROM THE iOS MESH CODE ITSELF — apps/ios/PopopxMeshKit/Sources/PopopxMeshKit,
 * compiled for macOS by Apple Swift 6.4.2 (swiftlang-6.4.2.1.9, arm64-apple-macosx27.0.0) and run,
 * minted 2026-11-26. Generated from the freeze by /tmp/meshvec/gen_kotlin_vectors.py: no value here was
 * typed by hand, so changing one means changing the Swift probe that produced it and re-minting.
 *
 *   sources   the iOS tree, verbatim except for the added probe file _VecBridge.swift — `diff -r`
 *             reports exactly that one file as the difference, and apps/ios stays clean
 *   mint      `swift build --product MeshVec && .build/debug/MeshVec > vectors.txt`
 *   freeze    vectors.txt, whose own header records the measured conclusions, which rows are
 *             stable across processes, and how the tool was built
 *
 * EVIDENCE LEVEL, stated once so no test can imply more: this is iOS' own protocol and crypto code
 * running on macOS, NOT on an iOS device. CryptoKit on the two OSes is the same implementation
 * lineage but a different build, so these rows prove the Kotlin port agrees with the Swift source
 * and with CryptoKit as compiled here. Nothing here proves BLE behaviour on hardware.
 *
 * A value is written verbatim when it is printable ASCII with no quote, backslash or `$`. Anything
 * else is prefixed `%` and holds UTF-8 hex, because some rows legitimately carry CJK, emoji,
 * U+2028/U+2029, control characters and nested JSON escapes; keeping this file ASCII means no
 * reader has to guess whether an invisible character survived the copy.
 */
internal object PopopxMeshSwiftVectors {

  /** noise — 12 rows, freeze order. */

  private val noise: List<Pair<String, String>> =
    listOf(

      "noise.name.ascii" to "Noise_XX_25519_ChaChaPoly_SHA256",
      "noise.name.bytes" to "32",
      "noise.name.hex" to "4e6f6973655f58585f32353531395f436861436861506f6c795f534841323536",
      "noise.encryptedPublicKeySize" to "48",
      "noise.frameOverhead" to "28",
      "noise.messageLimit" to "4294967295",
      "noise.nonce(0)" to "000000000000000000000000",
      "noise.nonce(1)" to "000000000100000000000000",
      "noise.nonce(2)" to "000000000200000000000000",
      "noise.nonce(255)" to "00000000ff00000000000000",
      "noise.nonce(256)" to "000000000001000000000000",
      "noise.nonce(4294967295)" to "00000000ffffffff00000000",
    )

  /** identity — 12 rows, freeze order. */

  private val identity: List<Pair<String, String>> =
    listOf(

      "identity.seed" to "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
      "identity.publicKey" to "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f",
      "identity.peerID" to "eedd883da0a94515",
      "identity.peerID.u64" to "17212063149149734165",
      "identity.seed#2" to "0708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20212223242526",
      "identity.publicKey#2" to "07b8c542487686a78301855fcb6d3f6a8a911cd7f1983a9b44dc9dcd22839d23",
      "identity.peerID#2" to "c686298850642c4e",
      "identity.peerID.u64#2" to "14305166931829992526",
      "identity.seed#3" to "0000000000000000000000000000000000000000000000000000000000000000",
      "identity.publicKey#3" to "2fe57da347cd62431528daac5fbb290730fff684afc4cfc2ed90995f58cb3b74",
      "identity.peerID#3" to "233ced774423c7a7",
      "identity.peerID.u64#3" to "2539165386430203815",
    )

  /** xxEmpty — 36 rows, freeze order. */

  private val xxEmpty: List<Pair<String, String>> =
    listOf(

      "xx.msg1" to "c37077fb432d19c51d6a8c6fdf9dbf06f8471cf12edb1cadab76aeac29917a1e",
      "xx.msg1.len" to "32",
      "xx.msg1.payloadRead" to "",
      "xx.msg1.complete" to "false",
      "xx.msg2" to "3ebcb692149344dc54e58160cf90bed9eea1dd14e81c8e91de557af7d7afd91505cf9b5e529155d13a67ba235b85feb0e8995dd571bbfb520deaa09e2ec22d120e71621df18e65f4718436ab022f38605e046f25ec65aff0fb27ed647a926eec",
      "xx.msg2.len" to "96",
      "xx.msg2.payloadRead" to "",
      "xx.msg2.complete" to "false",
      "xx.msg3" to "df8976c685aabeb6556e89ca61a52cd11a95cea8e28729cce14c204195262ca32449a4ebb8848ce9e7d99f412d7707b11d7c33eec94ffc8c810342694c83defd",
      "xx.msg3.len" to "64",
      "xx.msg3.payloadRead" to "",
      "xx.msg3.complete" to "true",
      "xx.peerStatic.initiatorSees" to "07b8c542487686a78301855fcb6d3f6a8a911cd7f1983a9b44dc9dcd22839d23",
      "xx.peerStatic.responderSees" to "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f",
      "xx.hash.initiator" to "21a486052495567641be3f01242c8ccf9ecb098efe06de1aaeeef27bee5b985c",
      "xx.hash.responder" to "21a486052495567641be3f01242c8ccf9ecb098efe06de1aaeeef27bee5b985c",
      "xx.keys.initiator.send" to "83e508c3cfc2b4ff3e91163204b8aed1907d09a62aef043d85222a216a26a0da",
      "xx.keys.initiator.receive" to "7e11e80c0bcaa5c598521f1ced313393ae612d6f77b097ad63e517da748a83f0",
      "xx.keys.responder.send" to "7e11e80c0bcaa5c598521f1ced313393ae612d6f77b097ad63e517da748a83f0",
      "xx.keys.responder.receive" to "83e508c3cfc2b4ff3e91163204b8aed1907d09a62aef043d85222a216a26a0da",
      "xx.frame.nonce0" to "00000000000000000000000057663b64e3d28993cdffd1ebbb8af2820a98b3df675f1571d6bf17112f552065e9",
      "xx.frame.nonce0.tag" to "98b3df675f1571d6bf17112f552065e9",
      "xx.frame.nonce0.opened" to "hello popopx mesh",
      "xx.frame.nonce1" to "000000000100000000000000290193a8f7c4ba6d7a7e09e4ad29255ee9e1ce1bd76625ae2b4cd59891eca2ec28",
      "xx.frame.nonce1.tag" to "e1ce1bd76625ae2b4cd59891eca2ec28",
      "xx.frame.nonce1.opened" to "hello popopx mesh",
      "xx.frame.nonce2" to "00000000020000000000000066b2e6605921ec5d68fbec4ba8e6751cd1c1bd57562ba77bdfe417a7b5a98603ce",
      "xx.frame.nonce2.tag" to "c1bd57562ba77bdfe417a7b5a98603ce",
      "xx.frame.nonce2.opened" to "hello popopx mesh",
      "xx.frame.nonce4294967294" to "00000000feffffff0000000069bdbcd88aa3c6c67c5e2e7b7e0ccf0a376a6f9dca5dd6933447032b94da28073a",
      "xx.frame.nonce4294967294.tag" to "6a6f9dca5dd6933447032b94da28073a",
      "xx.frame.nonce4294967294.opened" to "hello popopx mesh",
      "xx.frame.tamperedPrefix" to "OPENED (unexpected)",
      "xx.frame.nonceInFrame" to "7",
      "xx.frame.nonceInFrame.badPrefix" to "decryptionFailed",
      "xx.frame.tooShort" to "messageTooShort(bytes: 27, required: 28)",
    )

  /** xxPayload — 36 rows, freeze order. */

  private val xxPayload: List<Pair<String, String>> =
    listOf(

      "xx.msg1" to "c37077fb432d19c51d6a8c6fdf9dbf06f8471cf12edb1cadab76aeac29917a1e5359535f504f504f50585f41434b3a30613061306130613061306130613061306130613061306130613061306130613061306130613061306130613061306130613061306130613061306130613061",
      "xx.msg1.len" to "111",
      "xx.msg1.payloadRead" to "SYS_POPOPX_ACK:0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a",
      "xx.msg1.complete" to "false",
      "xx.msg2" to "3ebcb692149344dc54e58160cf90bed9eea1dd14e81c8e91de557af7d7afd91505cf9b5e529155d13a67ba235b85feb0e8995dd571bbfb520deaa09e2ec22d12d8932f39ad1adb38fc32411326036ddeae40d6ad3a408efc41e749bd38b1bc4b354225794874e9ba",
      "xx.msg2.len" to "104",
      "xx.msg2.payloadRead" to "announce",
      "xx.msg2.complete" to "false",
      "xx.msg3" to "df8976c685aabeb6556e89ca61a52cd11a95cea8e28729cce14c204195262ca3c5873dfc187fa80b480a192a1b74c156ffc9119769f1c586341b90aed5d5037773a6ecc519731ce1f5675b577a05b714a8",
      "xx.msg3.len" to "81",
      "xx.msg3.payloadRead" to "BLE_ACK:message-1",
      "xx.msg3.complete" to "true",
      "xx.peerStatic.initiatorSees" to "07b8c542487686a78301855fcb6d3f6a8a911cd7f1983a9b44dc9dcd22839d23",
      "xx.peerStatic.responderSees" to "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f",
      "xx.hash.initiator" to "f51a13da8bb1d9ce82c6677c64fd8980e7a9735dc6627a85e0c7c59f1698244d",
      "xx.hash.responder" to "f51a13da8bb1d9ce82c6677c64fd8980e7a9735dc6627a85e0c7c59f1698244d",
      "xx.keys.initiator.send" to "83e508c3cfc2b4ff3e91163204b8aed1907d09a62aef043d85222a216a26a0da",
      "xx.keys.initiator.receive" to "7e11e80c0bcaa5c598521f1ced313393ae612d6f77b097ad63e517da748a83f0",
      "xx.keys.responder.send" to "7e11e80c0bcaa5c598521f1ced313393ae612d6f77b097ad63e517da748a83f0",
      "xx.keys.responder.receive" to "83e508c3cfc2b4ff3e91163204b8aed1907d09a62aef043d85222a216a26a0da",
      "xx.frame.nonce0" to "00000000000000000000000044213567e88bdbc69fe883bfb98ef3d35808a37aab1b0c549490179376a95addb4ffa4d73f0232c124cca86a1758b78cbe8032903069e6afa0046039944b464c61fab13578fae682be3d",
      "xx.frame.nonce0.tag" to "6039944b464c61fab13578fae682be3d",
      "xx.frame.nonce0.opened" to "%7b22626f6479223a2278222c226964223a2279222c226b696e64223a2274657874222c2273656e744174223a313739353631343934343030307d",
      "xx.frame.nonce1" to "0000000001000000000000003a469dabfc9de83828695bb0af2d240fbb9ba86b22e6a1f2d475c6f6bff866a5fb9dfe1bdc795997bd787a934f37d1e8c3fcf730bdd4d6e8408a947ec6877dd40a1374faf848f7a8a788",
      "xx.frame.nonce1.tag" to "947ec6877dd40a1374faf848f7a8a788",
      "xx.frame.nonce1.opened" to "%7b22626f6479223a2278222c226964223a2279222c226b696e64223a2274657874222c2273656e744174223a313739353631343934343030307d",
      "xx.frame.nonce2" to "00000000020000000000000075f5e8635278be083aecbe1faae2744d83c502c39323e7bd4992007f849792f2f884e4ea8e0a59b0685bf559e8494fbaec1f85dcfe2df1904caa9701c859c8bd65c9abe1c2695aa40952",
      "xx.frame.nonce2.tag" to "9701c859c8bd65c9abe1c2695aa40952",
      "xx.frame.nonce2.opened" to "%7b22626f6479223a2278222c226964223a2279222c226b696e64223a2274657874222c2273656e744174223a313739353631343934343030307d",
      "xx.frame.nonce4294967294" to "00000000feffffff000000007afab2db81fa94932e497c2f7c08ce5b654112436741de07f81f21a34040f6ee71d275826f4a915a12ee21ae8129c75a43d77385482374503e091c4ae8ed032a91dc762b7db7cd04ef45",
      "xx.frame.nonce4294967294.tag" to "1c4ae8ed032a91dc762b7db7cd04ef45",
      "xx.frame.nonce4294967294.opened" to "%7b22626f6479223a2278222c226964223a2279222c226b696e64223a2274657874222c2273656e744174223a313739353631343934343030307d",
      "xx.frame.tamperedPrefix" to "OPENED (unexpected)",
      "xx.frame.nonceInFrame" to "7",
      "xx.frame.nonceInFrame.badPrefix" to "decryptionFailed",
      "xx.frame.tooShort" to "messageTooShort(bytes: 27, required: 28)",
    )

  /** xxFail — 16 rows, freeze order. */

  private val xxFail: List<Pair<String, String>> =
    listOf(

      "xxfail.protocolName" to "protocolNameMismatch",
      "xxfail.identity.shortSeed" to "nil",
      "xxfail.turnOrder" to "handshakeOutOfOrder(role: PopopxMeshKit.PopopxNoiseXXHandshake.Role.initiator)",
      "xxfail.consumeFirst" to "handshakeOutOfOrder(role: PopopxMeshKit.PopopxNoiseXXHandshake.Role.initiator)",
      "xxfail.truncatedMsg1" to "messageTooShort(bytes: 31, required: 32)",
      "xxfail.responderUsableAfterTruncate" to "accepted",
      "xxfail.allZeroEphemeral" to "peerKeyUnusable",
      "xxfail.allZeroThenMsg2" to "handshakeOutOfOrder(role: PopopxMeshKit.PopopxNoiseXXHandshake.Role.initiator)",
      "xxfail.finalizeIncomplete" to "handshakeNotComplete",
      "xxfail.msg2.len" to "96",
      "xxfail.msg3.len" to "64",
      "xxfail.finalizeIdempotent" to "same",
      "xxfail.messageAfterComplete" to "handshakeOutOfOrder(role: PopopxMeshKit.PopopxNoiseXXHandshake.Role.initiator)",
      "xxfail.responderMessageAfterComplete" to "handshakeOutOfOrder(role: PopopxMeshKit.PopopxNoiseXXHandshake.Role.responder)",
      "xxfail.consumeAfterComplete" to "handshakeOutOfOrder(role: PopopxMeshKit.PopopxNoiseXXHandshake.Role.responder)",
      "xxfail.transcript" to "complete",
    )

  /** session — 46 rows, freeze order. */

  private val session: List<Pair<String, String>> =
    listOf(

      "session.hash.agree" to "same",
      "session.hash.hex" to "21a486052495567641be3f01242c8ccf9ecb098efe06de1aaeeef27bee5b985c",
      "session.keys.mirrored" to "swapped",
      "session.peerKey.iSees" to "07b8c542487686a78301855fcb6d3f6a8a911cd7f1983a9b44dc9dcd22839d23",
      "session.peerKey.rSees" to "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f",
      "session.peerHexWidth" to "32bytes",
      "session.init.shortPeerKey" to "refused",
      "session.init.zeroPeerKey" to "built",
      "session.init.window0" to "refused",
      "session.init.windowMax" to "built",
      "session.init.windowOverMax" to "refused",
      "session.sealed.count" to "9",
      "session.sealed.counters" to "0,1,2,3,4,5,6,7,8",
      "session.sealed.messagesSent" to "9",
      "session.sealed.frame0" to "0000000000000000000000005233d8a4f98dbf155e02e9324b6e1b4c3477",
      "session.sealed.len0" to "30",
      "session.sealed.peerCounterBeforeAny" to "nil",
      "session.d.0" to "OPENED:m0:peer=1",
      "session.d.1" to "OPENED:m1:peer=2",
      "session.d.3.outOfOrder" to "OPENED:m3:peer=4",
      "session.d.2.late" to "OPENED:m2:peer=4",
      "session.d.2.replay" to "ERR:replayed(counter: 2)",
      "session.d.8.jump" to "OPENED:m8:peer=9",
      "session.d.4.middle" to "OPENED:m4:peer=9",
      "session.d.4.again" to "ERR:replayed(counter: 4)",
      "session.d.5.forgedTag" to "ERR:decryptionFailed",
      "session.d.5.afterForge" to "OPENED:m5:peer=9",
      "session.d.6.badNoncePrefix" to "ERR:decryptionFailed",
      "session.d.7" to "OPENED:m7:peer=9",
      "session.d.7.replay" to "ERR:replayed(counter: 7)",
      "session.end.peerCounter" to "9",
      "session.end.messagesSent" to "9",
      "session.hostile.forged" to "ERR:decryptionFailed",
      "session.hostile.realAfterForge" to "OPENED:y:counter=10",
      "session.small.0" to "OPENED:s0:peer=1",
      "session.small.11" to "OPENED:s11:peer=12",
      "session.small.3.inside" to "ERR:counterOutsideWindow(counter: 3, windowStart: 4)",
      "session.small.4" to "OPENED:s4:peer=12",
      "session.small.5" to "OPENED:s5:peer=12",
      "session.small.6" to "OPENED:s6:peer=12",
      "session.small.7" to "OPENED:s7:peer=12",
      "session.small.8" to "OPENED:s8:peer=12",
      "session.small.9" to "OPENED:s9:peer=12",
      "session.small.10" to "OPENED:s10:peer=12",
      "session.small.3.tooOld" to "ERR:counterOutsideWindow(counter: 3, windowStart: 4)",
      "session.small.4.tooOld" to "ERR:replayed(counter: 4)",
    )

  /** window — 20 rows, freeze order. */

  private val window: List<Pair<String, String>> =
    listOf(

      "window.size8" to "0=accept 1=accept 2=accept 3=accept 4=accept 5=accept 6=accept 7=accept 8=accept 7=duplicate 6=duplicate 0=tooOld 15=accept 16=accept 20=accept 19=accept 18=accept 17=accept 33=accept 32=accept",
      "window.size8.end" to "highest=33 start=26 read=true size=8",
      "window.size1" to "0=accept 1=accept 1=duplicate 2=accept 5=accept 4=tooOld",
      "window.size1.end" to "highest=5 start=5 read=true size=1",
      "window.size64" to "63=accept 62=accept 64=accept 0=tooOld 1=accept 100=accept 36=tooOld 37=accept 101=accept 102=accept 102=duplicate",
      "window.size64.end" to "highest=102 start=39 read=true size=64",
      "window.size1024" to "0=accept 1023=accept 1024=accept 1=accept 1022=accept 2=accept 2047=accept 2048=accept 1025=accept 1024=tooOld",
      "window.size1024.end" to "highest=2048 start=1025 read=true size=1024",
      "window.backward" to "10=accept 9=accept 8=accept 7=accept 6=accept 5=accept 4=accept 3=accept 2=tooOld 1=tooOld 0=tooOld 3=duplicate",
      "window.backward.end" to "highest=10 start=3 read=true size=8",
      "window.bigJump" to "0=accept 1000=accept 999=accept 998=accept 992=tooOld 991=tooOld 993=accept",
      "window.bigJump.end" to "highest=1000 start=993 read=true size=8",
      "window.interleave" to "200=accept 193=accept 186=accept 179=accept 172=accept 165=accept 158=accept 151=accept 144=accept 137=accept 130=accept 123=accept 116=accept 109=accept 102=accept 95=accept 88=accept 81=accept 74=accept 67=tooOld 60=tooOld 53=tooOld 46=tooOld 39=tooOld 32=tooOld 25=tooOld 18=tooOld 11=tooOld 4=tooOld",
      "window.interleave.end" to "highest=200 start=73 read=true size=128",
      "window.byteBoundaries" to "0=accept 8=accept 16=accept 7=accept 15=accept 24=accept 25=accept 41=accept 40=accept 9=tooOld 42=accept 100=accept 58=tooOld 59=tooOld 60=tooOld 75=tooOld 76=tooOld",
      "window.byteBoundaries.end" to "highest=100 start=84 read=true size=17",
      "window.fresh.start" to "0",
      "window.fresh.read" to "false",
      "window.fresh.place" to "accept",
      "window.first.mark" to "highest=0 start=0 place0=duplicate",
    )

  /** packet — 72 rows, freeze order. */

  private val packet: List<Pair<String, String>> =
    listOf(

      "packet.unsigned.packetID" to "457653dc40010143407079e12a1b7c20",
      "packet.unsigned.len" to "41",
      "packet.unsigned.unpadded" to "010207000001a212fdab000000130123456789abcdef706f706f7078206d657368207061796c6f6164",
      "packet.unsigned.padded" to "010207000001a212fdab000000130123456789abcdef706f706f7078206d657368207061796c6f6164d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7",
      "packet.unsigned.isBroadcast" to "true",
      "packet.unsigned.decodedType" to "Optional(PopopxMeshKit.PopopxMeshMessageType.message)",
      "packet.unsigned.decodeUnpadded" to "true",
      "packet.unsigned.decodePadded" to "true",
      "packet.unsigned.packetIDLen" to "16",
      "packet.directed.packetID" to "457653dc40010143407079e12a1b7c20",
      "packet.directed.len" to "49",
      "packet.directed.unpadded" to "010205000001a212fdab000100130123456789abcdeffedcba9876543210706f706f7078206d657368207061796c6f6164",
      "packet.directed.padded" to "010205000001a212fdab000100130123456789abcdeffedcba9876543210706f706f7078206d657368207061796c6f6164cfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcf",
      "packet.directed.isBroadcast" to "false",
      "packet.directed.decodedType" to "Optional(PopopxMeshKit.PopopxMeshMessageType.message)",
      "packet.directed.decodeUnpadded" to "true",
      "packet.directed.decodePadded" to "true",
      "packet.directed.packetIDLen" to "16",
      "packet.broadcastOnes.packetID" to "457653dc40010143407079e12a1b7c20",
      "packet.broadcastOnes.len" to "49",
      "packet.broadcastOnes.unpadded" to "010205000001a212fdab000100130123456789abcdefffffffffffffffff706f706f7078206d657368207061796c6f6164",
      "packet.broadcastOnes.padded" to "010205000001a212fdab000100130123456789abcdefffffffffffffffff706f706f7078206d657368207061796c6f6164cfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcf",
      "packet.broadcastOnes.isBroadcast" to "true",
      "packet.broadcastOnes.decodedType" to "Optional(PopopxMeshKit.PopopxMeshMessageType.message)",
      "packet.broadcastOnes.decodeUnpadded" to "true",
      "packet.broadcastOnes.decodePadded" to "true",
      "packet.broadcastOnes.packetIDLen" to "16",
      "packet.signed.packetID" to "a3c100960400273eca7d0cc3f17808ec",
      "packet.signed.len" to "113",
      "packet.signed.unpadded" to "011107000001a212fdab000300130123456789abcdeffedcba9876543210706f706f7078206d657368207061796c6f6164000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f",
      "packet.signed.padded" to "011107000001a212fdab000300130123456789abcdeffedcba9876543210706f706f7078206d657368207061796c6f6164000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f",
      "packet.signed.isBroadcast" to "false",
      "packet.signed.decodedType" to "Optional(PopopxMeshKit.PopopxMeshMessageType.noiseEncrypted)",
      "packet.signed.decodeUnpadded" to "true",
      "packet.signed.decodePadded" to "true",
      "packet.signed.packetIDLen" to "16",
      "packet.announce.packetID" to "b9ade540c27e19fc5e1f341ca2fe3b8b",
      "packet.announce.len" to "50",
      "packet.announce.unpadded" to "010107000001a212fdab0000001c0123456789abcdef7b226e69636b6e616d65223a22616461222c227075626b6579223a22",
      "packet.announce.padded" to "010107000001a212fdab0000001c0123456789abcdef7b226e69636b6e616d65223a22616461222c227075626b6579223a22cececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececececece",
      "packet.announce.isBroadcast" to "true",
      "packet.announce.decodedType" to "Optional(PopopxMeshKit.PopopxMeshMessageType.announce)",
      "packet.announce.decodeUnpadded" to "true",
      "packet.announce.decodePadded" to "true",
      "packet.announce.packetIDLen" to "16",
      "packet.emptyPayload.packetID" to "f006c35041e9ed8537b4208b58cd7ca1",
      "packet.emptyPayload.len" to "22",
      "packet.emptyPayload.unpadded" to "01260100000000000000000000000123456789abcdef",
      "packet.emptyPayload.padded" to "01260100000000000000000000000123456789abcdefeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaea",
      "packet.emptyPayload.isBroadcast" to "true",
      "packet.emptyPayload.decodedType" to "Optional(PopopxMeshKit.PopopxMeshMessageType.ping)",
      "packet.emptyPayload.decodeUnpadded" to "true",
      "packet.emptyPayload.decodePadded" to "true",
      "packet.emptyPayload.packetIDLen" to "16",
      "packet.zeroTimestamp.packetID" to "4237e1853da386964e61a13f5d86da8e",
      "packet.zeroTimestamp.len" to "23",
      "packet.zeroTimestamp.unpadded" to "0127ff0000000000000000000001000000000000000000",
      "packet.zeroTimestamp.padded" to "0127ff0000000000000000000001000000000000000000e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9",
      "packet.zeroTimestamp.isBroadcast" to "true",
      "packet.zeroTimestamp.decodedType" to "Optional(PopopxMeshKit.PopopxMeshMessageType.pong)",
      "packet.zeroTimestamp.decodeUnpadded" to "true",
      "packet.zeroTimestamp.decodePadded" to "true",
      "packet.zeroTimestamp.packetIDLen" to "16",
      "packet.unknownType.packetID" to "83c09e4ea24ccd92e4509a00a0856126",
      "packet.unknownType.len" to "41",
      "packet.unknownType.unpadded" to "017703000001a212fdab000000130123456789abcdef706f706f7078206d657368207061796c6f6164",
      "packet.unknownType.padded" to "017703000001a212fdab000000130123456789abcdef706f706f7078206d657368207061796c6f6164d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7",
      "packet.unknownType.isBroadcast" to "true",
      "packet.unknownType.decodedType" to "nil",
      "packet.unknownType.decodeUnpadded" to "true",
      "packet.unknownType.decodePadded" to "true",
      "packet.unknownType.packetIDLen" to "16",
    )

  /** packetBad — 5 rows, freeze order. */

  private val packetBad: List<Pair<String, String>> =
    listOf(

      "packetBad.recipientWidth" to "nil",
      "packetBad.version2" to "nil",
      "packetBad.senderWidth" to "nil",
      "packetBad.signatureWidth" to "nil",
      "packetBad.oversized" to "nil",
    )

  /** decode — 10 rows, freeze order. */

  private val decode: List<Pair<String, String>> =
    listOf(

      "decode.wrongVersion" to "nil",
      "decode.shorterThan22" to "nil",
      "decode.recipientFlagWithoutBytes" to "nil",
      "decode.signatureFlagWithoutBytes" to "nil",
      "decode.payloadOverrun" to "nil",
      "decode.trailingBytesIgnored" to "true",
      "decode.ttlZeroAccepted" to "true",
      "decode.empty" to "nil",
      "decode.garbage" to "nil",
      "decode.versionNotStored" to "true",
    )

  /** pad — 84 rows, freeze order. */

  private val pad: List<Pair<String, String>> =
    listOf(

      "pad.in" to "255",
      "pad.bucket" to "256",
      "pad.out" to "256",
      "pad.tail" to "000000000001",
      "pad.unpadLength" to "255",
      "pad.unpadStable" to "true",
      "pad.in#2" to "256",
      "pad.bucket#2" to "256",
      "pad.out#2" to "256",
      "pad.tail#2" to "000000000000",
      "pad.unpadLength#2" to "256",
      "pad.unpadStable#2" to "true",
      "pad.in#3" to "257",
      "pad.bucket#3" to "512",
      "pad.out#3" to "512",
      "pad.tail#3" to "ffffffffffff",
      "pad.unpadLength#3" to "257",
      "pad.unpadStable#3" to "true",
      "pad.in#4" to "511",
      "pad.bucket#4" to "512",
      "pad.out#4" to "512",
      "pad.tail#4" to "000000000001",
      "pad.unpadLength#4" to "511",
      "pad.unpadStable#4" to "true",
      "pad.in#5" to "512",
      "pad.bucket#5" to "512",
      "pad.out#5" to "512",
      "pad.tail#5" to "000000000000",
      "pad.unpadLength#5" to "512",
      "pad.unpadStable#5" to "true",
      "pad.in#6" to "513",
      "pad.bucket#6" to "1024",
      "pad.out#6" to "513",
      "pad.tail#6" to "000000000000",
      "pad.unpadLength#6" to "513",
      "pad.unpadStable#6" to "true",
      "pad.in#7" to "768",
      "pad.bucket#7" to "1024",
      "pad.out#7" to "768",
      "pad.tail#7" to "000000000000",
      "pad.unpadLength#7" to "768",
      "pad.unpadStable#7" to "true",
      "pad.in#8" to "769",
      "pad.bucket#8" to "1024",
      "pad.out#8" to "1024",
      "pad.tail#8" to "ffffffffffff",
      "pad.unpadLength#8" to "769",
      "pad.unpadStable#8" to "true",
      "pad.in#9" to "1023",
      "pad.bucket#9" to "1024",
      "pad.out#9" to "1024",
      "pad.tail#9" to "000000000001",
      "pad.unpadLength#9" to "1023",
      "pad.unpadStable#9" to "true",
      "pad.in#10" to "1024",
      "pad.bucket#10" to "1024",
      "pad.out#10" to "1024",
      "pad.tail#10" to "000000000000",
      "pad.unpadLength#10" to "1024",
      "pad.unpadStable#10" to "true",
      "pad.in#11" to "2047",
      "pad.bucket#11" to "2048",
      "pad.out#11" to "2048",
      "pad.tail#11" to "000000000001",
      "pad.unpadLength#11" to "2047",
      "pad.unpadStable#11" to "true",
      "pad.in#12" to "2048",
      "pad.bucket#12" to "2048",
      "pad.out#12" to "2048",
      "pad.tail#12" to "000000000000",
      "pad.unpadLength#12" to "2048",
      "pad.unpadStable#12" to "true",
      "pad.in#13" to "2049",
      "pad.bucket#13" to "2049",
      "pad.out#13" to "2049",
      "pad.tail#13" to "000000000000",
      "pad.unpadLength#13" to "2049",
      "pad.unpadStable#13" to "true",
      "unpad.empty" to " -> ",
      "unpad.lastByteZero" to "4100 -> 4100",
      "unpad.claimLongerThanBuffer" to "414205 -> 414205",
      "unpad.mixedTail" to "417a7a02 -> 417a7a02",
      "unpad.cleanTail" to "410202 -> 41",
      "unpad.singleByteTail" to "01 -> ",
    )

  /** envelope — 63 rows, freeze order. */

  private val envelope: List<Pair<String, String>> =
    listOf(

      "envelope.in.idHex" to "6d73672d31",
      "envelope.in.kind" to "text",
      "envelope.in.bodyHex" to "68656c6c6f",
      "envelope.in.sentAt" to "1795614944000",
      "envelope.utf8" to "%7b22626f6479223a2268656c6c6f222c226964223a226d73672d31222c226b696e64223a2274657874222c2273656e744174223a313739353631343934343030307d",
      "envelope.hex" to "7b22626f6479223a2268656c6c6f222c226964223a226d73672d31222c226b696e64223a2274657874222c2273656e744174223a313739353631343934343030307d",
      "envelope.roundTrip" to "equal",
      "envelope.decodeGarbage" to "true",
      "envelope.decodeNotOurShape" to "true",
      "envelope.in.idHex#2" to "6d73672d32",
      "envelope.in.kind#2" to "control",
      "envelope.in.bodyHex#2" to "424c455f41434b3a6d73672d31",
      "envelope.in.sentAt#2" to "0",
      "envelope.utf8#2" to "%7b22626f6479223a22424c455f41434b3a6d73672d31222c226964223a226d73672d32222c226b696e64223a22636f6e74726f6c222c2273656e744174223a307d",
      "envelope.hex#2" to "7b22626f6479223a22424c455f41434b3a6d73672d31222c226964223a226d73672d32222c226b696e64223a22636f6e74726f6c222c2273656e744174223a307d",
      "envelope.roundTrip#2" to "equal",
      "envelope.decodeGarbage#2" to "true",
      "envelope.decodeNotOurShape#2" to "true",
      "envelope.in.idHex#3" to "e6b688e681af2d31",
      "envelope.in.kind#3" to "text",
      "envelope.in.bodyHex#3" to "e4bda0e5a5bdefbc8ce4b896e7958c20f09f8e89",
      "envelope.in.sentAt#3" to "9999999999999",
      "envelope.utf8#3" to "%7b22626f6479223a22e4bda0e5a5bdefbc8ce4b896e7958c20f09f8e89222c226964223a22e6b688e681af2d31222c226b696e64223a2274657874222c2273656e744174223a393939393939393939393939397d",
      "envelope.hex#3" to "7b22626f6479223a22e4bda0e5a5bdefbc8ce4b896e7958c20f09f8e89222c226964223a22e6b688e681af2d31222c226b696e64223a2274657874222c2273656e744174223a393939393939393939393939397d",
      "envelope.roundTrip#3" to "equal",
      "envelope.decodeGarbage#3" to "true",
      "envelope.decodeNotOurShape#3" to "true",
      "envelope.in.idHex#4" to "6d73672d33",
      "envelope.in.kind#4" to "text",
      "envelope.in.bodyHex#4" to "71756f74652022206261636b736c617368205c20736c617368202f206e65776c696e65200a20746162200920753230323820e280a820753230323920e280a9",
      "envelope.in.sentAt#4" to "1",
      "envelope.utf8#4" to "%7b22626f6479223a2271756f7465205c22206261636b736c617368205c5c20736c617368205c2f206e65776c696e65205c6e20746162205c7420753230323820e280a820753230323920e280a9222c226964223a226d73672d33222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelope.hex#4" to "7b22626f6479223a2271756f7465205c22206261636b736c617368205c5c20736c617368205c2f206e65776c696e65205c6e20746162205c7420753230323820e280a820753230323920e280a9222c226964223a226d73672d33222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelope.roundTrip#4" to "equal",
      "envelope.decodeGarbage#4" to "true",
      "envelope.decodeNotOurShape#4" to "true",
      "envelope.in.idHex#5" to "6d73672d34",
      "envelope.in.kind#5" to "text",
      "envelope.in.bodyHex#5" to "",
      "envelope.in.sentAt#5" to "18446744073709551615",
      "envelope.utf8#5" to "%7b22626f6479223a22222c226964223a226d73672d34222c226b696e64223a2274657874222c2273656e744174223a31383434363734343037333730393535313631357d",
      "envelope.hex#5" to "7b22626f6479223a22222c226964223a226d73672d34222c226b696e64223a2274657874222c2273656e744174223a31383434363734343037333730393535313631357d",
      "envelope.roundTrip#5" to "equal",
      "envelope.decodeGarbage#5" to "true",
      "envelope.decodeNotOurShape#5" to "true",
      "envelope.in.idHex#6" to "6d73672d35",
      "envelope.in.kind#6" to "text",
      "envelope.in.bodyHex#6" to "63720d206261636b73706163650820666f726d0c203031012031661f2064656c7f206e627370c2a02061706f73272071756f746522206261636b736c6173685c20736c6173682f20656d6f6a69f09f988020636f6d62696e696e67cc81",
      "envelope.in.sentAt#6" to "1234567890123",
      "envelope.utf8#6" to "%7b22626f6479223a2263725c72206261636b73706163655c6220666f726d5c662030315c75303030312031665c75303031662064656c7f206e627370c2a02061706f73272071756f74655c22206261636b736c6173685c5c20736c6173685c2f20656d6f6a69f09f988020636f6d62696e696e67cc81222c226964223a226d73672d35222c226b696e64223a2274657874222c2273656e744174223a313233343536373839303132337d",
      "envelope.hex#6" to "7b22626f6479223a2263725c72206261636b73706163655c6220666f726d5c662030315c75303030312031665c75303031662064656c7f206e627370c2a02061706f73272071756f74655c22206261636b736c6173685c5c20736c6173685c2f20656d6f6a69f09f988020636f6d62696e696e67cc81222c226964223a226d73672d35222c226b696e64223a2274657874222c2273656e744174223a313233343536373839303132337d",
      "envelope.roundTrip#6" to "equal",
      "envelope.decodeGarbage#6" to "true",
      "envelope.decodeNotOurShape#6" to "true",
      "envelope.in.idHex#7" to "6d73672d36",
      "envelope.in.kind#7" to "control",
      "envelope.in.bodyHex#7" to "7b226964223a22696e6a6563746564227d",
      "envelope.in.sentAt#7" to "7",
      "envelope.utf8#7" to "%7b22626f6479223a227b5c2269645c223a5c22696e6a65637465645c227d222c226964223a226d73672d36222c226b696e64223a22636f6e74726f6c222c2273656e744174223a377d",
      "envelope.hex#7" to "7b22626f6479223a227b5c2269645c223a5c22696e6a65637465645c227d222c226964223a226d73672d36222c226b696e64223a22636f6e74726f6c222c2273656e744174223a377d",
      "envelope.roundTrip#7" to "equal",
      "envelope.decodeGarbage#7" to "true",
      "envelope.decodeNotOurShape#7" to "true",
    )

  /** announceOrder — 4 rows, freeze order. */

  private val announceOrder: List<Pair<String, String>> =
    listOf(

      "announce.distinctOrderings" to "1",
      "announce.ordering0" to "%333078207b227369676e707562223a2263646364636463646364636463646364636463646364636463646364636463646364636463646364636463646364636463646364636463646364636463646364222c227075626b6579223a2261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162222c226e69636b6e616d65223a22616461227d",
      "announce.sortedKeysForm" to "%7b226e69636b6e616d65223a22616461222c227075626b6579223a2261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162222c227369676e707562223a2263646364636463646364636463646364636463646364636463646364636463646364636463646364636463646364636463646364636463646364636463646364227d",
      "announce.decodesFromSorted" to "true",
    )

  /** announceShape — 10 rows, freeze order. */

  private val announceShape: List<Pair<String, String>> =
    listOf(

      "announceShape.pubkeyOnly.bytes" to "010107000001a212fdab0000004d00010203040506077b227075626b6579223a2261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162227d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d",
      "announceShape.pubkeyOnly.decodes" to "true",
      "announceShape.pubkeyNickname.bytes" to "010107000001a212fdab0000005e00010203040506077b227075626b6579223a2261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162222c226e69636b6e616d65223a22616461227d8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c",
      "announceShape.pubkeyNickname.decodes" to "true",
      "announceShape.allThree.bytes" to "010107000001a212fdab000000ab00010203040506077b227369676e707562223a2261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162222c227075626b6579223a2261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162222c226e69636b6e616d65223a22616461227d3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f",
      "announceShape.allThree.decodes" to "true",
      "announceShape.emptyNickname.bytes" to "010107000001a212fdab000000a800010203040506077b227369676e707562223a2261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162222c227075626b6579223a2261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162222c226e69636b6e616d65223a22227d424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242",
      "announceShape.emptyNickname.decodes" to "true",
      "announceShape.unknownKey.bytes" to "010107000001a212fdab0000005900010203040506077b226578747261223a227a222c227075626b6579223a2261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162616261626162227d91919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191919191",
      "announceShape.unknownKey.decodes" to "true",
    )

  /** envelopeDecode — 92 rows, freeze order. */

  private val envelopeDecode: List<Pair<String, String>> =
    listOf(

      "envelopeDecode.ourShape.in" to "7b22626f6479223a2268656c6c6f222c226964223a226d73672d31222c226b696e64223a2274657874222c2273656e744174223a313739353631343934343030307d",
      "envelopeDecode.ourShape" to "%6f6b2d3e7b22626f6479223a2268656c6c6f222c226964223a226d73672d31222c226b696e64223a2274657874222c2273656e744174223a313739353631343934343030307d",
      "envelopeDecode.reverseKeyOrder.in" to "7b2273656e744174223a312c226b696e64223a22636f6e74726f6c222c226964223a2269222c22626f6479223a2262227d",
      "envelopeDecode.reverseKeyOrder" to "%6f6b2d3e7b22626f6479223a2262222c226964223a2269222c226b696e64223a22636f6e74726f6c222c2273656e744174223a317d",
      "envelopeDecode.extraKey.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a312c227a7a223a397d",
      "envelopeDecode.extraKey" to "%6f6b2d3e7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.missingBody.in" to "7b226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.missingBody" to "nil",
      "envelopeDecode.missingSentAt.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874227d",
      "envelopeDecode.missingSentAt" to "nil",
      "envelopeDecode.unknownKind.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a22626f677573222c2273656e744174223a317d",
      "envelopeDecode.unknownKind" to "nil",
      "envelopeDecode.sentAtString.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a2231227d",
      "envelopeDecode.sentAtString" to "nil",
      "envelopeDecode.sentAtNegative.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a2d317d",
      "envelopeDecode.sentAtNegative" to "nil",
      "envelopeDecode.sentAtOverflow.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a31383434363734343037333730393535313631367d",
      "envelopeDecode.sentAtOverflow" to "nil",
      "envelopeDecode.emptyObject.in" to "7b7d",
      "envelopeDecode.emptyObject" to "nil",
      "envelopeDecode.array.in" to "5b312c325d",
      "envelopeDecode.array" to "nil",
      "envelopeDecode.notJSON.in" to "68656c6c6f",
      "envelopeDecode.notJSON" to "nil",
      "envelopeDecode.kindNumber.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a312c2273656e744174223a317d",
      "envelopeDecode.kindNumber" to "nil",
      "envelopeDecode.nullBody.in" to "7b22626f6479223a6e756c6c2c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.nullBody" to "nil",
      "envelopeDecode.trailingGarbage.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d207a7a",
      "envelopeDecode.trailingGarbage" to "nil",
      "envelopeDecode.trailingObject.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d7b22626f6479223a2263227d",
      "envelopeDecode.trailingObject" to "nil",
      "envelopeDecode.leadingWhitespace.in" to "20207b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d2020",
      "envelopeDecode.leadingWhitespace" to "%6f6b2d3e7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.duplicateBody.in" to "7b22626f6479223a2261222c22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.duplicateBody" to "%6f6b2d3e7b22626f6479223a2261222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.sentAtExponent.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a3165337d",
      "envelopeDecode.sentAtExponent" to "%6f6b2d3e7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a313030307d",
      "envelopeDecode.sentAtFloatIntegral.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a313030302e307d",
      "envelopeDecode.sentAtFloatIntegral" to "%6f6b2d3e7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a313030307d",
      "envelopeDecode.sentAtFloat.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a312e357d",
      "envelopeDecode.sentAtFloat" to "nil",
      "envelopeDecode.sentAtPlus.in" to "2b7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.sentAtPlus" to "nil",
      "envelopeDecode.bodyNumber.in" to "7b22626f6479223a352c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.bodyNumber" to "nil",
      "envelopeDecode.idNull.in" to "7b22626f6479223a2262222c226964223a6e756c6c2c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.idNull" to "nil",
      "envelopeDecode.nestedBody.in" to "7b22626f6479223a7b2261223a317d2c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.nestedBody" to "nil",
      "envelopeDecode.bareString.in" to "226a757374206120737472696e6722",
      "envelopeDecode.bareString" to "nil",
      "envelopeDecode.numberTop.in" to "3432",
      "envelopeDecode.numberTop" to "nil",
      "envelopeDecode.sentAtLeadingZero.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a30317d",
      "envelopeDecode.sentAtLeadingZero" to "nil",
      "envelopeDecode.sentAtTrailingDot.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a312e7d",
      "envelopeDecode.sentAtTrailingDot" to "nil",
      "envelopeDecode.sentAtExpNoDigits.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a31657d",
      "envelopeDecode.sentAtExpNoDigits" to "nil",
      "envelopeDecode.sentAtExpPlus.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a31652b337d",
      "envelopeDecode.sentAtExpPlus" to "%6f6b2d3e7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a313030307d",
      "envelopeDecode.sentAtExpNeg.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a31652d317d",
      "envelopeDecode.sentAtExpNeg" to "nil",
      "envelopeDecode.sentAtBareWord.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a6162637d",
      "envelopeDecode.sentAtBareWord" to "nil",
      "envelopeDecode.duplicateKind.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a22626f677573222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.duplicateKind" to "nil",
      "envelopeDecode.bom.in" to "efbbbf7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.bom" to "%6f6b2d3e7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.innerWhitespace.in" to "7b2022626f647922203a20226222202c2022696422203a20226922202c20226b696e6422203a20227465787422202c202273656e74417422203a2031207d",
      "envelopeDecode.innerWhitespace" to "%6f6b2d3e7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.unicodeEscape.in" to "7b22626f6479223a225c7532303238222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.unicodeEscape" to "%6f6b2d3e7b22626f6479223a22e280a8222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.badUnicodeEscape.in" to "7b22626f6479223a225c755a5a5a5a222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.badUnicodeEscape" to "nil",
      "envelopeDecode.controlInString.in" to "7b22626f6479223a22610162222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.controlInString" to "nil",
      "envelopeDecode.dupKindValidThenBogus.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c226b696e64223a22626f677573222c2273656e744174223a317d",
      "envelopeDecode.dupKindValidThenBogus" to "%6f6b2d3e7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.dupBodyThree.in" to "7b22626f6479223a2261222c22626f6479223a2262222c22626f6479223a2263222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.dupBodyThree" to "%6f6b2d3e7b22626f6479223a2261222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.dupBodyBadThenGood.in" to "7b22626f6479223a312c22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.dupBodyBadThenGood" to "nil",
      "envelopeDecode.dupSentAtBadThenGood.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a2278222c2273656e744174223a357d",
      "envelopeDecode.dupSentAtBadThenGood" to "nil",
      "envelopeDecode.dupSentAtGoodThenBad.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a352c2273656e744174223a2d317d",
      "envelopeDecode.dupSentAtGoodThenBad" to "%6f6b2d3e7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a357d",
      "envelopeDecode.dupId.in" to "7b22626f6479223a2262222c226964223a226931222c226964223a226932222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.dupId" to "%6f6b2d3e7b22626f6479223a2262222c226964223a226931222c226b696e64223a2274657874222c2273656e744174223a317d",
      "envelopeDecode.unterminated.in" to "7b22626f6479223a2262222c226964223a2269222c226b696e64223a2274657874222c2273656e744174223a31",
      "envelopeDecode.unterminated" to "nil",
    )

  /** control — 7 rows, freeze order. */

  private val control: List<Pair<String, String>> =
    listOf(

      "control.accept" to "SYS_POPOPX_REQ:popopx:/i len=37 -> type=48 bytes=5359535f504f504f50585f5245513a706f706f70783a2f696e76697465236162633a646566",
      "control.accept#2" to "SYS_POPOPX_ACK:0a0a0a0a0 len=79 -> type=49 bytes=5359535f504f504f50585f41434b3a30613061306130613061306130613061306130613061306130613061306130613061306130613061306130613061306130613061306130613061306130613061",
      "control.reject" to "SYS_POPOPX_ACK:tooshort len=23 -> nil",
      "control.accept#3" to "BLE_ACK:msg-42 len=14 -> type=50 bytes=424c455f41434b3a6d73672d3432",
      "control.reject#2" to "BLE_ACK: len=8 -> nil",
      "control.reject#3" to "BLE_ACK:xxxxxxxxxxxxxxxx len=137 -> nil",
      "control.reject#4" to "not a frame len=11 -> nil",
    )

  /** fragment — 28 rows, freeze order. */

  private val fragment: List<Pair<String, String>> =
    listOf(

      "fragment.count" to "3",
      "fragment.0.len" to "491",
      "fragment.0.head13" to "012007000001a212fdab000001d5010203040506070801020304050607080000000302",
      "fragment.0.parsed" to "key=72623859790382856/72623859790382856 index=0 total=3 type=2 dataLen=456",
      "fragment.1.len" to "491",
      "fragment.1.head13" to "012007000001a212fdab000001d5010203040506070801020304050607080001000302",
      "fragment.1.parsed" to "key=72623859790382856/72623859790382856 index=1 total=3 type=2 dataLen=456",
      "fragment.2.len" to "123",
      "fragment.2.head13" to "012007000001a212fdab00000065010203040506070801020304050607080002000302",
      "fragment.2.parsed" to "key=72623859790382856/72623859790382856 index=2 total=3 type=2 dataLen=88",
      "fragment.count#2" to "1",
      "fragment.0.len#2" to "135",
      "fragment.0.head13#2" to "012007000001a212fdab0000007101020304050607080a0b0c0d0e0f10110000000102",
      "fragment.0.parsed#2" to "key=72623859790382856/723685415333072913 index=0 total=1 type=2 dataLen=100",
      "fragment.count#3" to "1",
      "fragment.0.len#3" to "491",
      "fragment.0.head13#3" to "012007000001a212fdab000001d501020304050607080a0b0c0d0e0f10110000000102",
      "fragment.0.parsed#3" to "key=72623859790382856/723685415333072913 index=0 total=1 type=2 dataLen=456",
      "fragment.count#4" to "2",
      "fragment.0.len#4" to "491",
      "fragment.0.head13#4" to "012007000001a212fdab000001d501020304050607080a0b0c0d0e0f10110000000202",
      "fragment.0.parsed#4" to "key=72623859790382856/723685415333072913 index=0 total=2 type=2 dataLen=456",
      "fragment.1.len#2" to "36",
      "fragment.1.head13#2" to "012007000001a212fdab0000000e01020304050607080a0b0c0d0e0f10110001000202",
      "fragment.1.parsed#2" to "key=72623859790382856/723685415333072913 index=1 total=2 type=2 dataLen=1",
      "fragment.nil" to "payload=0 budget=469",
      "fragment.nil#2" to "payload=100 budget=13",
      "fragment.nil#3" to "payload=100 budget=469",
    )

  /** gcs — 20 rows, freeze order. */

  private val gcs: List<Pair<String, String>> =
    listOf(

      "gcs.deriveP(0.000244140625)" to "12",
      "gcs.deriveP(0.0009765625)" to "10",
      "gcs.deriveP(0.01)" to "7",
      "gcs.deriveP(1e-12)" to "20",
      "gcs.deriveP(0.5)" to "2",
      "gcs.deriveP(0.0)" to "20",
      "gcs.p" to "12",
      "gcs.m" to "262144",
      "gcs.included" to "64",
      "gcs.serialized" to "010c000400000732ac1f2d06a28d5b5aa3acf0a562aae939311e43ce2baf1578b794234821f74632ba62696b6e6fb997a7267a219ddd986554c289a0ed15e8b0d0f2a305afc57f826386183d7a1cf2898dcc30a58eb307841f6963b0e1e3b7604daf5518ac75f217177c7e06fa9834edf9ca00",
      "gcs.serializedLen" to "115",
      "gcs.containsKnown" to "true",
      "gcs.bucketFirst" to "172307",
      "gcs.bucketLast" to "106870",
      "gcs.roundTrip" to "true",
      "gcs.roundTripSerialized" to "010c000400000732ac1f2d06a28d5b5aa3acf0a562aae939311e43ce2baf1578b794234821f74632ba62696b6e6fb997a7267a219ddd986554c289a0ed15e8b0d0f2a305afc57f826386183d7a1cf2898dcc30a58eb307841f6963b0e1e3b7604daf5518ac75f217177c7e06fa9834edf9ca00",
      "gcs.falsePositiveRate" to "0.00035",
      "gcs.empty.serialized" to "010c00000001",
      "gcs.empty.containsAny" to "false",
      "gcs.empty.decoded" to "0",
    )

  /** config — 28 rows, freeze order. */

  private val config: List<Pair<String, String>> =
    listOf(

      "config.ttlDefault" to "7",
      "config.fragmentRelayTtlCap" to "7",
      "config.highDegreeThreshold" to "6",
      "config.denseBroadcastTtlCap" to "5",
      "config.fragmentSize" to "469",
      "config.maxMTU" to "512",
      "config.fragmentLifetime" to "30.0",
      "config.maxInFlightAssemblies" to "128",
      "config.relayMinDelay" to "0.008",
      "config.relayMaxDelay" to "0.025",
      "config.recentPacketWindow" to "30.0",
      "config.recentPacketMaxCount" to "100",
      "config.messageDedupMaxAge" to "300.0",
      "config.messageDedupMaxCount" to "1000",
      "config.scanOnDuration" to "5.0",
      "config.scanOffDuration" to "10.0",
      "config.announceInterval" to "4.0",
      "config.connectTimeout" to "8.0",
      "config.maxCentralLinks" to "6",
      "config.maintenanceInterval" to "5.0",
      "config.peerReachabilityTimeout" to "15.0",
      "config.bleAckTimeout" to "5.0",
      "config.smpAckTimeout" to "3.0",
      "config.serviceUUID" to "D3A6F5A1-2C4E-4B9A-8F7D-1E2C3B4A5960",
      "config.characteristicUUID" to "B7C1D4E2-5A6F-4B3C-9D8E-0F1A2B3C4D5E",
      "config.centralRestoreIdentifier" to "chat.popopx.mesh.central",
      "config.peripheralRestoreIdentifier" to "chat.popopx.mesh.peripheral",
      "config.noiseTransportOverhead" to "28",
    )

  /** Every section, in freeze order. */
  private val ALL: Map<String, List<Pair<String, String>>> =
    linkedMapOf("noise" to noise,
      "identity" to identity,
      "xxEmpty" to xxEmpty,
      "xxPayload" to xxPayload,
      "xxFail" to xxFail,
      "session" to session,
      "window" to window,
      "packet" to packet,
      "packetBad" to packetBad,
      "decode" to decode,
      "pad" to pad,
      "envelope" to envelope,
      "announceOrder" to announceOrder,
      "announceShape" to announceShape,
      "envelopeDecode" to envelopeDecode,
      "control" to control,
      "fragment" to fragment,
      "gcs" to gcs,
      "config" to config)

  /** The section names, so a test can assert the freeze it was written against. */
  val SECTION_NAMES: List<String> =
    listOf("noise", "identity", "xxEmpty", "xxPayload", "xxFail", "session", "window", "packet", "packetBad", "decode", "pad", "envelope", "announceOrder", "announceShape", "envelopeDecode", "control", "fragment", "gcs", "config")

  /** Row total, checked by a test so a truncated generation cannot pass as a match. */
  const val ROW_COUNT: Int = 601

  /** The rows of one section, in printed order, with values decoded back to text. */
  fun rows(section: String): List<Pair<String, String>> =
    ALL.getValue(section).map { it.first to value(it.second) }

  /** A row's value. A repeated label is suffixed `#2`, `#3`, ... in freeze order. */
  fun row(section: String, label: String): String =
    value(ALL.getValue(section).first { it.first == label }.second)

  fun rowsStartingWith(section: String, prefix: String): List<Pair<String, String>> =
    rows(section).filter { it.first.startsWith(prefix) }

  fun long(section: String, label: String): Long = row(section, label).toLong()

  fun int(section: String, label: String): Int = row(section, label).toInt()

  fun flag(section: String, label: String): Boolean = row(section, label) == "true"

  /** A row whose value is itself hex (a frame, a key, an encoded packet) as those bytes. */
  fun bytesOfHexRow(section: String, label: String): ByteArray = hexToBytes(row(section, label))

  /** UTF-8 bytes of a row, for feeding a codec whose input was a String on the Swift side. */
  fun utf8(section: String, label: String): ByteArray = row(section, label).toByteArray(Charsets.UTF_8)

  /** The label list is part of the evidence: a renamed or dropped row fails here, not silently. */
  fun requireRow(section: String, label: String) {
    check(ALL.getValue(section).any { it.first == label }) { "vector row missing: $section/$label" }
  }

  private fun value(stored: String): String =
    if (stored.startsWith("%")) String(hexToBytes(stored.drop(1)), Charsets.UTF_8) else stored

  private fun hexToBytes(hex: String): ByteArray =
    ByteArray(hex.length / 2) { index -> hex.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
}
