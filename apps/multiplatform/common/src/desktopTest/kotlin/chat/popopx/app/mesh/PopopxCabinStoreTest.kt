package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxBluetoothState
import chat.popopx.common.mesh.PopopxMeshBody
import chat.popopx.common.mesh.PopopxMeshEvent
import chat.popopx.common.mesh.PopopxMeshEventHub
import chat.popopx.common.mesh.PopopxMeshInbound
import chat.popopx.common.mesh.PopopxMeshPeer
import chat.popopx.common.mesh.PopopxMeshPeerID
import chat.popopx.common.mesh.PopopxMeshSendFailure
import chat.popopx.common.views.cabin.PopopxCabinStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The Cabin's own reduction of the mesh's event stream. iOS drives `PopopxMeshStateSource.ingest(_:)` the
 * same way in its tests — no radio, no hub — because the ordering, the dedup and the split between the
 * plaza and a private thread are the whole of what this type is.
 */
class PopopxCabinStoreTest {
  private fun peerID(seed: Int): PopopxMeshPeerID =
    PopopxMeshPeerID.of(ByteArray(8) { index -> if (index == 0) seed.toByte() else 0x10.toByte() })!!

  private fun peer(seed: Int, nickname: String? = null, direct: Boolean = true): PopopxMeshPeer =
    PopopxMeshPeer(
      peerID = peerID(seed),
      meshPublicKey = null,
      nickname = nickname,
      hopCount = if (direct) 0 else 2,
      lastSeenAtMillis = 1_700_000_000_000L,
      rssi = null,
      isDirect = direct,
    )

  private fun inbound(
    id: String,
    seed: Int,
    text: String,
    broadcast: Boolean,
  ): PopopxMeshInbound = PopopxMeshInbound(
    messageId = id,
    sender = peerID(seed),
    senderMeshPublicKey = null,
    recipient = if (broadcast) null else peerID(0x7F),
    hopCount = 1,
    isBroadcast = broadcast,
    receivedAtMillis = 1_700_000_000_000L,
    body = PopopxMeshBody.Text(text),
  )

  @Test
  fun peersArriveOnceAndStayOrderedByWireId() {
    val store = PopopxCabinStore(PopopxMeshEventHub())
    store.ingest(PopopxMeshEvent.PeerAppeared(peer(0x30, nickname = "third")))
    store.ingest(PopopxMeshEvent.PeerAppeared(peer(0x10, nickname = "first")))
    store.ingest(PopopxMeshEvent.PeerAppeared(peer(0x20, nickname = "second")))
    assertEquals(listOf("first", "second", "third"), store.peers.value.mapNotNull { it.nickname })

    // The same id again replaces in place rather than adding a row the plaza would show twice.
    store.ingest(PopopxMeshEvent.PeerAppeared(peer(0x20, nickname = "renamed")))
    assertEquals(3, store.peers.value.size)
    assertEquals(listOf("first", "renamed", "third"), store.peers.value.mapNotNull { it.nickname })

    store.ingest(PopopxMeshEvent.PeerDisappeared(peerID(0x10)))
    assertEquals(listOf("renamed", "third"), store.peers.value.mapNotNull { it.nickname })
  }

  @Test
  fun thePlazaAndADirectThreadAreSeparateStreamsAndControlFramesAreNeither() {
    val store = PopopxCabinStore(PopopxMeshEventHub())
    store.ingest(PopopxMeshEvent.Inbound(inbound("b1", 0x11, "plaza", broadcast = true)))
    store.ingest(PopopxMeshEvent.Inbound(inbound("d1", 0x22, "private", broadcast = false)))
    assertEquals(listOf("plaza"), store.broadcasts.value.map { it.text })
    assertEquals(listOf("private"), store.privateThreads.value.getValue(peerID(0x22).hex).map { it.text })
    assertEquals(1, store.privateThreads.value.size)

    val control = PopopxMeshInbound(
      messageId = "c1",
      sender = peerID(0x33),
      senderMeshPublicKey = null,
      recipient = null,
      hopCount = 1,
      isBroadcast = true,
      receivedAtMillis = 1_700_000_000_000L,
      body = PopopxMeshBody.Binary(byteArrayOf(1, 2, 3)),
    )
    store.ingest(PopopxMeshEvent.Inbound(control))
    assertEquals(1, store.broadcasts.value.size)
  }

  @Test
  fun aFloodKeepsOnlyTheNewestWindowAndNeverGrowsForever() {
    val store = PopopxCabinStore(PopopxMeshEventHub(), capacity = 3)
    (1..5).forEach { index ->
      store.ingest(PopopxMeshEvent.Inbound(inbound("m$index", 0x11, "text $index", broadcast = true)))
    }
    assertEquals(listOf("text 3", "text 4", "text 5"), store.broadcasts.value.map { it.text })
  }

  @Test
  fun aSendFailureMarksTheRowThatFailedAndNothingElse() {
    val store = PopopxCabinStore(PopopxMeshEventHub())
    store.noteLocal("mine", "local-1", failed = false)
    store.noteLocal("also mine", "local-2", failed = false)
    store.ingest(PopopxMeshEvent.SendFailed("local-1", peerID(0x11), PopopxMeshSendFailure.NoLinkToPeer))
    assertEquals(listOf(true, false), store.broadcasts.value.map { it.failed })
    assertTrue(store.broadcasts.value.first().mine)
  }

  @Test
  fun aPrivateSendFailureMarksOnlyThatThread() {
    val store = PopopxCabinStore(PopopxMeshEventHub())
    val key = peerID(0x22).hex
    store.noteLocalPrivate("to peer", key, "p1", failed = false)
    store.noteLocal("to plaza", "b1", failed = false)
    store.ingest(PopopxMeshEvent.SendFailed("p1", peerID(0x22), PopopxMeshSendFailure.LinkDropped))
    assertTrue(store.privateThreads.value.getValue(key).single().failed)
    assertFalse(store.broadcasts.value.single().failed)
  }

  @Test
  fun startingHoldsOneHubSlotAndStoppingHoldsNoneAndRetainsNothing() {
    val hub = PopopxMeshEventHub()
    val store = PopopxCabinStore(hub)
    store.ingest(PopopxMeshEvent.BluetoothState(PopopxBluetoothState.POWERED_ON))
    store.ingest(PopopxMeshEvent.PeerAppeared(peer(0x10)))
    store.noteLocal("kept?", "x1", failed = false)
    assertEquals(0, hub.subscriberCount)

    store.start()
    store.start()
    assertEquals(1, hub.subscriberCount)
    assertTrue(store.isPumping)

    store.stop()
    assertEquals(0, hub.subscriberCount)
    assertFalse(store.isPumping)
    assertEquals(PopopxBluetoothState.UNKNOWN, store.radioState.value)
    assertEquals(emptyList(), store.peers.value)
    assertEquals(emptyList(), store.broadcasts.value)
    assertEquals(emptyMap(), store.privateThreads.value)
  }
}
