package chat.popopx.common.views.cabin

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.mesh.PopopxBluetoothState
import chat.popopx.common.mesh.PopopxMeshBody
import chat.popopx.common.mesh.PopopxMeshConfig
import chat.popopx.common.mesh.PopopxMeshEngine
import chat.popopx.common.mesh.PopopxMeshEnvelope
import chat.popopx.common.mesh.PopopxMeshEvent
import chat.popopx.common.mesh.PopopxMeshEventHub
import chat.popopx.common.mesh.PopopxMeshFusePhase
import chat.popopx.common.mesh.PopopxMeshInbound
import chat.popopx.common.mesh.PopopxMeshKillSwitch
import chat.popopx.common.mesh.PopopxMeshPeer
import chat.popopx.common.mesh.PopopxMeshSendError
import chat.popopx.common.mesh.PopopxMeshSendFailure
import chat.popopx.common.mesh.meshHex
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.ui.theme.DEFAULT_PADDING
import chat.popopx.common.ui.theme.DEFAULT_PADDING_HALF
import chat.popopx.common.views.helpers.AppBarTitle
import chat.popopx.common.views.helpers.DefaultBasicTextField
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.util.UUID

// The Cabin tab: the offline Bluetooth mesh's screen, ported from
// `apps/ios/PopopxMeshKit/Sources/PopopxMeshUI/MeshPlazaView.swift` and the node list of
// `Shared/Features/Cabin/PopopxCabinView.swift`. It is reached only through `PopopxTab.CABIN`, which the
// tab bar shows on Android alone, so the desktop tree and its 376 snapshot baselines never compose this file.
//
// Three things are deliberately absent, and the screen says so rather than faking them:
// - mesh groups. The group key tree is HOLD this phase, so the offline channel is iOS' *broadcast plaza*
//   (`MeshPlazaView`), not a group chat.
// - a nickname. iOS persists one in the mesh sandbox and restarts the mesh to advertise a new value
//   (`PopopxMeshKillSwitch.setNickname`); that store is not ported, so the engine starts unnamed and the
//   list shows wire ids.
// - pairing, proximity, health and the SMP router. A peer with no mesh session is reported as having none;
//   nothing here falls back to the internet, which is the whole point of the screen.

/** One line of a Cabin timeline. */
class PopopxCabinPost(
  val id: String,
  val text: String,
  val atMillis: Long,
  val author: String,
  val mine: Boolean,
  val hopCount: Int,
  val failed: Boolean = false,
) {
  fun asFailed(): PopopxCabinPost = PopopxCabinPost(id, text, atMillis, author, mine, hopCount, true)

  companion object {
    /** Control and binary bodies are not text and stay out of a text timeline, as they do on iOS. */
    fun of(inbound: PopopxMeshInbound): PopopxCabinPost? {
      val text = (inbound.body as? PopopxMeshBody.Text)?.text ?: return null
      return PopopxCabinPost(
        id = inbound.messageId,
        text = text,
        atMillis = inbound.receivedAtMillis,
        author = inbound.sender.hex,
        mine = false,
        hopCount = inbound.hopCount,
      )
    }
  }
}

/**
 * `PopopxMeshReachEstimate` — how far a broadcast sent from here can travel. The metre figure is iOS'
 * 30 m/hop rule of thumb, and it is presented as one: the radius is what the TTL allows, not a measurement.
 */
object PopopxCabinReach {
  /** `PopopxMeshReachEstimate.metresPerHop`. */
  const val METRES_PER_HOP: Int = 30

  fun metres(hops: Int): Int = maxOf(0, hops) * METRES_PER_HOP

  fun radius(hops: Int): String {
    val metres = metres(hops)
    return if (metres >= 1_000) "%.1f km".format(metres / 1_000.0) else "$metres m"
  }
}

