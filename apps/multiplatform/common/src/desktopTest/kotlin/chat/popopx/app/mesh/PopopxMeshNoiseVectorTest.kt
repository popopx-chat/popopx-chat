package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxMeshIdentity
import chat.popopx.common.mesh.PopopxNoiseCipherState
import chat.popopx.common.mesh.PopopxNoiseError
import chat.popopx.common.mesh.PopopxNoiseXXHandshake
import chat.popopx.common.mesh.meshHex
import chat.popopx.common.mesh.meshHexToBytes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Noise XX and the mesh identity layer, row for row against the vectors the iOS Swift code produced;
 * see `PopopxMeshSwiftVectors` for where those rows came from and what they do not prove.
 *
 * The seeds and ephemerals below are the vector tool's *inputs*, restated as the same formulas it
 * used. [identityRowsUseTheToolInputs] checks the two agree before a single byte of output is
 * compared, so a formula typed here differently cannot pass by testing a different handshake.
 */
internal class PopopxMeshNoiseVectorTest {
  private val aliceSeed = ByteArray(32) { it.toByte() }
  private val bobSeed = ByteArray(32) { (it + 7).toByte() }
  private val zeroSeed = ByteArray(32)
  private val aliceEphemeral = ByteArray(32) { (it * 3 + 1).toByte() }
  private val bobEphemeral = ByteArray(32) { (255 - it).toByte() }

  private val alice: PopopxMeshIdentity = PopopxMeshIdentity.of(aliceSeed)!!
  private val bob: PopopxMeshIdentity = PopopxMeshIdentity.of(bobSeed)!!

  @Test
  fun protocolNameAndConstants() {
    assertEquals(V.row("noise", "noise.name.ascii"), PopopxNoiseXXHandshake.PROTOCOL_NAME)
    assertEquals(
      V.int("noise", "noise.name.bytes"),
      PopopxNoiseXXHandshake.PROTOCOL_NAME.toByteArray(Charsets.UTF_8).size,
    )
    assertEquals(
      V.row("noise", "noise.name.hex"),
      PopopxNoiseXXHandshake.PROTOCOL_NAME.toByteArray(Charsets.UTF_8).meshHex(),
    )
    assertEquals(V.int("noise", "noise.encryptedPublicKeySize"), PopopxNoiseXXHandshake.ENCRYPTED_PUBLIC_KEY_SIZE)
    assertEquals(V.int("noise", "noise.frameOverhead"), PopopxNoiseCipherState.FRAME_OVERHEAD)
    assertEquals(V.long("noise", "noise.messageLimit"), PopopxNoiseCipherState.MESSAGE_LIMIT)
  }

  /** Four zero bytes then the counter little-endian, which is the whole of the transport nonce rule. */
  @Test
  fun transportNonceFraming() {
    for ((label, expected) in V.rowsStartingWith("noise", "noise.nonce(")) {
      val counter = label.substringAfter("(").substringBefore(")").toLong()
      assertEquals(expected, PopopxNoiseCipherState.nonceBytes(counter).meshHex(), label)
      assertEquals(counter, PopopxNoiseCipherState.counterOf(PopopxNoiseCipherState.nonceBytes(counter)))
    }
  }

  @Test
  fun identityRowsUseTheToolInputs() {
    assertEquals(
      listOf(aliceSeed.meshHex(), bobSeed.meshHex(), zeroSeed.meshHex()),
      V.rowsStartingWith("identity", "identity.seed").map { it.second },
    )
    assertEquals(aliceSeed.meshHex(), V.row("identity", "identity.seed"))
  }

