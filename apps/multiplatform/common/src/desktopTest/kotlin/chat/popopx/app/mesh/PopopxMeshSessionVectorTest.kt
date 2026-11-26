package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxMeshIdentity
import chat.popopx.common.mesh.PopopxNoiseCipherState
import chat.popopx.common.mesh.PopopxNoiseError
import chat.popopx.common.mesh.PopopxNoiseHandshakeResult
import chat.popopx.common.mesh.PopopxNoiseReplayWindow
import chat.popopx.common.mesh.PopopxNoiseSession
import chat.popopx.common.mesh.PopopxNoiseXXHandshake
import chat.popopx.common.mesh.meshHex
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * The transport layer above the handshake: how a counter travels, which frames the replay window
 * accepts, and the rule that a counter is only retired once a frame has actually opened.
 *
 * These rows are behavioural, not only byte-level, so they are the part of the port most likely to be
 * subtly wrong and least likely to show up as a mismatched hash. The counters, the window sizes and
 * the expected verdicts are all read back out of the vectors, so nothing about the shape of a
 * sequence was typed by hand.
 */
internal class PopopxMeshSessionVectorTest {
  private val aliceEphemeral = ByteArray(32) { (it * 3 + 1).toByte() }
  private val bobEphemeral = ByteArray(32) { (255 - it).toByte() }

  /** The same XX the `xxEmpty` section ran, with both parties' finished results. */
  private fun handshake(): Pair<PopopxNoiseHandshakeResult, PopopxNoiseHandshakeResult> {
    val initiator = PopopxNoiseXXHandshake.create(
      PopopxNoiseXXHandshake.Role.INITIATOR,
      PopopxMeshIdentity.of(ByteArray(32) { it.toByte() })!!,
      ephemeralSeed = aliceEphemeral,
    )
    val responder = PopopxNoiseXXHandshake.create(
      PopopxNoiseXXHandshake.Role.RESPONDER,
      PopopxMeshIdentity.of(ByteArray(32) { (it + 7).toByte() })!!,
      ephemeralSeed = bobEphemeral,
    )
    responder.consume(initiator.nextMessage(ByteArray(0)))
    initiator.consume(responder.nextMessage(ByteArray(0)))
    responder.consume(initiator.nextMessage(ByteArray(0)))
    return Pair(initiator.finalize(), responder.finalize())
  }

  /** A session per side, the way the engine would hold them after that transcript. */
  private fun sessions(
    window: Int = PopopxNoiseSession.DEFAULT_REPLAY_WINDOW,
  ): Pair<PopopxNoiseSession, PopopxNoiseSession> {
    val (fromInitiator, fromResponder) = handshake()
    return Pair(
      assertNotNull(PopopxNoiseSession.of(fromResponder.peerStaticPublicKey, fromInitiator.transportKeys, window)),
      assertNotNull(PopopxNoiseSession.of(fromInitiator.peerStaticPublicKey, fromResponder.transportKeys, window)),
    )
  }

  @Test
  fun keysAndChannelBindingHash() {
    val (fromInitiator, fromResponder) = handshake()
    assertEquals(
      V.row("session", "session.hash.agree"),
      if (fromInitiator.handshakeHash.contentEquals(fromResponder.handshakeHash)) "same" else "DIFFERENT",
    )
    assertEquals(V.row("session", "session.hash.hex"), fromInitiator.handshakeHash.meshHex())
    assertEquals(
      V.row("session", "session.keys.mirrored"),
      if (
        fromInitiator.transportKeys.sendKey.contentEquals(fromResponder.transportKeys.receiveKey) &&
        fromInitiator.transportKeys.receiveKey.contentEquals(fromResponder.transportKeys.sendKey)
      ) {
        "swapped"
      } else {
        "DIFFERENT"
      },
    )
    assertEquals(V.row("session", "session.peerKey.iSees"), fromInitiator.peerStaticPublicKey.meshHex())
    assertEquals(V.row("session", "session.peerKey.rSees"), fromResponder.peerStaticPublicKey.meshHex())
    assertEquals(
      V.row("session", "session.peerHexWidth"),
      if (fromResponder.peerStaticPublicKey.size == 32) "32bytes" else "OTHER",
    )
    // The binding hash this transcript agreed on is the one the xx section recorded, byte for byte.
    assertEquals(V.row("xxEmpty", "xx.hash.initiator"), V.row("session", "session.hash.hex"))
    assertEquals(V.row("xxEmpty", "xx.keys.initiator.send"), fromInitiator.transportKeys.sendKey.meshHex())
  }