/**
 * The Cabin's mirror of the mesh — the reduced form of `PopopxMeshStateSource`, keeping its reduction
 * rules: peers ordered by wire id, one append-and-trim per stream, and a broadcast told from a direct
 * message by the packet's own flag rather than by anything the view guesses.
 *
 * Shared rather than remembered by the composable, because iOS' mirror outlives the screen that reads it:
 * leaving the tab and coming back does not empty the timeline. [stop] does clear it, which is what makes
 * "the fuse is off and nothing is retained" a checkable claim instead of a hope.
 */
class PopopxCabinStore(
  private val hub: PopopxMeshEventHub = PopopxMeshEventHub.shared,
  private val capacity: Int = DEFAULT_CAPACITY,
) {
  val radioState = MutableStateFlow(PopopxBluetoothState.UNKNOWN)
  val peers = MutableStateFlow<List<PopopxMeshPeer>>(emptyList())
  val broadcasts = MutableStateFlow<List<PopopxCabinPost>>(emptyList())
  val privateThreads = MutableStateFlow<Map<String, List<PopopxCabinPost>>>(emptyMap())

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
  private var pump: Job? = null
  private var stream: Channel<PopopxMeshEvent>? = null

  val isPumping: Boolean get() = pump?.isActive == true

  /** Idempotent, so several entries into the tab — or the fuse and the tab both — cannot double-subscribe. */
  fun start() {
    if (isPumping) return
    val channel = hub.subscribe()
    stream = channel
    pump = scope.launch {
      for (event in channel) ingest(event)
    }
  }

  /** Stops the pump, releases the hub slot and forgets the timeline. */
  fun stop() {
    pump?.cancel()
    pump = null
    stream?.close()
    stream = null
    radioState.value = PopopxBluetoothState.UNKNOWN
    peers.value = emptyList()
    broadcasts.value = emptyList()
    privateThreads.value = emptyMap()
  }

  /**
   * One event in, one state out. Public because it is the whole behaviour of this type and a test drives it
   * directly, without a radio and without a hub — the same reason iOS exposes `ingest(_:)`.
   */
  fun ingest(event: PopopxMeshEvent) {
    when (event) {
      is PopopxMeshEvent.BluetoothState -> radioState.value = event.state

      is PopopxMeshEvent.PeerAppeared -> {
        val rest = peers.value.filter { it.peerID != event.peer.peerID }
        peers.value = (rest + event.peer).sortedBy { it.peerID.hex }
      }

      is PopopxMeshEvent.PeerDisappeared ->
        peers.value = peers.value.filter { it.peerID != event.peerID }

      is PopopxMeshEvent.Inbound -> {
        val post = PopopxCabinPost.of(event.inbound) ?: return
        if (event.inbound.isBroadcast) {
          broadcasts.value = append(post, broadcasts.value)
        } else {
          val key = event.inbound.sender.hex
          privateThreads.value = privateThreads.value + (key to append(post, privateThreads.value[key].orEmpty()))
        }
      }

      is PopopxMeshEvent.SendFailed -> markFailed(event.messageId)
    }
  }

  /** The composer's own post. A broadcast the radio refused still appears, marked as refused. */
  fun noteLocal(text: String, messageId: String, failed: Boolean) {
    val post = PopopxCabinPost(
      id = messageId,
      text = text,
      atMillis = System.currentTimeMillis(),
      author = LOCAL_AUTHOR,
      mine = true,
      hopCount = 0,
      failed = failed,
    )
    broadcasts.value = append(post, broadcasts.value)
  }

  /** The private thread's own post, filed under the peer it was sent to. */
  fun noteLocalPrivate(text: String, meshPublicKeyHex: String, messageId: String, failed: Boolean) {
    val post = PopopxCabinPost(
      id = messageId,
      text = text,
      atMillis = System.currentTimeMillis(),
      author = LOCAL_AUTHOR,
      mine = true,
      hopCount = 0,
      failed = failed,
    )
    val current = privateThreads.value[meshPublicKeyHex].orEmpty()
    privateThreads.value = privateThreads.value + (meshPublicKeyHex to append(post, current))
  }

  /** Re-seeds from a live engine, because a screen that mounts after the first announce must not wait for the next one. */
  suspend fun seed(engine: PopopxMeshEngine) {
    radioState.value = engine.bluetoothState
    peers.value = engine.peers()
  }

  private fun markFailed(messageId: String) {
    broadcasts.value = broadcasts.value.map { if (it.id == messageId && !it.failed) it.asFailed() else it }
    privateThreads.value = privateThreads.value.mapValues { (_, posts) ->
      posts.map { if (it.id == messageId && !it.failed) it.asFailed() else it }
    }
  }

  /** `PopopxMeshStateSource.append(_:to:capacity:)` — trim from the front, never refuse the newest. */
  private fun append(post: PopopxCabinPost, to: List<PopopxCabinPost>): List<PopopxCabinPost> {
    val next = to + post
    return if (next.size > capacity) next.subList(next.size - capacity, next.size).toList() else next
  }

  companion object {
    /** `PopopxMeshStateSource.defaultCapacity`. */
    const val DEFAULT_CAPACITY: Int = 256

    /** iOS shows a local post under the user's own nickname; there is none until that store is ported. */
    const val LOCAL_AUTHOR: String = "local"

    val shared: PopopxCabinStore = PopopxCabinStore()
  }
}

