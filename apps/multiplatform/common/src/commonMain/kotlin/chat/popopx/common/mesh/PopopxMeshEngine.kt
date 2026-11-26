package chat.popopx.common.mesh

import java.util.concurrent.Executors
import java.util.UUID
import kotlin.random.Random
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The mesh's only façade — a port of
 * `apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Engine/PopopxMeshEngine.swift`. It owns the radio, the
 * per-peer Noise sessions, the fragment path, the flood decisions and the identity key, and everything
 * above it talks to this type or to the event hub and never to the transport.
 *
 * Two invariants hold it together, and they are iOS' verbatim: a peer is only ever addressed by a public
 * key that a handshake or an announce proved, never by the 8-byte wire id alone; and every packet that is
 * neither for us nor seen before is re-flooded once, with one hop less, never back out of the link it came
 * in on.
 *
 * iOS is an `actor`. Here the same confinement is one thread — [dispatcher] — and every field below is
 * touched only from it, so a transport callback and a UI call cannot interleave inside one decision. The
 * difference that matters is *suspension*: iOS blocks an actor hop on `Task.sleep`, and a single thread
 * would be lost for the duration, so every wait in this file is a suspension (`delay`, a
 * [CompletableDeferred]) rather than a park. The relay jitter, the connect timeout and the maintenance
 * tick all yield the thread.
 *
 * The private-group layer (module 8) is not mounted here, so `groupState` and `groupMessage` frames are
 * decoded and ignored rather than applied, and an announce carries no `signpub` field. Routing, health
 * and pairing are held too: `deliver` does not notify a monitor, and a bare control packet type on the
 * wire is refused exactly as iOS refuses it.
 */