  @Test
  fun constructionRefusals() {
    val (_, fromResponder) = handshake()
    val key = fromResponder.peerStaticPublicKey
    fun verdict(built: PopopxNoiseSession?) = if (built == null) "refused" else "built"
    assertEquals(
      V.row("session", "session.init.shortPeerKey"),
      verdict(PopopxNoiseSession.of(key.copyOfRange(0, 31), fromResponder.transportKeys)),
    )
    assertEquals(
      V.row("session", "session.init.zeroPeerKey"),
      verdict(PopopxNoiseSession.of(ByteArray(32), fromResponder.transportKeys)),
    )
    assertEquals(V.row("session", "session.init.window0"), verdict(PopopxNoiseSession.of(key, fromResponder.transportKeys, 0)))
    assertEquals(
      V.row("session", "session.init.windowMax"),
      verdict(PopopxNoiseSession.of(key, fromResponder.transportKeys, PopopxNoiseSession.MAX_REPLAY_WINDOW)),
    )
    assertEquals(
      V.row("session", "session.init.windowOverMax"),
      verdict(PopopxNoiseSession.of(key, fromResponder.transportKeys, PopopxNoiseSession.MAX_REPLAY_WINDOW + 1)),
    )
  }

  @Test
  fun countersOutOfFramesAndOutOfOrderDelivery() {
    val (send, recv) = sessions()
    val frames = (0 until 9).map { send.encrypt("m$it".toByteArray(Charsets.UTF_8)) }
    assertEquals(V.int("session", "session.sealed.count"), frames.size)
    assertEquals(
      V.row("session", "session.sealed.counters"),
      frames.joinToString(",") { PopopxNoiseCipherState.counterInFrame(it).toString() },
    )
    assertEquals(V.long("session", "session.sealed.messagesSent"), send.messagesSent)
    assertEquals(V.row("session", "session.sealed.frame0"), frames[0].meshHex())
    assertEquals(V.int("session", "session.sealed.len0"), frames[0].size)
    assertEquals(V.row("session", "session.sealed.peerCounterBeforeAny"), if (recv.peerCounter == null) "nil" else "NOT")

    fun deliver(label: String, index: Int, mutate: (ByteArray) -> ByteArray = { it }) =
      assertEquals(V.row("session", label), open(recv, frames[index], mutate), label)

    deliver("session.d.0", 0)
    deliver("session.d.1", 1)
    deliver("session.d.3.outOfOrder", 3)
    deliver("session.d.2.late", 2)
    deliver("session.d.2.replay", 2)
    deliver("session.d.8.jump", 8)
    deliver("session.d.4.middle", 4)
    deliver("session.d.4.again", 4)
    deliver("session.d.5.forgedTag", 5) { flipLast(it, 0x01) }
    deliver("session.d.5.afterForge", 5)
    deliver("session.d.6.badNoncePrefix", 6) { flip(it, 0, 0xFF) }
    deliver("session.d.7", 7)
    deliver("session.d.7.replay", 7)
    assertEquals(V.row("session", "session.end.peerCounter"), recv.peerCounter?.toString() ?: "nil")
    assertEquals(V.long("session", "session.end.messagesSent"), send.messagesSent)
  }

  /**
   * The mark-after-open rule on its own: a frame whose tag does not verify must leave the counter it
   * claimed still available, because otherwise anyone who can guess a peer's next counter can lock
   * the real message out. The vectors recorded the forgery at counter 9 and the real frame at 10, so
   * this replays the nine frames that got the sender there.
   */
  @Test
  fun aForgedFrameCannotRetireACounter() {
    val (send, hostile) = sessions()
    (0 until 9).forEach { send.encrypt("m$it".toByteArray(Charsets.UTF_8)) }
    val forged = flipLast(send.encrypt("x".toByteArray(Charsets.UTF_8)), 0x40)
    assertEquals(V.row("session", "session.hostile.forged"), openBare(hostile, forged))
    val late = send.encrypt("y".toByteArray(Charsets.UTF_8))
    assertEquals(
      V.row("session", "session.hostile.realAfterForge"),
      runCatching {
        "OPENED:" + String(hostile.decrypt(late), Charsets.UTF_8) +
          ":counter=" + PopopxNoiseCipherState.counterInFrame(late)
      }.fold(
        onSuccess = { it },
        onFailure = { "ERR:" + PopopxMeshVerdicts.swift(it as PopopxNoiseError) },
      ),
    )
  }