  /** X25519 derivation and the eight-byte peer id, for all three seeds including the all-zero one. */
  @Test
  fun identityDerivationAndPeerID() {
    val groups = V.rows("identity").chunked(4)
    assertEquals(3, groups.size, "the freeze holds three identity groups")
    for (group in groups) {
      val (seedLabel, seedHex) = group[0]
      val seed = seedHex.meshHexToBytes() ?: throw AssertionError("seed row is not hex: $seedLabel")
      val identity = PopopxMeshIdentity.of(seed)
      assertEquals(group[1].second, identity?.publicKey?.meshHex(), seedLabel)
      val peer = identity?.peerID
      assertEquals(group[2].second, peer?.hex, seedLabel)
      assertEquals(group[3].second, peer?.u64?.let { PopopxMeshVerdicts.unsigned(it) }, seedLabel)
    }
    // The tool's three seeds are exactly the ones this file rebuilds by formula.
    assertEquals(alice.publicKey.meshHex(), V.row("identity", "identity.publicKey"))
    assertEquals(bob.publicKey.meshHex(), V.row("identity", "identity.publicKey#2"))
    assertNull(PopopxMeshIdentity.of(ByteArray(31)), "a 31-byte seed is not an identity")
  }

  @Test
  fun xxTranscriptWithEmptyPayloads() {
    assertTranscript("xxEmpty", "", "", "", "hello popopx mesh")
  }

  @Test
  fun xxTranscriptWithPayloads() {
    assertTranscript(
      section = "xxPayload",
      payload1 = "SYS_POPOPX_ACK:" + "0a".repeat(32),
      payload2 = "announce",
      payload3 = "BLE_ACK:message-1",
      transport = "{\"body\":\"x\",\"id\":\"y\",\"kind\":\"text\",\"sentAt\":1795614944000}",
    )
  }