@Composable
fun PopopxCabinView() {
  val store = PopopxCabinStore.shared
  val fuse = PopopxMeshKillSwitch.shared
  val uiScope = rememberCoroutineScope()

  val enabled by fuse.isEnabled.collectAsState()
  val phase by fuse.phase.collectAsState()
  val radio by store.radioState.collectAsState()
  val peers by store.peers.collectAsState()
  val posts by store.broadcasts.collectAsState()
  val threads by store.privateThreads.collectAsState()

  val draft = rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue("")) }
  val chatDraft = rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue("")) }
  val selected = rememberSaveable { mutableStateOf<String?>(null) }
  val failure = remember { mutableStateOf<PopopxMeshSendFailure?>(null) }

  // The mirror and the fuse, not the view, own the mesh: entering the tab starts the pump and restores the
  // persisted switch, and leaving the tab stops neither. Only the switch (or a panic wipe) tears the radio down.
  LaunchedEffect(Unit) {
    store.start()
    fuse.restore()
    fuse.engine()?.let { store.seed(it) }
  }

  AppBarTitle(stringResource(MR.strings.cabin_title))
  ColumnWithScrollBar(Modifier.fillMaxSize()) {
    Column(Modifier.padding(horizontal = DEFAULT_PADDING)) {
      PopopxCabinStatus(radio = radio, phase = phase, peers = peers, enabled = enabled)

      PopopxCabinSwitchRow(
        enabled = enabled,
        busy = phase == PopopxMeshFusePhase.STARTING || phase == PopopxMeshFusePhase.STOPPING,
      ) { next ->
        uiScope.launch { fuse.setEnabled(next) }
      }

      Spacer(Modifier.height(DEFAULT_PADDING))
      Text(stringResource(MR.strings.cabin_nodes_heading), fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
      Spacer(Modifier.height(DEFAULT_PADDING_HALF))
      if (peers.isEmpty()) {
        Text(stringResource(MR.strings.cabin_nodes_empty), color = MaterialTheme.colors.secondary, fontSize = 13.sp)
      } else {
        peers.forEach { peer ->
          PopopxCabinPeerRow(peer, selected.value == peer.meshPublicKey?.meshHex()) {
            selected.value = peer.meshPublicKey?.meshHex()
            failure.value = null
          }
        }
      }

      Spacer(Modifier.height(DEFAULT_PADDING))
      Text(stringResource(MR.strings.cabin_broadcast_heading), fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
      Spacer(Modifier.height(DEFAULT_PADDING_HALF))
      if (posts.isEmpty()) {
        Text(stringResource(MR.strings.cabin_broadcast_empty), color = MaterialTheme.colors.secondary, fontSize = 13.sp)
      } else {
        posts.forEach { post -> PopopxCabinPostRow(post) }
      }
      Spacer(Modifier.height(DEFAULT_PADDING_HALF))
      PopopxCabinComposer(
        value = draft,
        placeholder = stringResource(MR.strings.cabin_broadcast_placeholder),
        action = stringResource(MR.strings.cabin_broadcast_send),
        // `MeshPlazaViewModel.canBroadcast`: the radio has to be able to carry it, and a draft has to exist.
        enabled = radio.isUsable && draft.value.text.isNotBlank(),
      ) {
        val text = draft.value.text.trim().take(MAX_DRAFT_CHARACTERS)
        draft.value = TextFieldValue("")
        uiScope.launch {
          val engine = fuse.engine()
          // iOS appends the draft to the plaza whether or not the radio took it, and marks the row.
          val result = runCatching { requireNotNull(engine).sendBroadcast(text) }
          val messageId = result.getOrNull() ?: UUID.randomUUID().toString().lowercase()
          store.noteLocal(text, messageId, failed = result.isFailure)
          failure.value = (result.exceptionOrNull() as? PopopxMeshSendError)?.failure
        }
      }

      val peer = selected.value
      Spacer(Modifier.height(DEFAULT_PADDING))
      Text(stringResource(MR.strings.cabin_chat_heading), fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
      Spacer(Modifier.height(DEFAULT_PADDING_HALF))
      if (peer == null) {
        Text(stringResource(MR.strings.cabin_chat_none), color = MaterialTheme.colors.secondary, fontSize = 13.sp)
      } else {
        val thread = threads[peer].orEmpty()
        if (thread.isEmpty()) {
          Text(stringResource(MR.strings.cabin_chat_empty), color = MaterialTheme.colors.secondary, fontSize = 13.sp)
        } else {
          thread.forEach { post -> PopopxCabinPostRow(post) }
        }
        PopopxCabinComposer(
          value = chatDraft,
          placeholder = stringResource(MR.strings.cabin_chat_placeholder),
          action = stringResource(MR.strings.cabin_chat_send),
          enabled = radio.isUsable && chatDraft.value.text.isNotBlank(),
        ) {
          val text = chatDraft.value.text.trim().take(MAX_DRAFT_CHARACTERS)
          chatDraft.value = TextFieldValue("")
          uiScope.launch {
            val engine = fuse.engine()
            val envelope = PopopxMeshEnvelope.text(UUID.randomUUID().toString().lowercase(), text)
            val result = runCatching { requireNotNull(engine).send(envelope, peer) }
            store.noteLocalPrivate(text, peer, envelope.id, failed = result.isFailure)
            failure.value = (result.exceptionOrNull() as? PopopxMeshSendError)?.failure
          }
        }
      }

      failure.value?.let {
        Spacer(Modifier.height(DEFAULT_PADDING_HALF))
        Text(
          cabinFailureWords(it),
          color = MaterialTheme.colors.error,
          fontSize = 12.sp,
          maxLines = 2,
        )
      }
      Spacer(Modifier.height(DEFAULT_PADDING * 2))
    }
  }
}

/**
 * The three facts iOS keeps apart — the radio, the fuse, and what the radio has actually reached — as three
 * lines. A single "connected/disconnected" label would collapse them, and they disagree in real life: the
 * radio can be on with the fuse off, and the fuse on with nothing in range.
 */
@Composable
private fun PopopxCabinStatus(
  radio: PopopxBluetoothState,
  phase: PopopxMeshFusePhase,
  peers: List<PopopxMeshPeer>,
  enabled: Boolean,
) {
  Column(
    Modifier
      .fillMaxWidth()
      .background(MaterialTheme.colors.background, RoundedCornerShape(12.dp))
      .padding(12.dp),
    verticalArrangement = Arrangement.spacedBy(4.dp)
  ) {
    Text(
      if (radio.isUsable) {
        val hops = maxOf(1, PopopxMeshConfig.default.ttlDefault)
        stringResource(MR.strings.cabin_neighbours, peers.size) +
          " · " + stringResource(MR.strings.cabin_reach, hops, PopopxCabinReach.radius(hops))
      } else {
        cabinRadioTitle(radio)
      },
      fontSize = 13.sp,
      color = MaterialTheme.colors.secondary,
    )
    Text(cabinFuseTitle(phase, enabled), fontSize = 13.sp, color = MaterialTheme.colors.secondary)
    Text(
      if (peers.isEmpty()) {
        stringResource(MR.strings.cabin_nodes_none)
      } else {
        val direct = peers.count { it.isDirect }
        stringResource(MR.strings.cabin_nodes_summary, direct, peers.size - direct)
      },
      fontSize = 13.sp,
      color = MaterialTheme.colors.secondary,
    )
  }
}

/** `PopopxMeshBannerModel.radioTitle`, case for case, so both platforms name a state the same way. */
@Composable
private fun cabinRadioTitle(state: PopopxBluetoothState): String = when (state) {
  PopopxBluetoothState.POWERED_OFF -> stringResource(MR.strings.cabin_radio_off)
  PopopxBluetoothState.UNAUTHORIZED -> stringResource(MR.strings.cabin_radio_unauthorized)
  PopopxBluetoothState.RESETTING -> stringResource(MR.strings.cabin_radio_resetting)
  PopopxBluetoothState.UNSUPPORTED -> stringResource(MR.strings.cabin_radio_unsupported)
  PopopxBluetoothState.POWERED_ON, PopopxBluetoothState.UNKNOWN -> stringResource(MR.strings.cabin_radio_unavailable)
}

@Composable
private fun cabinFuseTitle(phase: PopopxMeshFusePhase, enabled: Boolean): String = when {
  phase == PopopxMeshFusePhase.OFF && !enabled -> stringResource(MR.strings.cabin_fuse_off)
  phase == PopopxMeshFusePhase.OFF -> stringResource(MR.strings.cabin_fuse_stopped)
  phase == PopopxMeshFusePhase.STARTING -> stringResource(MR.strings.cabin_fuse_starting)
  phase == PopopxMeshFusePhase.STOPPING -> stringResource(MR.strings.cabin_fuse_stopping)
  else -> stringResource(MR.strings.cabin_fuse_on)
}

/** `MeshPlazaView.words(for:)`, branch for branch — including the radio case, which reuses the banner's wording. */
@Composable
private fun cabinFailureWords(failure: PopopxMeshSendFailure): String = when (failure) {
  is PopopxMeshSendFailure.NoLinkToPeer -> stringResource(MR.strings.cabin_fail_no_link)
  is PopopxMeshSendFailure.LinkDropped -> stringResource(MR.strings.cabin_fail_link_dropped)
  is PopopxMeshSendFailure.TtlExhausted -> stringResource(MR.strings.cabin_fail_ttl_exhausted)
  is PopopxMeshSendFailure.Oversized ->
    stringResource(MR.strings.cabin_fail_oversized, failure.payloadBytes, failure.limitBytes)
  is PopopxMeshSendFailure.NoSessionWithPeer -> stringResource(MR.strings.cabin_fail_no_session)
  is PopopxMeshSendFailure.RadioUnavailable -> cabinRadioTitle(failure.state)
}

@Composable
private fun PopopxCabinSwitchRow(enabled: Boolean, busy: Boolean, onToggle: (Boolean) -> Unit) {
  Column(Modifier.fillMaxWidth().padding(top = DEFAULT_PADDING_HALF)) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
      Text(
        stringResource(MR.strings.cabin_switch),
        fontSize = 14.sp,
        fontWeight = FontWeight.Medium,
        modifier = Modifier.weight(1f),
      )
      Text(
        if (busy) {
          stringResource(MR.strings.cabin_switch_busy)
        } else {
          stringResource(if (enabled) MR.strings.cabin_switch_on else MR.strings.cabin_switch_off)
        },
        fontSize = 13.sp,
        color = if (enabled) MaterialTheme.colors.primary else MaterialTheme.colors.secondary,
        modifier = Modifier
          .clip(RoundedCornerShape(14.dp))
          .background(if (enabled) MaterialTheme.colors.primary.copy(alpha = 0.12f) else MaterialTheme.colors.background)
          .clickable(enabled = !busy) { onToggle(!enabled) }
          .padding(horizontal = 12.dp, vertical = 6.dp),
      )
    }
    Text(
      stringResource(MR.strings.cabin_switch_note),
      fontSize = 12.sp,
      color = MaterialTheme.colors.secondary,
    )
  }
}