  /** The `tooOld` boundary needs a window the frames can actually fall out of, which is why size 8. */
  @Test
  fun smallWindowReachesItsOwnBoundary() {
    val (send, recv) = sessions(window = 8)
    val frames = (0 until 12).map { send.encrypt("s$it".toByteArray(Charsets.UTF_8)) }
    fun deliver(label: String, index: Int) = assertEquals(V.row("session", label), open(recv, frames[index]), label)
    deliver("session.small.0", 0)
    deliver("session.small.11", 11)
    deliver("session.small.3.inside", 3)
    for (index in 4..10) deliver("session.small.$index", index)
    deliver("session.small.3.tooOld", 3)
    deliver("session.small.4.tooOld", 4)
  }

  /**
   * The bit window in isolation. Each row is a chain of `counter=placement`, and the window's own size
   * is in the row that follows it, so the sequence is replayed from the evidence rather than restated.
   */
  @Test
  fun replayWindowSequences() {
    val rows = V.rows("window")
    val byLabel = rows.toMap()
    for ((label, chain) in rows) {
      if (label.endsWith(".end") || label.startsWith("window.fresh") || label.startsWith("window.first")) continue
      val end = byLabel.getValue("$label.end")
      val size = end.substringAfter("size=").trim().toInt()
      val window = PopopxNoiseReplayWindow(size)
      val verdicts =
        chain.split(" ").map { step ->
          val counter = step.substringBefore("=").toLong()
          val placement = PopopxMeshVerdicts.swift(window.place(counter))
          if (placement == "accept") window.mark(counter)
          "$counter=$placement"
        }
      assertEquals(chain, verdicts.joinToString(" "), label)
      assertEquals(
        end,
        "highest=${window.highest} start=${window.start} read=${window.hasReadAny} size=${window.size}",
        "$label end",
      )
    }

    val fresh = PopopxNoiseReplayWindow(8)
    assertEquals(V.long("window", "window.fresh.start"), fresh.start)
    assertEquals(V.row("window", "window.fresh.read"), fresh.hasReadAny.toString())
    assertEquals(V.row("window", "window.fresh.place"), PopopxMeshVerdicts.swift(fresh.place(0)))
    fresh.mark(0)
    assertEquals(
      V.row("window", "window.first.mark"),
      "highest=${fresh.highest} start=${fresh.start} place0=${PopopxMeshVerdicts.swift(fresh.place(0))}",
    )
  }

  /** The delivery probe's wording: the plaintext it opened, then what the peer counter became. */
  private fun open(recv: PopopxNoiseSession, frame: ByteArray, mutate: (ByteArray) -> ByteArray = { it }): String =
    runCatching { String(recv.decrypt(mutate(frame)), Charsets.UTF_8) }.fold(
      onSuccess = { "OPENED:$it:peer=${recv.peerCounter?.toString() ?: "nil"}" },
      onFailure = { "ERR:" + PopopxMeshVerdicts.swift(it as PopopxNoiseError) },
    )

  private fun openBare(target: PopopxNoiseSession, frame: ByteArray): String =
    runCatching { target.decrypt(frame) }.fold(
      onSuccess = { "OPENED (unexpected)" },
      onFailure = { "ERR:" + PopopxMeshVerdicts.swift(it as PopopxNoiseError) },
    )

  private fun flip(bytes: ByteArray, at: Int, mask: Int): ByteArray =
    bytes.copyOf().also { it[at] = (it[at].toInt() xor mask).toByte() }

  private fun flipLast(bytes: ByteArray, mask: Int): ByteArray = flip(bytes, bytes.size - 1, mask)

  private companion object {
    val V = PopopxMeshSwiftVectors
  }
}