  /**
   * One full XX in both directions, then transport frames under the split keys - the same sequence the
   * vector tool ran, message by message. The payloads are inputs here, so `payloadRead` is a round
   * trip rather than a restatement of the vector.
   */
  private fun assertTranscript(
    section: String,
    payload1: String,
    payload2: String,
    payload3: String,
    transport: String,
  ) {
    fun row(label: String): String = V.row(section, label)

    val initiator =
      PopopxNoiseXXHandshake.create(PopopxNoiseXXHandshake.Role.INITIATOR, alice, ephemeralSeed = aliceEphemeral)
    val responder =
      PopopxNoiseXXHandshake.create(PopopxNoiseXXHandshake.Role.RESPONDER, bob, ephemeralSeed = bobEphemeral)

    val msg1 = initiator.nextMessage(payload1.toByteArray(Charsets.UTF_8))
    assertEquals(row("xx.msg1"), msg1.meshHex(), "$section msg1")
    assertEquals(V.int(section, "xx.msg1.len"), msg1.size)
    val read1 = responder.consume(msg1)
    assertEquals(row("xx.msg1.payloadRead"), String(read1.payload, Charsets.UTF_8))
    assertEquals(row("xx.msg1.complete"), read1.complete.toString())

    val msg2 = responder.nextMessage(payload2.toByteArray(Charsets.UTF_8))
    assertEquals(row("xx.msg2"), msg2.meshHex(), "$section msg2")
    assertEquals(V.int(section, "xx.msg2.len"), msg2.size)
    val read2 = initiator.consume(msg2)
    assertEquals(row("xx.msg2.payloadRead"), String(read2.payload, Charsets.UTF_8))
    assertEquals(row("xx.msg2.complete"), read2.complete.toString())

    val msg3 = initiator.nextMessage(payload3.toByteArray(Charsets.UTF_8))
    assertEquals(row("xx.msg3"), msg3.meshHex(), "$section msg3")
    assertEquals(V.int(section, "xx.msg3.len"), msg3.size)
    val read3 = responder.consume(msg3)
    assertEquals(row("xx.msg3.payloadRead"), String(read3.payload, Charsets.UTF_8))
    assertEquals(row("xx.msg3.complete"), read3.complete.toString())
    assertTrue(initiator.isComplete && responder.isComplete)

    val fromInitiator = initiator.finalize()
    val fromResponder = responder.finalize()
    assertEquals(row("xx.peerStatic.initiatorSees"), fromInitiator.peerStaticPublicKey.meshHex())
    assertEquals(row("xx.peerStatic.responderSees"), fromResponder.peerStaticPublicKey.meshHex())
    assertEquals(row("xx.hash.initiator"), fromInitiator.handshakeHash.meshHex())
    assertEquals(row("xx.hash.responder"), fromResponder.handshakeHash.meshHex())
    assertEquals(row("xx.keys.initiator.send"), fromInitiator.transportKeys.sendKey.meshHex())
    assertEquals(row("xx.keys.initiator.receive"), fromInitiator.transportKeys.receiveKey.meshHex())
    assertEquals(row("xx.keys.responder.send"), fromResponder.transportKeys.sendKey.meshHex())
    assertEquals(row("xx.keys.responder.receive"), fromResponder.transportKeys.receiveKey.meshHex())

    val sealer = PopopxNoiseCipherState.of(fromInitiator.transportKeys.sendKey)!!
    val opener = PopopxNoiseCipherState.of(fromResponder.transportKeys.receiveKey)!!
    val plain = transport.toByteArray(Charsets.UTF_8)
    for (counter in longArrayOf(0L, 1L, 2L, 4_294_967_294L)) {
      val (ciphertext, tag) = sealer.encryptWithTag(plain, counter)
      val frame = PopopxNoiseCipherState.nonceBytes(counter) + ciphertext + tag
      assertEquals(row("xx.frame.nonce$counter"), frame.meshHex(), "counter $counter")
      assertEquals(row("xx.frame.nonce$counter.tag"), tag.meshHex(), "counter $counter")
      assertEquals(row("xx.frame.nonce$counter.opened"), String(opener.decrypt(frame, counter), Charsets.UTF_8))
    }

    // A flipped byte in the nonce prefix must fail the tag, not move the frame elsewhere. Measured on
    // iOS, it does neither: the prefix is ignored by this entry point, so the frame still opens.
    val tampered = sealer.encrypt(plain, 3).also { it[0] = (it[0].toInt() xor 1).toByte() }
    assertEquals(
      row("xx.frame.tamperedPrefix"),
      PopopxMeshVerdicts.probeOk("OPENED (unexpected)") { opener.decrypt(tampered, 3) },
    )

    val good = sealer.encrypt(plain, 7)
    assertEquals(row("xx.frame.nonceInFrame"), PopopxNoiseCipherState.counterInFrame(good).toString())
    val badPrefix = good.copyOf().also { it[2] = 0xFF.toByte() }
    assertEquals(
      row("xx.frame.nonceInFrame.badPrefix"),
      PopopxMeshVerdicts.probe("accepted (unexpected)") { PopopxNoiseCipherState.counterInFrame(badPrefix) },
    )
    assertEquals(
      row("xx.frame.tooShort"),
      PopopxMeshVerdicts.probe("accepted (unexpected)") {
        opener.decrypt(ByteArray(PopopxNoiseCipherState.FRAME_OVERHEAD - 1), 0)
      },
    )
  }