@Composable
private fun PopopxCabinPeerRow(peer: PopopxMeshPeer, isSelected: Boolean, onSelect: () -> Unit) {
  val key = peer.meshPublicKey?.meshHex()
  Row(
    Modifier
      .fillMaxWidth()
      .clip(RoundedCornerShape(10.dp))
      .background(if (isSelected) MaterialTheme.colors.primary.copy(alpha = 0.08f) else MaterialTheme.colors.background)
      .clickable(enabled = key != null, onClick = onSelect)
      .padding(vertical = 8.dp),
    verticalAlignment = Alignment.CenterVertically,
  ) {
    Column(Modifier.weight(1f)) {
      Text(key?.take(12) ?: peer.peerID.hex, fontSize = 14.sp)
      Text(
        // iOS distinguishes the two reachabilities, and the difference is the point of the screen: a direct
        // link is a device in the room, a relayed one is a friend of a friend.
        if (peer.isDirect) stringResource(MR.strings.cabin_link_direct) else stringResource(MR.strings.cabin_link_relayed),
        fontSize = 12.sp,
        color = MaterialTheme.colors.secondary,
      )
    }
    if (!peer.isDirect) {
      Text(
        stringResource(MR.strings.cabin_hops, peer.hopCount),
        fontSize = 12.sp,
        color = MaterialTheme.colors.secondary,
      )
    }
  }
}