class PopopxMeshEngine(
  private val config: PopopxMeshConfig = PopopxMeshConfig.default,
  private val transport: PopopxBLETransporting = popopxBLETransport(config),
  private val hub: PopopxMeshEventHub = PopopxMeshEventHub.shared,
  private val secrets: PopopxMeshSecretStoring = PopopxMeshSecretStore(),
  /** Epoch milliseconds. Injectable so the TTL, ageing and handshake-timeout paths are testable. */
  private val nowMillis: () -> Long = { System.currentTimeMillis() },
  /** Seconds, drawn from `relayMinDelay...relayMaxDelay`. A test pins it to 0 to keep the flood synchronous. */
  private val relayDelay: () -> Double = { Random.nextDouble(config.relayMinDelay, config.relayMaxDelay) },
) : PopopxBLETransportDelegate {

  /**
   * Everything about one peer that is not the public key. iOS keeps this in a struct and writes the whole
   * value back after mutating a copy; here it is a reference held by the table, so a field assignment is
   * the write-back.
   */
  private class PeerRecord(
    val meshPublicKeyHex: String,
    var peerID: PopopxMeshPeerID,
    var nickname: String?,
    var hopCount: Int,
    var lastSeenAtMillis: Long,
    var isDirect: Boolean,
    val linkIDs: MutableSet<String> = LinkedHashSet(),
    var session: PopopxNoiseSession? = null,
    var handshake: PopopxNoiseXXHandshake? = null,
    /** When our msg1 went out, so a stalled initiator is retried instead of hanging forever. */
    var handshakeStartedAtMillis: Long? = null,
  ) {
    /** Engine convention, and iOS': `rssi` is always null here even though the link table records it. */
    val peer: PopopxMeshPeer
      get() = PopopxMeshPeer(
        peerID = peerID,
        meshPublicKey = meshPublicKeyHex.meshHexToBytes(),
        nickname = nickname,
        hopCount = hopCount,
        lastSeenAtMillis = lastSeenAtMillis,
        rssi = null,
        isDirect = isDirect,
      )
  }

  private val executor = Executors.newSingleThreadExecutor { runnable ->
    Thread(runnable, "popopx-mesh-engine").apply { isDaemon = true }
  }
  private val dispatcher: CoroutineDispatcher = executor.asCoroutineDispatcher()
  private val scope = CoroutineScope(SupervisorJob() + dispatcher)

  @Volatile private var identityValue: PopopxMeshIdentity = loadOrMakeIdentity(secrets)

  /** Engine-local view of the identity: reads are confined to [dispatcher] like everything else. */
  private val identity: PopopxMeshIdentity get() = identityValue

  private val peersByHex = HashMap<String, PeerRecord>()
  private val meshHexByPeerID = HashMap<String, String>()
  private val meshHexByLink = HashMap<String, String>()

  /**
   * Responder handshakes, keyed by the initiator's 8-byte wire id. Until msg3 decrypts we do not know the
   * initiator's public key, so nothing else can index them.
   */
  private val responders = HashMap<String, Pair<PopopxNoiseXXHandshake, Long>>()
  private val handshakeWaiters = HashMap<String, MutableList<CompletableDeferred<Unit>>>()

  @Volatile private var radioState: PopopxBluetoothState = PopopxBluetoothState.UNKNOWN
  @Volatile private var runningFlag = false
  private var maintenanceJob: Job? = null
  private var nickname: String? = null
  private var lastAnnounceAtMillis: Long? = null

  private var recentPackets = PopopxMeshDeduplicator(config, nowMillis)
  private var fragments = PopopxMeshFragmentAssembler(
    lifetime = config.fragmentLifetime,
    maxInFlight = config.maxInFlightAssemblies,
    maxReassembledBytes = config.maxReassembledBytes,
  )

  /**
   * Retransmit counts for frames the stack refused outright, keyed by packet id. Only a refusal is
   * retried: a frame that was handed over may have landed, and nothing on Android waits for the
   * acknowledgement that would tell us otherwise (module 4 is held in this port).
   */
  private val retransmits = HashMap<String, Int>()

  // MARK: - Identity

  /**
   * A node that cannot keep its static key loses its identity at the next launch, which silently
   * invalidates every pairing bound to it. iOS logs that and runs the fresh key anyway; this port runs the
   * same way, because refusing to start a mesh is a worse outcome for a user than a node that re-pairs.
   */
  private fun loadOrMakeIdentity(store: PopopxMeshSecretStoring): PopopxMeshIdentity {
    val stored = store.data(PopopxMeshSecretStore.IDENTITY_SERVICE, PopopxMeshSecretStore.IDENTITY_ACCOUNT)
    if (stored != null) {
      val restored = PopopxMeshIdentity.of(stored)
      if (restored != null) return restored
    }
    val fresh = PopopxMeshIdentity.generate()
    store.set(fresh.privateSeed, PopopxMeshSecretStore.IDENTITY_SERVICE, PopopxMeshSecretStore.IDENTITY_ACCOUNT)
    return fresh
  }

  val localMeshPublicKeyHex: String get() = identityValue.meshPublicKeyHex

  /**
   * Panic wipe (module 7), step 2's mesh half — iOS' `destroyIdentity()` (`Engine:157-164`): the static key
   * leaves the keystore and memory and every session dies with it. A fresh key is generated rather than a
   * null one, because the node keeps working as a node.
   *
   * Returns whether the persisted key is actually gone, which is what the wipe journal reports; the
   * in-memory half has no failure mode worth naming because it is this process's own memory.
   */
  suspend fun destroyIdentity(): Boolean = withContext(dispatcher) {
    identityValue = PopopxMeshIdentity.generate()
    peersByHex.clear()
    meshHexByPeerID.clear()
    meshHexByLink.clear()
    responders.clear()
    settleAllHandshakeWaiters()
    secrets.remove(PopopxMeshSecretStore.IDENTITY_SERVICE, PopopxMeshSecretStore.IDENTITY_ACCOUNT)
  }

  // MARK: - Lifecycle

  /**
   * Opens the radio. The global switch (`chat.popopx.mesh.enabled`) is read by the host, so a mesh that is
   * off never leaves a manager scanning.
   */
  suspend fun start(engineNickname: String? = null) {
    withContext(dispatcher) {
      if (runningFlag) return@withContext
      runningFlag = true
      nickname = engineNickname
      current = this@PopopxMeshEngine
      transport.setDelegate(this@PopopxMeshEngine)
      radioState = transport.state()
      transport.start()
      val interval = config.maintenanceInterval
      maintenanceJob = scope.launch {
        while (true) {
          delay((interval * 1000).toLong())
          maintain()
        }
      }
      publish(PopopxMeshEvent.BluetoothState(radioState))
    }
  }

  /**
   * Stops everything and forgets every session: with the fuse off the app must behave exactly as the stock
   * build, with no mesh state left in memory.
   */
  suspend fun stop() {
    withContext(dispatcher) {
      if (!runningFlag) return@withContext
      runningFlag = false
      maintenanceJob?.cancel()
      maintenanceJob = null
      if (current === this@PopopxMeshEngine) current = null
      transport.stop()
      transport.setDelegate(null)
      peersByHex.clear()
      meshHexByPeerID.clear()
      meshHexByLink.clear()
      responders.clear()
      settleAllHandshakeWaiters()
      recentPackets = PopopxMeshDeduplicator(config, nowMillis)
      fragments = PopopxMeshFragmentAssembler(
        lifetime = config.fragmentLifetime,
        maxInFlight = config.maxInFlightAssemblies,
        maxReassembledBytes = config.maxReassembledBytes,
      )
      retransmits.clear()
      radioState = PopopxBluetoothState.UNKNOWN
    }
  }

  /**
   * Releases the engine's thread. iOS' actor has no such step because the app keeps one alive for the
   * process; a test that builds an engine per case needs the thread to go with it.
   */
  internal fun shutdown() {
    runningFlag = false
    if (current === this) current = null
    scope.coroutineContext.cancel()
    executor.shutdownNow()
  }

  val isRunning: Boolean get() = runningFlag

  /** What the radio is doing, for the UI's "Bluetooth unavailable" copy. */
  val bluetoothState: PopopxBluetoothState get() = radioState

  // MARK: - Outbound

  /** One envelope, sealed in the Noise session with `meshPublicKeyHex` and put on the radio. */
  suspend fun send(envelope: PopopxMeshEnvelope, to: String) {
    withContext(dispatcher) {
      sendSealed(PopopxMeshEnvelope.encode(envelope), PopopxMeshMessageType.NOISE_ENCRYPTED, to, envelope.id)
    }
  }

  /** A control frame as an envelope, with an id we mint: iOS' `send(control:to:)` is exactly this. */
  suspend fun sendControl(frame: PopopxMeshControlFrame, to: String): String {
    val id = UUID.randomUUID().toString().lowercase()
    send(PopopxMeshEnvelope.control(id, frame), to)
    return id
  }

  /** The local `#mesh` plaza: unencrypted, flooded, never acknowledged. Returns the frame's dedup id. */
  suspend fun sendBroadcast(text: String): String = withContext(dispatcher) {
    if (!runningFlag) {
      throw PopopxMeshSendError(identityValue.peerID.hex, PopopxMeshSendFailure.RadioUnavailable(radioState))
    }
    val packet = packet(PopopxMeshMessageType.MESSAGE, outboundTTL(broadcast = true), null, text.toByteArray(Charsets.UTF_8))
    deliver(packet, packet.packetID.meshHex(), null, null)
    packet.packetID.meshHex()
  }

  /**
   * Asks a peer to identify itself again. The reply refreshes its reachability, so a ping is how a
   * 15-second silence gets evidence rather than a verdict.
   */
  suspend fun ping(meshPublicKeyHex: String) {
    withContext(dispatcher) {
      if (!runningFlag) return@withContext
      val peer = peersByHex[meshPublicKeyHex] ?: return@withContext
      val nonce = ByteArray(8).also { SECURE_RANDOM.nextBytes(it) }
      val packet = packet(PopopxMeshMessageType.PING, outboundTTL(broadcast = false), peer.peerID.bytes, nonce)
      deliver(packet, packet.packetID.meshHex(), peer, null)
    }
  }

  private suspend fun sendSealed(
    plaintext: ByteArray,
    type: PopopxMeshMessageType,
    to: String,
    messageId: String,
  ) {
    if (!runningFlag) throw PopopxMeshSendError(messageId, PopopxMeshSendFailure.RadioUnavailable(radioState))
    val session = openSession(to, messageId)
    val ciphertext = try {
      session.encrypt(plaintext)
    } catch (e: Throwable) {
      // The nonce space is spent, or the session was never keyed: drop it so the next send re-handshakes
      // rather than emitting frames this peer cannot read.
      peersByHex[to]?.session = null
      throw PopopxMeshSendError(messageId, PopopxMeshSendFailure.NoSessionWithPeer)
    }
    val peer = peersByHex[to] ?: throw PopopxMeshSendError(messageId, PopopxMeshSendFailure.NoSessionWithPeer)
    val packet = packet(type, outboundTTL(broadcast = false), peer.peerID.bytes, ciphertext)
    deliver(packet, messageId, peer, null)
    // module 4's ACK watchdog would record the outbound envelope here; the health monitor is not mounted
    // in this phase, so nothing waits on the reply and nothing is claimed about it.
  }

  /** The roster, ordered by wire id as iOS orders it, so two peers' lists compare equal. */
  suspend fun peers(): List<PopopxMeshPeer> = withContext(dispatcher) {
    peersByHex.values.map { it.peer }.sortedBy { it.peerID.hex }
  }

  suspend fun meshPublicKeyHexForPeerID(peerIDHex: String): String? = withContext(dispatcher) {
    meshHexByPeerID[peerIDHex.lowercase()]
  }

  /** Direct neighbours, which is what decides a broadcast's TTL. */
  internal suspend fun directNeighbourCount(): Int = withContext(dispatcher) {
    peersByHex.values.count { it.isDirect }
  }

  // MARK: - Sessions

  /**
   * The Noise session with a peer, handshaking on demand: a peer whose link just came up is reachable the
   * first time something tries to send, without anyone calling [beginHandshake].
   */
  private suspend fun openSession(meshPublicKeyHex: String, messageId: String): PopopxNoiseSession {
    peersByHex[meshPublicKeyHex]?.session?.let { return it }
    startHandshake(meshPublicKeyHex, messageId)
    waitForHandshake(meshPublicKeyHex, (config.connectTimeout * 1000).toLong())
    return peersByHex[meshPublicKeyHex]?.session
      ?: throw PopopxMeshSendError(messageId, PopopxMeshSendFailure.NoSessionWithPeer)
  }

  /**
   * Opens a Noise_XX session with a peer whose public key we know — from a `SYS_POPOPX_*` exchange, an
   * announce, or a previous contact. Safe to call while a handshake is in flight.
   */
  suspend fun beginHandshake(meshPublicKeyHex: String) {
    withContext(dispatcher) {
      runCatching { startHandshake(meshPublicKeyHex, meshPublicKeyHex) }
    }
  }

  private suspend fun startHandshake(meshPublicKeyHex: String, messageId: String) {
    if (!runningFlag) throw PopopxMeshSendError(messageId, PopopxMeshSendFailure.RadioUnavailable(radioState))
    val peer = peerRecord(meshPublicKeyHex, messageId)
    if (peer.session != null || peer.handshake != null) return
    val handshake = PopopxNoiseXXHandshake.initiator(identityValue)
    val message = try {
      handshake.nextMessage(ByteArray(0))
    } catch (e: Throwable) {
      throw PopopxMeshSendError(messageId, PopopxMeshSendFailure.NoSessionWithPeer)
    }
    peer.handshake = handshake
    peer.handshakeStartedAtMillis = nowMillis()
    val packet = packet(PopopxMeshMessageType.NOISE_HANDSHAKE, outboundTTL(broadcast = false), peer.peerID.bytes, message)
    deliver(packet, packet.packetID.meshHex(), peer, null)
  }

  /**
   * The record for a peer named by public key, created from that key if we have never seen it. A malformed
   * key is refused here, which is the one place a caller-supplied hex becomes mesh state, so it is also the
   * one place it has to be checked.
   */
  private fun peerRecord(meshPublicKeyHex: String, messageId: String): PeerRecord {
    peersByHex[meshPublicKeyHex]?.let { return it }
    if (meshPublicKeyHex.length != PopopxMeshIdentity.KEY_BYTE_COUNT * 2) {
      throw PopopxMeshSendError(messageId, PopopxMeshSendFailure.NoSessionWithPeer)
    }
    val peerPublicKey = meshPublicKeyHex.meshHexToBytes()
      ?: throw PopopxMeshSendError(messageId, PopopxMeshSendFailure.NoSessionWithPeer)
    val created = PeerRecord(
      meshPublicKeyHex = meshPublicKeyHex,
      peerID = PopopxMeshPeerID.fromPublicKey(peerPublicKey),
      nickname = null,
      hopCount = 0,
      lastSeenAtMillis = nowMillis(),
      isDirect = false,
    )
    peersByHex[meshPublicKeyHex] = created
    meshHexByPeerID[created.peerID.hex] = meshPublicKeyHex
    return created
  }

  private suspend fun waitForHandshake(meshPublicKeyHex: String, timeoutMillis: Long) {
    if (peersByHex[meshPublicKeyHex]?.session != null) return
    val waiter = CompletableDeferred<Unit>()
    handshakeWaiters.getOrPut(meshPublicKeyHex) { mutableListOf() }.add(waiter)
    val timer = scope.launch {
      delay(timeoutMillis)
      settleHandshakeWaiters(meshPublicKeyHex)
    }
    try {
      waiter.await()
    } finally {
      timer.cancel()
      handshakeWaiters[meshPublicKeyHex]?.remove(waiter)
    }
  }

  /**
   * Resumes everyone waiting on this peer. Idempotent, so a completion and its timeout racing is harmless:
   * only the first caller finds the waiters.
   */
  private fun settleHandshakeWaiters(meshPublicKeyHex: String) {
    val waiters = handshakeWaiters.remove(meshPublicKeyHex) ?: return
    for (waiter in waiters) waiter.complete(Unit)
  }

  private fun settleAllHandshakeWaiters() {
    for (meshPublicKeyHex in handshakeWaiters.keys.toList()) settleHandshakeWaiters(meshPublicKeyHex)
  }

  // MARK: - Delivery

  /**
   * Puts one packet on the radio, fragmented if a link cannot take it whole. [origin] is the link the packet
   * arrived on, for a relay: a frame is never sent back the way it came. A peer with a live link of ours
   * gets it there and only there; anything else is flooded and dedup keeps the loops out of it.
   *
   * The answer is "was any frame of this packet handed to the radio".
   */
  private suspend fun deliver(
    packet: PopopxMeshPacket,
    messageId: String,
    peer: PeerRecord?,
    origin: String?,
  ): Boolean {
    if (!runningFlag) {
      publish(PopopxMeshEvent.SendFailed(messageId, peer?.peerID, PopopxMeshSendFailure.RadioUnavailable(radioState)))
      return false
    }
    var writable = transport.links().filter { it.canSend && it.linkID != origin }
    if (peer != null && peer.linkIDs.isNotEmpty()) {
      val direct = writable.filter { peer.linkIDs.contains(it.linkID) }
      if (direct.isNotEmpty()) writable = direct
    }
    if (writable.isEmpty()) {
      publish(PopopxMeshEvent.SendFailed(messageId, peer?.peerID, PopopxMeshSendFailure.NoLinkToPeer))
      return false
    }
    val encoded = packet.encoded(padded = false)
      ?: run {
        publish(
          PopopxMeshEvent.SendFailed(
            messageId,
            peer?.peerID,
            PopopxMeshSendFailure.Oversized(packet.payload.size, U_SHORT_MAX),
          )
        )
        return false
      }
    // A payload past the ceiling a receiving node is allowed to hold for one stream is deleted at the far
    // end without a word: the fragment table refuses it and the sender hears nothing, so the only place
    // this node can still say so is on the way out. A relayed copy is not ours to judge — we are not the
    // node that has to reassemble it.
    if (origin == null && packet.payload.size > config.maxReassembledBytes) {
      publish(
        PopopxMeshEvent.SendFailed(
          messageId,
          peer?.peerID,
          PopopxMeshSendFailure.Oversized(packet.payload.size, config.maxReassembledBytes),
        )
      )
      return false
    }
    val frames = framesOf(packet, encoded, writable)
    var handedOff = false
    for (frame in frames) {
      for (link in writable) {
        if (frame.size > link.usablePayloadBytes) {
          publish(
            PopopxMeshEvent.SendFailed(
              messageId,
              peer?.peerID,
              PopopxMeshSendFailure.Oversized(frame.size, link.usablePayloadBytes),
            )
          )
          continue
        }
        if (transport.send(frame, link.linkID)) handedOff = true
      }
    }
    if (!handedOff) {
      publish(PopopxMeshEvent.SendFailed(messageId, peer?.peerID, PopopxMeshSendFailure.NoLinkToPeer))
      return false
    }
    // Remember it as soon as we transmit, so our own flood coming back is dropped, and only after the
    // fragments exist, so a failed send stays retryable.
    recentPackets.note(packet.packetID)
    return true
  }

  /**
   * One frame when the smallest link can take it, otherwise a fragment stream. The budget is the link's
   * payload minus what every fragment packet itself carries: the fixed header plus the sender and
   * recipient fields, which the fragmenter keeps so a relay still dedups the run.
   */
  private fun framesOf(
    packet: PopopxMeshPacket,
    encoded: ByteArray,
    links: List<PopopxBLELink>,
  ): List<ByteArray> {
    val smallest = if (links.isEmpty()) 0 else links.minOf { it.usablePayloadBytes }
    if (encoded.size <= smallest) return listOf(encoded)
    val frameOverhead = PopopxMeshPacket.HEADER_SIZE + PopopxMeshPeerID.BYTE_COUNT * 2
    val budget = smallest - frameOverhead
    if (budget <= PopopxMeshFragmentHeader.BYTE_COUNT) return listOf(encoded)
    val fragments = PopopxMeshFragmenter.fragment(packet, budget) ?: return listOf(encoded)
    return fragments.mapNotNull { it.encoded(padded = false) }
  }

  /**
   * A dense neighbourhood makes a full-TTL broadcast the most expensive frame in the mesh, so broadcasts
   * are clamped. Directed traffic keeps its TTL: losing hops there means losing the message.
   */
  private fun outboundTTL(broadcast: Boolean): Int {
    if (!broadcast) return config.ttlDefault
    val neighbours = peersByHex.values.count { it.isDirect }
    if (neighbours <= config.highDegreeThreshold) return config.ttlDefault
    return minOf(config.ttlDefault, config.denseBroadcastTtlCap)
  }

  private fun packet(
    type: PopopxMeshMessageType,
    ttl: Int,
    recipientID: ByteArray?,
    payload: ByteArray,
  ): PopopxMeshPacket = PopopxMeshPacket(
    version = PROTOCOL_VERSION,
    type = type.wireValue,
    ttl = ttl,
    timestamp = nowMillis(),
    senderID = identityValue.peerID.bytes,
    recipientID = recipientID,
    payload = payload,
  )

  // MARK: - Inbound

  internal suspend fun receive(data: ByteArray, linkID: String) {
    withContext(dispatcher) { receiveOnThread(data, linkID) }
  }

  private suspend fun receiveOnThread(data: ByteArray, linkID: String) {
    if (!runningFlag) return
    val packet = PopopxMeshPacket.decode(data) ?: return
    if (packet.senderID.size != PopopxMeshPeerID.BYTE_COUNT) return
    if (packet.senderPeerID == identityValue.peerID) return
    // The id is claimed, not remembered: taking it up-front put the packet in the flood window before
    // this node knew whether it could do anything with it, and the retransmission that would have
    // finished the job — the sibling fragment of a stream with a hole in it, the copy that arrives after
    // the handshake it was waiting on — carries the same bytes, so it was eaten for the rest of the
    // window. A claim holds for the short window instead, and only a packet this node actually used or
    // forwarded is promoted to the flood memory.
    if (!recentPackets.claim(packet.packetID)) return

    val hopCount = maxOf(0, config.ttlDefault - packet.ttl)
    val sender = packet.senderPeerID
    if (sender != null) {
      val meshHex = meshHexByPeerID[sender.hex]
      if (meshHex != null) touch(meshHex, hopCount, linkID)
    }
    var used = false
    val isForUs = packet.isBroadcast || packet.recipientPeerID == identityValue.peerID
    if (isForUs) used = consume(packet, hopCount, linkID)
    val forwarded = relay(packet, linkID)
    if (used || forwarded) recentPackets.confirm(packet.packetID)
  }

  /**
   * true when this node did something with the packet: showed it, applied it, or answered it. false means
   * the same bytes are worth another look, which is what the claim's short window buys. A branch that has
   * nothing to retry — an unknown frame type, an announce that will parse the same way every time —
   * reports true, because repeating the work is not a second chance at delivery, it is a second copy of
   * the same failure.
   */
  private suspend fun consume(packet: PopopxMeshPacket, hopCount: Int, linkID: String): Boolean {
    return when (packet.decodedType) {
      // A handshake that was refused is refused on its bytes, not on this node's timing: we either have
      // the state it continues from or we tore it down and the peer must start a fresh exchange, which
      // arrives as different bytes under a different id.
      PopopxMeshMessageType.NOISE_HANDSHAKE -> {
        consumeHandshake(packet, hopCount, linkID)
        true
      }
      PopopxMeshMessageType.NOISE_ENCRYPTED -> consumeEncrypted(packet, hopCount, linkID)
      PopopxMeshMessageType.FRAGMENT -> consumeFragment(packet, hopCount, linkID)
      PopopxMeshMessageType.ANNOUNCE -> {
        consumeAnnounce(packet, hopCount, linkID)
        true
      }
      PopopxMeshMessageType.MESSAGE -> {
        consumeBroadcastMessage(packet, hopCount)
        true
      }
      PopopxMeshMessageType.PING -> {
        consumePing(packet)
        true
      }
      PopopxMeshMessageType.PONG -> true
      PopopxMeshMessageType.LEAVE -> {
        consumeLeave(packet)
        true
      }
      // The group layer is not mounted in this phase: a group frame is still relayed by `relay`, which is
      // the whole point of it being its own packet type, and we simply cannot read it. Nothing to retry.
      PopopxMeshMessageType.GROUP_STATE, PopopxMeshMessageType.GROUP_MESSAGE -> true
      // These ride `.noiseEncrypted`; a bare one on the wire is not ours to trust.
      PopopxMeshMessageType.PAIRING_REQUEST,
      PopopxMeshMessageType.PAIRING_ACK,
      PopopxMeshMessageType.DELIVERY_ACK,
      -> true
      null -> true
    }
  }

  private suspend fun consumeHandshake(packet: PopopxMeshPacket, hopCount: Int, linkID: String) {
    val sender = packet.senderPeerID ?: return
    val knownMeshPublicKeyHex = meshHexByPeerID[sender.hex]
    val pending = knownMeshPublicKeyHex?.let { peersByHex[it]?.handshake }
    if (packet.recipientPeerID == identityValue.peerID && knownMeshPublicKeyHex != null && pending != null) {
      // We sent msg1: this is msg2, or the msg3 of a session the peer opened with us.
      val reply = try {
        pending.consume(packet.payload)
      } catch (e: Throwable) {
        peersByHex[knownMeshPublicKeyHex]?.handshake = null
        peersByHex[knownMeshPublicKeyHex]?.handshakeStartedAtMillis = null
        settleHandshakeWaiters(knownMeshPublicKeyHex)
        return
      }
      applyHandshakeReply(reply, pending, sender, knownMeshPublicKeyHex, hopCount, linkID)
      return
    }
    // msg1, from a peer we have never named: we are the responder, and the initiator's public key is not
    // knowable yet, because msg1 carries no identity at all.
    val responder = PopopxNoiseXXHandshake.responder(identityValue)
    val reply = try {
      responder.consume(packet.payload)
    } catch (e: Throwable) {
      return
    }
    if (reply.complete) responders.remove(sender.hex) else responders[sender.hex] = responder to nowMillis()
    applyHandshakeReply(reply, responder, sender, knownMeshPublicKeyHex, hopCount, linkID)
  }

  /**
   * Applies one handshake step: sends whatever the handshake produced, keeps the in-flight state for the
   * peer it belongs to, and installs the session once the peer's static key is proven.
   */
  private suspend fun applyHandshakeReply(
    reply: PopopxNoiseHandshakeMessage,
    handshake: PopopxNoiseXXHandshake,
    sender: PopopxMeshPeerID,
    knownMeshPublicKeyHex: String?,
    hopCount: Int,
    linkID: String,
  ) {
    if (!reply.complete && knownMeshPublicKeyHex != null && peersByHex[knownMeshPublicKeyHex]?.session == null) {
      peersByHex[knownMeshPublicKeyHex]?.handshake = handshake
    }
    if (reply.payload.isNotEmpty()) {
      val packet = packet(PopopxMeshMessageType.NOISE_HANDSHAKE, outboundTTL(broadcast = false), sender.bytes, reply.payload)
      deliverKnownPeer(packet, packet.packetID.meshHex(), sender.hex, linkID)
    }
    if (!reply.complete) return
    responders.remove(sender.hex)
    val result = try {
      handshake.finalize()
    } catch (e: Throwable) {
      // Handshake completed but the keys are unusable: forget the in-flight state and let a waiter go.
      if (knownMeshPublicKeyHex != null) {
        peersByHex[knownMeshPublicKeyHex]?.handshake = null
        peersByHex[knownMeshPublicKeyHex]?.handshakeStartedAtMillis = null
        settleHandshakeWaiters(knownMeshPublicKeyHex)
      }
      return
    }
    val session = PopopxNoiseSession.of(
      peerPublicKey = result.peerStaticPublicKey,
      keys = result.transportKeys,
      replayWindow = NOISE_REPLAY_WINDOW,
    ) ?: return
    val meshHex = result.peerStaticPublicKey.meshHex()
    val derived = PopopxMeshPeerID.fromPublicKey(result.peerStaticPublicKey)
    if (derived != sender) {
      // The key that came out of the handshake does not hash to the id on the wire, so this is not the peer
      // it claims to be. No session is stored under either name.
      settleHandshakeWaiters(knownMeshPublicKeyHex ?: meshHex)
      return
    }
    val record = peersByHex[meshHex] ?: PeerRecord(
      meshPublicKeyHex = meshHex,
      peerID = derived,
      nickname = null,
      hopCount = hopCount,
      lastSeenAtMillis = nowMillis(),
      isDirect = false,
    ).also { peersByHex[meshHex] = it }
    record.session = session
    record.handshake = null
    record.handshakeStartedAtMillis = null
    touch(hopCount, linkID, record)
    meshHexByPeerID[derived.hex] = meshHex
    publish(PopopxMeshEvent.PeerAppeared(record.peer))
    settleHandshakeWaiters(meshHex)
    if (knownMeshPublicKeyHex != null && knownMeshPublicKeyHex != meshHex) settleHandshakeWaiters(knownMeshPublicKeyHex)
  }

  /**
   * Sends to a peer named only by its 8-byte wire id: by the hex we already bound it to if we know it, and
   * otherwise out of every writable link that can take the frame, because a handshake reply has to leave on
   * the link it came in from before any peer-to-key binding exists.
   */
  private suspend fun deliverKnownPeer(
    packet: PopopxMeshPacket,
    messageId: String,
    peerIDHex: String,
    on: String?,
  ) {
    val meshHex = meshHexByPeerID[peerIDHex]
    if (meshHex != null) {
      deliver(packet, messageId, peersByHex[meshHex], null)
      return
    }
    val data = packet.encoded(padded = false)
    val targets = transport.links().filter { it.canSend && (on == null || it.linkID == on) }
    if (data == null || targets.none { data.size <= it.usablePayloadBytes }) {
      publish(
        PopopxMeshEvent.SendFailed(
          messageId,
          PopopxMeshPeerID.of(packet.senderID),
          PopopxMeshSendFailure.NoLinkToPeer,
        )
      )
      return
    }
    for (link in targets.filter { data.size <= it.usablePayloadBytes }) transport.send(data, link.linkID)
    recentPackets.note(packet.packetID)
  }

  private suspend fun consumeEncrypted(packet: PopopxMeshPacket, hopCount: Int, linkID: String): Boolean {
    val sender = packet.senderPeerID
    val meshHex = sender?.let { meshHexByPeerID[it.hex] }
    val session = meshHex?.let { peersByHex[it]?.session }
    if (sender == null || meshHex == null || session == null) {
      // Retryable, and this is the case the mesh loses messages on: a private frame sent while the
      // handshake was still in flight. The bytes are fine — this node just cannot read them *yet*, and
      // the copy that arrives after the session exists is the one that lands.
      return false
    }
    if (packet.recipientPeerID != identityValue.peerID) {
      // Directed at someone else: nothing may credit a neighbour for traffic that was not ours, and we
      // cannot read it anyway.
      return true
    }
    val plaintext = try {
      session.decrypt(packet.payload)
    } catch (e: Throwable) {
      // A replay or a tampered frame. The session's window is untouched, because marking a counter the
      // peer did not actually spend would lock out the real message that follows.
      return true
    }
    touch(meshHex, hopCount, linkID)
    val envelope = PopopxMeshEnvelope.decode(plaintext) ?: return true
    val body = when (envelope.kind) {
      PopopxMeshEnvelope.Kind.TEXT -> PopopxMeshBody.Text(envelope.body)
      PopopxMeshEnvelope.Kind.CONTROL -> {
        val frame = PopopxMeshControlFrame.of(envelope.body) ?: return true
        PopopxMeshBody.Control(frame)
      }
    }
    publish(
      PopopxMeshEvent.Inbound(
        PopopxMeshInbound(
          messageId = envelope.id,
          sender = sender,
          senderMeshPublicKey = meshHex.meshHexToBytes(),
          recipient = packet.recipientPeerID,
          hopCount = hopCount,
          isBroadcast = false,
          receivedAtMillis = nowMillis(),
          body = body,
        )
      )
    )
    // Everything we can read and that is not itself an acknowledgement gets acknowledged.
    if (body is PopopxMeshBody.Control && body.frame is PopopxMeshControlFrame.DeliveryAck) return true
    acknowledge(envelope.id, meshHex)
    return true
  }

  /** `BLE_ACK:<messageId>`, back over the same session the message came in on. */
  private suspend fun acknowledge(messageId: String, meshPublicKeyHex: String) {
    if (!runningFlag || messageId.length > PopopxMeshControlFrame.MAX_ARGUMENT_LENGTH) return
    val record = peersByHex[meshPublicKeyHex] ?: return
    val session = record.session ?: return
    val frame = PopopxMeshControlFrame.DeliveryAck(messageId)
    val envelope = PopopxMeshEnvelope.control(UUID.randomUUID().toString().lowercase(), frame)
    val ciphertext = try {
      session.encrypt(PopopxMeshEnvelope.encode(envelope))
    } catch (e: Throwable) {
      return
    }
    // The acknowledgement's nonce is spent whether or not the radio takes it, which is why nothing here
    // rolls the session back.
    val packet = packet(PopopxMeshMessageType.NOISE_ENCRYPTED, outboundTTL(broadcast = false), record.peerID.bytes, ciphertext)
    deliver(packet, packet.packetID.meshHex(), record, null)
  }

  private suspend fun consumeFragment(packet: PopopxMeshPacket, hopCount: Int, linkID: String): Boolean {
    if (!packet.isBroadcast && packet.recipientPeerID != identityValue.peerID) return true
    val appended = fragments.append(packet, nowMillis())
    if (appended == null || appended is PopopxMeshAssemblerOutcome.Stored) {
      // `null` is not a fragment at all, which the type dispatch above already decided, and `Stored`
      // means the stream gained this piece. Neither is a hole a retransmission could fill: the pieces
      // still missing are separate packets with separate ids.
      return true
    }
    if (appended is PopopxMeshAssemblerOutcome.Rejected) {
      return when (appended.reason) {
        is PopopxMeshFragmentRejection.TooManyInFlight,
        is PopopxMeshFragmentRejection.Expired,
        -> {
          // Both are about when the piece arrived rather than what it holds: the table may have room by
          // the next copy, and a piece that opened a stream past its lifetime starts a clean one.
          // Refusing to look at them again is how a long message disappears.
          false
        }
        else -> true
      }
    }
    val outcome = appended as PopopxMeshAssemblerOutcome.Complete
    if (outcome.originalType == PopopxMeshMessageType.FRAGMENT.wireValue ||
      outcome.originalType == PopopxMeshMessageType.NOISE_HANDSHAKE.wireValue
    ) {
      // A stream that reassembles into another fragment, or into a handshake we would feed to the cipher,
      // is a wrapper loop. A node cannot name our handshake messages for us.
      return true
    }
    // The fragmenter repeats the sender, recipient, timestamp, TTL and signature on every piece, so the
    // finished payload needs no second frame to become a packet.
    val inner = PopopxMeshPacket(
      version = packet.version,
      type = outcome.originalType,
      ttl = packet.ttl,
      timestamp = packet.timestamp,
      senderID = packet.senderID,
      recipientID = packet.recipientID,
      payload = outcome.data,
      signature = packet.signature,
    )
    if (inner.senderPeerID == identityValue.peerID) return true
    // The finished packet is a different id from every piece that carried it, and this one is remembered
    // the moment it exists: the stream is complete, so a second copy of any piece can only duplicate a
    // message this node has already run.
    if (!recentPackets.note(inner.packetID)) return true
    return consume(inner, hopCount, linkID)
  }

  private suspend fun consumeAnnounce(packet: PopopxMeshPacket, hopCount: Int, linkID: String) {
    val sender = packet.senderPeerID ?: return
    val fields = decodeAnnounce(packet.payload) ?: return
    val keyHex = fields[ANNOUNCE_PUBLIC_KEY_FIELD] ?: return
    if (keyHex.length != PopopxMeshIdentity.KEY_BYTE_COUNT * 2) return
    val peerPublicKey = keyHex.meshHexToBytes() ?: return
    if (PopopxMeshPeerID.fromPublicKey(peerPublicKey) != sender) return
    val meshHex = peerPublicKey.meshHex()
    val record = peersByHex[meshHex] ?: PeerRecord(
      meshPublicKeyHex = meshHex,
      peerID = sender,
      nickname = null,
      hopCount = hopCount,
      lastSeenAtMillis = nowMillis(),
      isDirect = false,
    ).also { peersByHex[meshHex] = it }
    record.nickname = fields[ANNOUNCE_NICKNAME_FIELD] ?: record.nickname
    touch(hopCount, linkID, record)
    meshHexByPeerID[sender.hex] = meshHex
    publish(PopopxMeshEvent.PeerAppeared(record.peer))
  }

  /**
   * iOS decodes the announce payload as `[String: String]`, so a member whose value is a number, a bool,
   * null or an object fails the whole payload rather than that field. [JsonFlatReader] is the same
   * strictness applied to a document with no fixed shape.
   */
  private fun decodeAnnounce(data: ByteArray): Map<String, String>? {
    val members = JsonFlatReader(data.toString(Charsets.UTF_8)).readObject() ?: return null
    val out = HashMap<String, String>(members.size)
    for ((key, value) in members) {
      val text = (value as? JsonValue.Str)?.text ?: return null
      if (!out.containsKey(key)) out[key] = text
    }
    return out
  }

  private fun announcePayload(): ByteArray {
    val fields = LinkedHashMap<String, String>()
    val chosen = nickname
    if (chosen != null && chosen.isNotEmpty()) fields[ANNOUNCE_NICKNAME_FIELD] = chosen
    fields[ANNOUNCE_PUBLIC_KEY_FIELD] = identityValue.meshPublicKeyHex
    // Key order is sorted, deliberately not a copy of iOS': the announce goes through a plain JSONEncoder
    // there, so its order comes from a per-process seed and varies between runs (measured as
    // `announce.distinctOrderings` in the vector file). A reader cannot depend on it, and every reader here
    // keys by name.
    val ordered = LinkedHashMap<String, String>()
    for (key in fields.keys.toList().sorted()) ordered[key] = fields[key]!!
    // No `signpub`: the Ed25519 signing key belongs to the group layer, which is held this phase. A node
    // that has no module 8 simply does not learn our signing key, exactly as for an older iOS build.
    val out = StringBuilder("{")
    for ((index, entry) in ordered.entries.withIndex()) {
      if (index > 0) out.append(',')
      out.append(PopopxMeshEnvelope.jsonString(entry.key)).append(':').append(PopopxMeshEnvelope.jsonString(entry.value))
    }
    out.append('}')
    return out.toString().toByteArray(Charsets.UTF_8)
  }

  private suspend fun consumeBroadcastMessage(packet: PopopxMeshPacket, hopCount: Int) {
    val sender = packet.senderPeerID ?: return
    if (!packet.isBroadcast) return
    publish(
      PopopxMeshEvent.Inbound(
        PopopxMeshInbound(
          messageId = packet.packetID.meshHex(),
          sender = sender,
          senderMeshPublicKey = meshHexByPeerID[sender.hex]?.meshHexToBytes(),
          recipient = null,
          hopCount = hopCount,
          isBroadcast = true,
          receivedAtMillis = nowMillis(),
          body = PopopxMeshBody.Text(String(packet.payload, Charsets.UTF_8)),
        )
      )
    )
  }

  private suspend fun consumePing(packet: PopopxMeshPacket) {
    val sender = packet.senderPeerID ?: return
    if (packet.recipientPeerID != identityValue.peerID) return
    val reply = packet(PopopxMeshMessageType.PONG, outboundTTL(broadcast = false), sender.bytes, packet.payload)
    deliverKnownPeer(reply, reply.packetID.meshHex(), sender.hex, null)
  }

  private suspend fun consumeLeave(packet: PopopxMeshPacket) {
    val sender = packet.senderPeerID ?: return
    val meshHex = meshHexByPeerID[sender.hex] ?: return
    forget(meshHex)
    publish(PopopxMeshEvent.PeerDisappeared(sender))
  }

  // MARK: - Relay

  /**
   * The flood: TTL hops, never back out of the ingress link, never twice the same packet, and jittered so
   * that two neighbours that heard the frame at once do not collide on the link.
   */
  private suspend fun relay(packet: PopopxMeshPacket, incoming: String): Boolean {
    if (packet.ttl <= 1) {
      // A frame that dies at our door is not a delivery failure of ours: the health layer owns that verdict
      // for traffic we sent, and this traffic belongs to someone else.
      return false
    }
    val forwarded = PopopxMeshPacket(
      version = packet.version,
      type = packet.type,
      ttl = packet.ttl - 1,
      timestamp = packet.timestamp,
      senderID = packet.senderID,
      recipientID = packet.recipientID,
      payload = packet.payload,
      signature = packet.signature,
    )
    val delaySeconds = relayDelay()
    if (delaySeconds > 0.0) delay((delaySeconds * 1000).toLong())
    if (!runningFlag) return false
    val peer = packet.recipientPeerID?.let { meshHexByPeerID[it.hex] }?.let { peersByHex[it] }
    return deliver(forwarded, packet.packetID.meshHex(), peer, incoming)
  }

  // MARK: - Peers

  /**
   * Records that this peer was heard at this many hops, on this link. The `linkID` a frame arrived on proves
   * the peer is one hop away *if the link is ours*; a relayed frame carries no link at all, so a null link
   * keeps the peer indirect.
   */
  private fun touch(hopCount: Int, linkID: String?, record: PeerRecord) {
    record.hopCount = hopCount
    record.lastSeenAtMillis = nowMillis()
    if (linkID != null) {
      record.linkIDs.add(linkID)
      meshHexByLink[linkID] = record.meshPublicKeyHex
      record.isDirect = true
    }
  }

  private fun touch(meshPublicKeyHex: String, hopCount: Int, linkID: String?) {
    val record = peersByHex[meshPublicKeyHex] ?: return
    touch(hopCount, linkID, record)
  }

  private fun forget(meshPublicKeyHex: String) {
    val record = peersByHex.remove(meshPublicKeyHex) ?: return
    meshHexByPeerID.remove(record.peerID.hex)
    for ((linkID, bound) in meshHexByLink.filterValues { it == meshPublicKeyHex }) meshHexByLink.remove(linkID)
    settleHandshakeWaiters(meshPublicKeyHex)
  }

  // MARK: - Maintenance

  /** Public so a test can drive one tick of ageing and announcing without waiting five seconds. */
  suspend fun maintain() {
    withContext(dispatcher) { maintainOnThread() }
  }

  private suspend fun maintainOnThread() {
    val now = nowMillis()
    for ((meshHex, record) in peersByHex.entries.toList()) {
      val started = record.handshakeStartedAtMillis
      if (record.session == null && started != null && now - started > millisOf(config.connectTimeout)) {
        record.handshake = null
        record.handshakeStartedAtMillis = null
        settleHandshakeWaiters(meshHex)
      }
      // A peer we could not reach for four of the reachability windows, on no link of ours, is dropped; its
      // record is not the evidence a delivery failure is drawn from.
      if (record.linkIDs.isEmpty() && record.session == null &&
        now - record.lastSeenAtMillis > millisOf(config.peerReachabilityTimeout * 4)
      ) {
        forget(meshHex)
      }
    }
    for ((senderHex, entry) in responders.entries.toList()) {
      if (now - entry.second > millisOf(config.connectTimeout)) responders.remove(senderHex)
    }
    recentPackets.prune(now)
    fragments.prune(now)
    if (!runningFlag || !radioState.isUsable) return
    announceIfNeeded(now)
  }

  private suspend fun announceIfNeeded(now: Long) {
    val last = lastAnnounceAtMillis
    if (last != null && now - last < millisOf(config.announceInterval)) return
    lastAnnounceAtMillis = now
    val packet = packet(PopopxMeshMessageType.ANNOUNCE, outboundTTL(broadcast = true), null, announcePayload())
    deliver(packet, packet.packetID.meshHex(), null, null)
  }

  // MARK: - Transport delegate

  /**
   * Every callback hops onto [dispatcher] rather than running on the radio thread: iOS' delegate methods are
   * `nonisolated` and each starts a `Task` on the actor, which is the same confinement from the other side.
   */
  override fun didReceive(data: ByteArray, fromLinkID: String) {
    scope.launch { receiveOnThread(data, fromLinkID) }
  }

  override fun didUpdateState(state: PopopxBluetoothState) {
    scope.launch { radioChanged(state) }
  }

  override fun didOpen(link: PopopxBLELink) {
    // Nothing is bound yet: a link becomes a peer's link when a packet names it.
  }

  override fun didBecomeWritable(link: PopopxBLELink) {
    scope.launch {
      val meshHex = meshHexByLink[link.linkID] ?: return@launch
      touch(meshHex, 0, link.linkID)
      val peer = peersByHex[meshHex] ?: return@launch
      publish(PopopxMeshEvent.PeerAppeared(peer.peer))
    }
  }

  override fun didClose(linkID: String, error: Exception?) {
    scope.launch {
      val meshHex = meshHexByLink.remove(linkID) ?: return@launch
      val peer = peersByHex[meshHex] ?: return@launch
      peer.linkIDs.remove(linkID)
      if (peer.linkIDs.isEmpty()) {
        peer.isDirect = false
        // module 4 turns this into a delivery failure for everything still in flight; that layer is held,
        // so the event is the whole report.
        publish(PopopxMeshEvent.PeerDisappeared(peer.peerID))
      }
    }
  }

  override fun didFailToSend(data: ByteArray, toLinkID: String, error: Exception?) {
    scope.launch {
      val packet = PopopxMeshPacket.decode(data) ?: return@launch
      // No recipient means a broadcast, and a broadcast the stack refused is just as much a lost frame.
      // The guard that returned here is why the plaza showed a message as sent that never left.
      val peer = packet.recipientPeerID
      val reason: PopopxMeshSendFailure = when {
        !radioState.isUsable -> PopopxMeshSendFailure.RadioUnavailable(radioState)
        error is PopopxBLETransportError -> PopopxMeshSendFailure.LinkDropped
        else -> PopopxMeshSendFailure.NoLinkToPeer
      }
      publish(PopopxMeshEvent.SendFailed(packet.packetID.meshHex(), peer, reason))
      if (reason is PopopxMeshSendFailure.LinkDropped && peer != null) {
        meshHexByPeerID[peer.hex]?.let { peersByHex[it]?.session = null }
      }
      retransmit(packet, peer)
    }
  }

  /**
   * One more attempt at a frame the radio refused outright. This is not an acknowledgement watchdog —
   * module 4 is not mounted in this port, and a frame that was handed over may have landed, so nothing
   * here is re-sent on a silence. A refusal is different evidence: the bytes never left this node, which
   * is the only condition under which trying again cannot show the peer the message twice.
   *
   * The backoff is one connection interval rather than a round trip: what refuses a write is a full
   * GATT queue, and that drains as soon as the stack takes the pending one.
   */
  private suspend fun retransmit(packet: PopopxMeshPacket, peerID: PopopxMeshPeerID?) {
    if (!runningFlag || config.meshDeliveryRetries <= 0) return
    val key = packet.packetID.meshHex()
    val spent = retransmits[key] ?: 0
    if (spent >= config.meshDeliveryRetries) return
    retransmits[key] = spent + 1
    delay(RETRANSMIT_BACKOFF_MILLIS)
    if (!runningFlag) return
    val peer = peerID?.let { meshHexByPeerID[it.hex] }?.let { peersByHex[it] }
    deliver(packet, key, peer, null)
  }

  private suspend fun radioChanged(state: PopopxBluetoothState) {
    radioState = state
    publish(PopopxMeshEvent.BluetoothState(state))
    if (state.isUsable) return
    // A radio that died takes its sessions with it: the next start re-handshakes rather than writing into a
    // session the stack has already forgotten.
    peersByHex.clear()
    meshHexByPeerID.clear()
    meshHexByLink.clear()
    responders.clear()
    settleAllHandshakeWaiters()
  }

  // MARK: - Publishing

  private fun publish(event: PopopxMeshEvent) = hub.publish(event)

  companion object {
    /**
     * The engine the app mounted, or null while no mesh is running. iOS has `PopopxMeshEngine.shared`,
     * created on first touch; that shape is unsafe here because the panic-wipe path would then mint a
     * static key while it is trying to destroy one. Mounting is explicit: [start] claims it, [stop]
     * releases it, and a wipe reads whatever is actually running.
     */
    @Volatile
    var current: PopopxMeshEngine? = null
      private set

    /** Announce payload keys, verbatim from `Engine:85-92`. */
    const val ANNOUNCE_PUBLIC_KEY_FIELD: String = "pubkey"
    const val ANNOUNCE_NICKNAME_FIELD: String = "nickname"
    const val ANNOUNCE_SIGNING_KEY_FIELD: String = "signpub"

    /** How far back a peer's nonce may move before a frame is called a replay. */
    private val NOISE_REPLAY_WINDOW = PopopxNoiseSession.DEFAULT_REPLAY_WINDOW

    /** One connection interval, not one round trip: see [retransmit]. */
    private const val RETRANSMIT_BACKOFF_MILLIS = 250L

    private const val PROTOCOL_VERSION = 1
    private const val U_SHORT_MAX = 65_535

    private val SECURE_RANDOM = java.security.SecureRandom()

    private fun millisOf(seconds: Double): Long = (seconds * 1000).toLong()
  }
}