  /**
   * Every branch the handshake refuses, in the order the vector tool took them. Each probe gets a
   * fresh pair, because a rejected consume must leave the handshake usable - which is itself one of
   * the rows.
   */
  @Test
  fun xxFailureBranches() {
    fun row(label: String) = V.row("xxFail", label)
    fun pair(): Pair<PopopxNoiseXXHandshake, PopopxNoiseXXHandshake> =
      Pair(
        PopopxNoiseXXHandshake.create(
          PopopxNoiseXXHandshake.Role.INITIATOR, alice, protocolName = PopopxNoiseXXHandshake.PROTOCOL_NAME,
          ephemeralSeed = aliceEphemeral,
        ),
        PopopxNoiseXXHandshake.create(
          PopopxNoiseXXHandshake.Role.RESPONDER, bob, protocolName = PopopxNoiseXXHandshake.PROTOCOL_NAME,
          ephemeralSeed = bobEphemeral,
        ),
      )

    assertEquals(
      row("xxfail.protocolName"),
      PopopxMeshVerdicts.probe("accepted (unexpected)") {
        PopopxNoiseXXHandshake.create(
          PopopxNoiseXXHandshake.Role.INITIATOR, alice, protocolName = "Noise_XX_25519_AESGCM_SHA256",
          ephemeralSeed = aliceEphemeral,
        )
      },
    )
    assertEquals(row("xxfail.identity.shortSeed"), if (PopopxMeshIdentity.of(ByteArray(31)) == null) "nil" else "constructed")

    val first = pair()
    assertEquals(
      row("xxfail.turnOrder"),
      PopopxMeshVerdicts.probe("accepted (unexpected)") { first.second.nextMessage(ByteArray(0)) },
    )
    assertEquals(
      row("xxfail.consumeFirst"),
      PopopxMeshVerdicts.probe("accepted (unexpected)") { first.first.consume(ByteArray(32)) },
    )

    val truncated = pair()
    val msg1 = truncated.first.nextMessage(ByteArray(0))
    assertEquals(
      row("xxfail.truncatedMsg1"),
      PopopxMeshVerdicts.probe("accepted (unexpected)") { truncated.second.consume(msg1.copyOfRange(1, msg1.size)) },
    )
    assertEquals(
      row("xxfail.responderUsableAfterTruncate"),
      PopopxMeshVerdicts.probeOk("accepted") { truncated.second.consume(msg1) },
    )

    val zeros = pair().second
    assertEquals(
      row("xxfail.allZeroEphemeral"),
      PopopxMeshVerdicts.probe("accepted (unexpected)") { zeros.consume(ByteArray(32)) },
    )
    assertEquals(
      row("xxfail.allZeroThenMsg2"),
      PopopxMeshVerdicts.probe("accepted (unexpected)") { zeros.nextMessage(ByteArray(0)) },
    )

    assertEquals(
      row("xxfail.finalizeIncomplete"),
      PopopxMeshVerdicts.probe("accepted (unexpected)") { pair().first.finalize() },
    )

    val clean = pair()
    val m1 = clean.first.nextMessage(ByteArray(0))
    clean.second.consume(m1)
    val m2 = clean.second.nextMessage(ByteArray(0))
    clean.first.consume(m2)
    val m3 = clean.first.nextMessage(ByteArray(0))
    clean.second.consume(m3)
    assertEquals(V.int("xxFail", "xxfail.msg2.len"), m2.size)
    assertEquals(V.int("xxFail", "xxfail.msg3.len"), m3.size)

    val once = clean.first.finalize()
    val twice = clean.first.finalize()
    assertEquals(
      row("xxfail.finalizeIdempotent"),
      if (
        once.peerStaticPublicKey.contentEquals(twice.peerStaticPublicKey) &&
        once.handshakeHash.contentEquals(twice.handshakeHash) &&
        once.transportKeys.sendKey.contentEquals(twice.transportKeys.sendKey) &&
        once.transportKeys.receiveKey.contentEquals(twice.transportKeys.receiveKey)
      ) {
        "same"
      } else {
        "DIFFERENT"
      },
    )
    assertEquals(
      row("xxfail.messageAfterComplete"),
      PopopxMeshVerdicts.probe("accepted (unexpected)") { clean.first.nextMessage(ByteArray(0)) },
    )
    assertEquals(
      row("xxfail.responderMessageAfterComplete"),
      PopopxMeshVerdicts.probe("accepted (unexpected)") { clean.second.nextMessage(ByteArray(0)) },
    )
    assertEquals(
      row("xxfail.consumeAfterComplete"),
      PopopxMeshVerdicts.probe("accepted (unexpected)") { clean.second.consume(ByteArray(32)) },
    )
    assertEquals(row("xxfail.transcript"), "complete")

    // The numbers inside two of the refusals are part of the evidence, not only the case name.
    val short = PopopxNoiseError.MessageTooShort(31, 32)
    assertEquals("messageTooShort(bytes: 31, required: 32)", PopopxMeshVerdicts.swift(short))
  }

  private companion object {
    val V = PopopxMeshSwiftVectors
  }
}