@Composable
private fun PopopxCabinPostRow(post: PopopxCabinPost) {
  Column(
    Modifier
      .fillMaxWidth()
      .padding(vertical = 4.dp),
  ) {
    Row(Modifier.fillMaxWidth()) {
      Text(
        if (post.mine) stringResource(MR.strings.cabin_you) else post.author.take(12),
        fontSize = 12.sp,
        fontWeight = FontWeight.Medium,
        color = MaterialTheme.colors.secondary,
        modifier = Modifier.weight(1f),
      )
      if (post.failed) {
        Text(stringResource(MR.strings.cabin_failed), fontSize = 11.sp, color = MaterialTheme.colors.error)
      }
    }
    Text(post.text, fontSize = 14.sp)
  }
}

@Composable
private fun PopopxCabinComposer(
  value: MutableState<TextFieldValue>,
  placeholder: String,
  action: String,
  enabled: Boolean,
  onSubmit: () -> Unit,
) {
  Row(
    Modifier.fillMaxWidth(),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    DefaultBasicTextField(
      modifier = Modifier
        .weight(1f)
        .background(MaterialTheme.colors.background, shape = RoundedCornerShape(12.dp))
        .padding(horizontal = 12.dp, vertical = 10.dp),
      state = value,
      placeholder = { Text(placeholder, color = MaterialTheme.colors.secondary, fontSize = 14.sp) },
      keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = ImeAction.Send),
      onValueChange = { value.value = it },
    )
    Text(
      action,
      fontSize = 14.sp,
      fontWeight = FontWeight.Medium,
      color = if (enabled) MaterialTheme.colors.onPrimary else MaterialTheme.colors.secondary,
      modifier = Modifier
        .clip(RoundedCornerShape(14.dp))
        .background(if (enabled) MaterialTheme.colors.primary else MaterialTheme.colors.surface)
        .clickable(enabled = enabled, onClick = onSubmit)
        .padding(horizontal = 14.dp, vertical = 10.dp),
    )
  }
}

private const val MAX_DRAFT_CHARACTERS = 512
