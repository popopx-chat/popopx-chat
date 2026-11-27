package chat.popopx.common.views.cabin

import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import chat.popopx.common.mesh.PopopxBluetoothState
import chat.popopx.common.mesh.PopopxMeshBody
import chat.popopx.common.mesh.PopopxMeshConfig
import chat.popopx.common.mesh.PopopxMeshControlFrame
import chat.popopx.common.mesh.PopopxMeshEngine
import chat.popopx.common.mesh.PopopxMeshEvent
import chat.popopx.common.mesh.PopopxMeshEventHub
import chat.popopx.common.mesh.PopopxMeshFusePhase
import chat.popopx.common.mesh.PopopxMeshInbound
import chat.popopx.common.mesh.PopopxMeshKillSwitch
import chat.popopx.common.mesh.PopopxMeshPeer
import chat.popopx.common.mesh.PopopxMeshSendFailure
import chat.popopx.common.mesh.meshHex
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.ui.components.PopopxDivider
import chat.popopx.common.ui.components.PopopxIconBadge
import chat.popopx.common.ui.components.PopopxPickerRow
import chat.popopx.common.ui.components.PopopxPrimaryButton
import chat.popopx.common.ui.components.PopopxSecondaryButton
import chat.popopx.common.ui.components.PopopxSection
import chat.popopx.common.ui.components.PopopxSwitch
import chat.popopx.common.ui.theme.PopopxAlpha
import chat.popopx.common.ui.theme.PopopxDuration
import chat.popopx.common.ui.theme.PopopxMesh
import chat.popopx.common.ui.theme.PopopxMeshInk
import chat.popopx.common.ui.theme.PopopxOnMesh
import chat.popopx.common.ui.theme.PopopxRadiusControl
import chat.popopx.common.ui.theme.PopopxSize
import chat.popopx.common.ui.theme.PopopxSurface
import chat.popopx.common.ui.theme.PopopxTypeScale
import chat.popopx.common.ui.theme.popopxReducedMotion
import chat.popopx.common.views.helpers.AppBarTitle
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin

// The Cabin tab: the offline Bluetooth mesh's root page, ported screen for screen from
// `apps/ios/Shared/Features/Cabin/PopopxCabinView.swift` — header, master-switch/radio card, the channels
// card (C2) and the nearby-nodes card with its radar (C1). The hall screen lives in
// `PopopxCabinHallView.kt`, the channels and pending pairings in `PopopxCabinChannelsView.kt`, and the
// settings centre in `PopopxCabinSettingsView.kt`, on the same atoms. It is reached only through `PopopxTab.CABIN`, which the tab bar shows on Android alone, so the
// desktop tree and its 376 snapshot baselines never compose this file.
//
// Two things are still deliberately absent, and the screens say so rather than faking them:
// - pairing, proximity, health and the SMP router. A peer with no mesh session is reported as having
//   none; nothing here falls back to the internet, which is the whole point of the screen. The channels
//   card keeps iOS' third row and states "not in this build" because GROUP_STATE/GROUP_MESSAGE are relayed
//   but not read on this platform.
// - the nickname is ported now (`PopopxMeshNicknameStore` + `PopopxMeshKillSwitch.setNickname`), so the
//   engine advertises whatever the hall's nickname card last saved.
//
// Reduce Motion: iOS stops the radar pulse when the system asks. The radar reads the same gate here
// (`popopxReducedMotion`) and, when it is set, draws its travelling ring at a fixed radius instead of
// looping a transition.

/** One line of a Cabin timeline. */
class PopopxCabinPost(
  val id: String,
  val text: String,
  val atMillis: Long,
  val author: String,
  val mine: Boolean,
  val hopCount: Int,
  val failed: Boolean = false,
  /**
   * The sender's mesh public key, when the mesh has one. This, not [author], is what a private send is
   * addressed with, so it is the value a tap on the author needs: [author] is the 8-byte wire id and
   * `send()` cannot take it.
   */
  val meshPublicKeyHex: String? = null,
) {
  fun asFailed(): PopopxCabinPost =
    PopopxCabinPost(id, text, atMillis, author, mine, hopCount, true, meshPublicKeyHex)

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
        meshPublicKeyHex = inbound.senderMeshPublicKey?.meshHex(),
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
}

/**
 * One pairing invitation this device received, as the sealed control frame carried it. Kept from the
 * moment it decrypts until the fuse goes off: it is a real frame that arrived, not a claim about a
 * pairing layer, and [inviteLink] is the peer's own argument.
 */
class PopopxCabinPairingRequest(
  val meshPublicKeyHex: String,
  val inviteLink: String,
  val receivedAtMillis: Long,
)

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
  /** Mesh public keys this device has actually held a Noise session with this run. */
  val channels = MutableStateFlow<Set<String>>(emptySet())
  val pendingPairings = MutableStateFlow<List<PopopxCabinPairingRequest>>(emptyList())

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
    channels.value = emptySet()
    pendingPairings.value = emptyList()
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
        val inbound = event.inbound
        val senderKey = inbound.senderMeshPublicKey?.meshHex()
        // A sealed 1:1 that decrypts proves the session behind the "encrypted channel" count; the
        // pairing frame rides the same kind of session, so it proves one too. A broadcast proves nothing
        // about sessions and never counts here.
        if (!inbound.isBroadcast && senderKey != null) {
          channels.value = channels.value + senderKey
          (inbound.controlFrame as? PopopxMeshControlFrame.PairingRequest)?.let { request ->
            notePendingPairing(senderKey, request.inviteLink, inbound.receivedAtMillis)
          }
        }
        val post = PopopxCabinPost.of(inbound) ?: return
        if (event.inbound.isBroadcast) {
          broadcasts.value = append(post, broadcasts.value)
        } else {
          // One thread per peer, keyed the way the peer is addressed everywhere else on this screen: the
          // mesh public key, which is what `selected` holds and what `send()` takes. Keying an inbound by
          // the 8-byte wire id instead put the received half of a conversation in a different map entry
          // from the sent half, so the 1:1 panel showed only one direction — and showed nothing at all for
          // a peer announced by key. The wire id remains the fallback for a sender whose key is unknown,
          // which is the only state where there is no key to have used.
          val key = event.inbound.senderMeshPublicKey?.meshHex() ?: event.inbound.sender.hex
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

  /** Records that a sealed exchange with this key actually happened — the private chat calls it after a send. */
  fun noteChannel(meshPublicKeyHex: String) {
    channels.value = channels.value + meshPublicKeyHex
  }

  /**
   * Forgets every session claim. The fuse's own teardown kills the sessions, and the screens call this the
   * moment the master switch closes, so a closed fuse never leaves a "channel established" behind it.
   */
  fun clearChannels() {
    channels.value = emptySet()
  }

  /** One invitation per peer, latest wins: a repeat from the same key replaces its earlier link. */
  private fun notePendingPairing(meshPublicKeyHex: String, inviteLink: String, atMillis: Long) {
    val request = PopopxCabinPairingRequest(meshPublicKeyHex, inviteLink, atMillis)
    val rest = pendingPairings.value.filter { it.meshPublicKeyHex != meshPublicKeyHex }
    pendingPairings.value = (rest + request).sortedByDescending { it.receivedAtMillis }
  }

  /** Re-seeds from a live engine, because a screen that mounts after the first announce must not wait for the next one. */
  suspend fun seed(engine: PopopxMeshEngine) {
    radioState.value = engine.bluetoothState
    peers.value = engine.peers()
    channels.value = engine.channelMeshPublicKeyHexes()
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
  val channels by store.channels.collectAsState()

  // iOS refreshes the relative readings every 2 seconds (`refreshInterval`); without a tick a row's
  // "last heard" freezes at whatever it was when the last peer event arrived, and the reachability
  // dot would keep claiming "online" long after the 15-second window closed.
  var nowMillis by remember { mutableStateOf(System.currentTimeMillis()) }
  LaunchedEffect(Unit) {
    while (true) {
      delay(2_000)
      nowMillis = System.currentTimeMillis()
    }
  }

  // The mirror and the fuse, not the view, own the mesh: entering the tab starts the pump and restores the
  // persisted switch, and leaving the tab stops neither. Only the switch (or a panic wipe) tears the radio down.
  LaunchedEffect(Unit) {
    store.start()
    fuse.restore()
    fuse.engine()?.let { store.seed(it) }
  }
  // The fuse's teardown kills every Noise session; a closed switch must not leave "N established" behind it.
  LaunchedEffect(enabled) {
    if (!enabled) store.clearChannels()
  }

  AppBarTitle(stringResource(MR.strings.cabin_title))
  ColumnWithScrollBar(Modifier.fillMaxSize()) {
    Column(
      Modifier
        .padding(horizontal = CABIN_GUTTER)
        .padding(top = 8.dp, bottom = CABIN_GUTTER * 3),
      verticalArrangement = Arrangement.spacedBy(CABIN_SECTION_GAP),
    ) {
      CabinHeader(enabled)

      PopopxCabinStatusCard(
        radio = radio,
        phase = phase,
        enabled = enabled,
        latestBroadcastAt = posts.lastOrNull { !it.mine }?.atMillis,
        nowMillis = nowMillis,
      ) { next -> uiScope.launch { fuse.setEnabled(next) } }

      PopopxCabinChannelsCard(
        enabled = enabled,
        broadcastCount = posts.size,
        channelCount = if (enabled) peers.count { peer -> peer.meshPublicKey?.meshHex()?.let { it in channels } == true } else 0,
        onHall = { showPopopxCabinHall() },
        onEncryptedChannels = { showPopopxCabinChannels() },
      )

      PopopxCabinNearbyCard(
        peers = peers,
        radio = radio,
        enabled = enabled,
        nowMillis = nowMillis,
        onOpenChat = { peer ->
          val key = cabinPeerKey(peer) ?: return@PopopxCabinNearbyCard
          showPopopxCabinPrivateChat(key)
        },
        onTurnOnFuse = { uiScope.launch { fuse.setEnabled(true) } },
        onRescan = { uiScope.launch { fuse.engine()?.let { store.seed(it) } } },
      )
    }
  }
}

// MARK: - header

/**
 * The page header plus iOS' top-trailing "Settings" capsule (`meshSettingsEntry`). Android's tab shell
 * draws no per-page top bar, so the capsule sits at the top of the page content, level with the title;
 * the dot on it is the fuse state, the same fact the first card in the sheet reports.
 */
@Composable
private fun CabinHeader(enabled: Boolean) {
  val relayHopCap = PopopxMeshConfig.default.fragmentRelayTtlCap
  val broadcastTTL = PopopxMeshConfig.default.ttlDefault
  val entryLabel = stringResource(MR.strings.cabin_settings_entry)
  val stateWords = stringResource(
    if (enabled) MR.strings.cabin_settings_fuse_open else MR.strings.cabin_settings_fuse_closed
  )
  Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
      Text(
        stringResource(MR.strings.cabin_page_title),
        style = PopopxTypeScale.title2,
      )
      Text(
        stringResource(MR.strings.cabin_page_explainer, relayHopCap, broadcastTTL),
        style = PopopxTypeScale.subheadline,
        color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
      )
    }
    Spacer(Modifier.width(12.dp))
    Row(
      Modifier
        .heightIn(min = PopopxSize.control)
        .background(PopopxSurface, RoundedCornerShape(PopopxRadiusControl))
        .clickable { showPopopxCabinSettings() }
        .padding(horizontal = 10.dp)
        .semantics {
          contentDescription = entryLabel
          stateDescription = stateWords
        },
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
      Icon(painterResource(MR.images.ic_settings), null, Modifier.size(16.dp), tint = PopopxMeshInk)
      Box(
        Modifier
          .size(6.dp)
          .background(
            if (enabled) PopopxMesh else MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.hint),
            CircleShape,
          )
      )
      Text(stringResource(MR.strings.cabin_settings_capsule), style = PopopxTypeScale.subheadline, maxLines = 1)
    }
  }
}

// MARK: - channels

/**
 * `PopopxCabinView.channelsCard`: the channel entries of the page. The hall and the encrypted-channel
 * screens are real; the offline group row keeps iOS' three-row shape and says "not in this build" instead
 * of opening a screen whose engine layer (GROUP_STATE / GROUP_MESSAGE) is not mounted on this platform.
 */
@Composable
private fun PopopxCabinChannelsCard(
  enabled: Boolean,
  broadcastCount: Int,
  channelCount: Int,
  onHall: () -> Unit,
  onEncryptedChannels: () -> Unit,
) {
  PopopxSection(
    title = stringResource(MR.strings.cabin_channels_title),
    footnote = stringResource(MR.strings.cabin_channels_footnote),
  ) {
    PopopxPickerRow(
      label = stringResource(MR.strings.cabin_hall_row),
      value = when {
        !enabled -> stringResource(MR.strings.cabin_fuse_off_value)
        broadcastCount == 0 -> stringResource(MR.strings.cabin_hall_empty)
        else -> stringResource(MR.strings.cabin_hall_count, broadcastCount)
      },
      icon = MR.images.ic_forum,
      onClick = onHall,
      tint = PopopxMesh,
    )
    PopopxDivider()
    PopopxPickerRow(
      label = stringResource(MR.strings.cabin_channels_row),
      value = if (!enabled) {
        stringResource(MR.strings.cabin_fuse_off_value)
      } else {
        stringResource(MR.strings.cabin_encrypted_channels_value, channelCount)
      },
      icon = MR.images.ic_lock_filled,
      onClick = onEncryptedChannels,
      tint = PopopxMesh,
    )
    PopopxDivider()
    PopopxPickerRow(
      label = stringResource(MR.strings.cabin_groups_row),
      value = stringResource(MR.strings.cabin_groups_absent),
      icon = MR.images.ic_group_filled,
      enabled = false,
      onClick = {},
      tint = PopopxMesh,
    )
  }
}

// MARK: - master switch and radio

/**
 * The master switch + the radio + the time of the last broadcast heard within range, as the three facts
 * iOS keeps apart. A single "connected/disconnected" label would collapse them, and they disagree in real
 * life: the radio can be on with the fuse off, and the fuse on with nothing in range.
 */
@Composable
private fun PopopxCabinStatusCard(
  radio: PopopxBluetoothState,
  phase: PopopxMeshFusePhase,
  enabled: Boolean,
  latestBroadcastAt: Long?,
  nowMillis: Long,
  onToggle: (Boolean) -> Unit,
) {
  val busy = phase == PopopxMeshFusePhase.STARTING || phase == PopopxMeshFusePhase.STOPPING
  val windowSeconds = PopopxMeshConfig.default.peerReachabilityTimeout.toInt()
  PopopxSection(
    title = stringResource(MR.strings.cabin_status_title),
    footnote = if (enabled) {
      stringResource(MR.strings.cabin_status_footnote, windowSeconds)
    } else {
      stringResource(MR.strings.cabin_fuse_off_footnote)
    },
  ) {
    Row(
      Modifier.fillMaxWidth().heightIn(min = PopopxSize.control).padding(vertical = 8.dp),
      verticalAlignment = Alignment.CenterVertically,
    ) {
      Column(Modifier.weight(1f)) {
        Text(stringResource(MR.strings.cabin_switch), style = PopopxTypeScale.headline)
        Spacer(Modifier.height(2.dp))
        Text(
          if (enabled) stringResource(MR.strings.cabin_fuse_note_on) else stringResource(MR.strings.cabin_fuse_note_off),
          style = PopopxTypeScale.subheadline,
          color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
        )
      }
      Spacer(Modifier.width(12.dp))
      PopopxSwitch(
        checked = enabled,
        onCheckedChange = onToggle,
        enabled = !busy,
      )
    }
    PopopxDivider()
    Row(
      Modifier.fillMaxWidth().padding(vertical = 8.dp),
      verticalAlignment = Alignment.CenterVertically,
    ) {
      PopopxIconBadge(
        if (radio.isUsable) MR.images.ic_wifi_tethering else MR.images.ic_wifi_off,
        if (radio.isUsable) PopopxMeshInk else MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
      )
      Spacer(Modifier.width(12.dp))
      Column(Modifier.weight(1f)) {
        Text(
          cabinRadioWords(radio),
          style = PopopxTypeScale.body.copy(fontWeight = FontWeight.SemiBold),
        )
        Spacer(Modifier.height(2.dp))
        Text(
          radioFootnote(enabled, latestBroadcastAt, nowMillis),
          style = PopopxTypeScale.subheadline,
          color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
        )
      }
    }
  }
}

@Composable
private fun radioFootnote(enabled: Boolean, latestBroadcastAt: Long?, nowMillis: Long): String = when {
  !enabled -> stringResource(MR.strings.cabin_fuse_off_radio_note)
  latestBroadcastAt == null -> stringResource(MR.strings.cabin_no_broadcast_yet)
  else -> stringResource(MR.strings.cabin_last_broadcast, cabinSince(latestBroadcastAt, nowMillis))
}

// MARK: - nearby nodes (radar + per-device rows)

/**
 * `PopopxCabinNearbyCard` of iOS: the radar, the overflow note, the one real enable button when the master
 * switch is closed, and the per-device rows. The hop ceiling, TTL, silence window and dense-network
 * thresholds are read from `PopopxMeshConfig`, the same constants the iOS view cites, rather than passed in.
 */
@Composable
internal fun PopopxCabinNearbyCard(
  peers: List<PopopxMeshPeer>,
  radio: PopopxBluetoothState,
  enabled: Boolean,
  nowMillis: Long,
  onOpenChat: (PopopxMeshPeer) -> Unit,
  onTurnOnFuse: () -> Unit,
  onRescan: () -> Unit,
) {
  val hopCap = PopopxMeshConfig.default.fragmentRelayTtlCap
  val broadcastTTL = PopopxMeshConfig.default.ttlDefault
  val denseHopCap = PopopxMeshConfig.default.denseBroadcastTtlCap
  val highDegreeThreshold = PopopxMeshConfig.default.highDegreeThreshold
  val windowSeconds = PopopxMeshConfig.default.peerReachabilityTimeout.toInt()
  // A closed master switch means no scanning and no relaying, so a table left over from before it was
  // closed must not stay on screen looking alive; iOS' fold answers with empty tables in that case too.
  val visible = if (enabled) peers else emptyList()
  val directCount = visible.count { it.isDirect }
  val footnote = when {
    !enabled -> stringResource(MR.strings.cabin_fuse_off_footnote)
    directCount > highDegreeThreshold -> stringResource(MR.strings.cabin_nearby_dense_note, highDegreeThreshold, denseHopCap)
    else -> stringResource(
      MR.strings.cabin_nearby_footnote,
      windowSeconds,
      PopopxCabinReach.METRES_PER_HOP,
      broadcastTTL,
      cabinReachRadius(broadcastTTL),
    )
  }
  PopopxSection(
    title = stringResource(MR.strings.cabin_nearby_title, hopCap),
    footnote = footnote,
  ) {
    PopopxCabinRadar(
      peers = visible,
      hopCap = hopCap,
      markerLimit = RADAR_MARKER_LIMIT,
      scanning = enabled && radio.isUsable,
      nowMillis = nowMillis,
    )
    if (visible.size > RADAR_MARKER_LIMIT) {
      Text(
        stringResource(MR.strings.cabin_radar_overflow, visible.size, RADAR_MARKER_LIMIT),
        style = PopopxTypeScale.subheadline,
        color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
        modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
      )
    } else {
      Spacer(Modifier.height(16.dp))
    }
    when {
      !enabled -> PopopxPrimaryButton(
        text = stringResource(MR.strings.cabin_fuse_turn_on),
        icon = MR.images.ic_wifi_tethering,
        modifier = Modifier.fillMaxWidth(),
        onClick = onTurnOnFuse,
      )
      visible.isEmpty() -> {
        Text(
          if (radio.isUsable) {
            stringResource(MR.strings.cabin_nearby_empty_scanning)
          } else {
            cabinRadioWords(radio)
          },
          style = PopopxTypeScale.subheadline,
          color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
        )
        Spacer(Modifier.height(8.dp))
        PopopxSecondaryButton(
          text = stringResource(MR.strings.cabin_nearby_rescan),
          icon = MR.images.ic_refresh,
          modifier = Modifier.fillMaxWidth(),
          onClick = onRescan,
        )
      }
      else -> visible.forEachIndexed { index, peer ->
        PopopxCabinNodeRow(
          peer = peer,
          reachable = cabinIsReachable(peer, nowMillis),
          nowMillis = nowMillis,
          onOpenChat = { onOpenChat(peer) },
        )
        if (index < visible.size - 1) PopopxDivider()
      }
    }
  }
}

/** The radar draws at most this many dots on one screen; the extras are still listed in full in the rows below. */
private const val RADAR_MARKER_LIMIT = 12

/** The pulse radius the reduced-motion radar holds: mid-travel, so the ring is visible and still. */
private const val STATIC_RADAR_PULSE = 0.5f

private val radarSide = 144.dp
private val radarDotSide = 20.dp

/**
 * The concentric radar of nearby nodes. The static part is rings + hop numbers; the moving ring is one
 * teal pulse travelling outward, held still when the system asks for reduced motion. Position uses only
 * two real numbers: radius = hops / ceiling, angle = the index spread evenly around the circle. There is
 * no fake data.
 */
@Composable
private fun PopopxCabinRadar(
  peers: List<PopopxMeshPeer>,
  hopCap: Int,
  markerLimit: Int,
  scanning: Boolean,
  nowMillis: Long,
) {
  val mesh = PopopxMesh
  val reduced = popopxReducedMotion()
  val shown = peers.take(markerLimit)
  val onlineCount = peers.count { cabinIsReachable(it, nowMillis) }
  val label = stringResource(MR.strings.cabin_radar_label, onlineCount, peers.size)
  val pulse by if (reduced) {
    remember { mutableStateOf(STATIC_RADAR_PULSE) }
  } else {
    val transition = rememberInfiniteTransition(label = "popopx-cabin-radar")
    transition.animateFloat(
      initialValue = 0f,
      targetValue = 1f,
      animationSpec = infiniteRepeatable(
        animation = tween(durationMillis = PopopxDuration.radar, easing = LinearOutSlowInEasing),
        repeatMode = RepeatMode.Restart,
      ),
      label = "popopx-cabin-radar-pulse",
    )
  }
  Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
    Box(
      Modifier
        .size(radarSide)
        .semantics { contentDescription = label },
      contentAlignment = Alignment.Center,
    ) {
      Canvas(Modifier.fillMaxSize()) {
        val stroke = 1.5.dp.toPx()
        val half = size.minDimension / 2
        for (index in 0..2) {
          // The further out, the more solid; the outermost ring is the hop-ceiling ring.
          val pad = size.minDimension * (0.055f + 0.135f * (2 - index))
          drawCircle(
            color = mesh.copy(alpha = 0.16f + 0.10f * index),
            radius = half - pad,
            style = Stroke(width = stroke),
          )
        }
        if (scanning) {
          val scale = 0.18f + 0.82f * pulse
          drawCircle(
            color = mesh.copy(alpha = 0.6f - 0.54f * pulse),
            radius = half * scale,
            style = Stroke(width = stroke),
          )
        }
      }
      shown.forEachIndexed { index, peer ->
        val hops = peer.hopCount.coerceIn(0, max(hopCap, 1))
        val radius: Dp = (radarSide / 2) * (0.18f + 0.74f * hops / max(hopCap, 1))
        val degrees = index.toFloat() / max(shown.size, 1) * 360f - 90f
        val radians = degrees * PI.toFloat() / 180f
        val dx: Dp = radius * cos(radians)
        val dy: Dp = radius * sin(radians)
        val online = cabinIsReachable(peer, nowMillis)
        Box(
          Modifier
            .offset {
              IntOffset(
                (dx - radarDotSide / 2).roundToPx(),
                (dy - radarDotSide / 2).roundToPx(),
              )
            }
            .size(radarDotSide)
            .background(if (online) mesh else Color.Transparent, CircleShape)
            .then(
              if (online) {
                Modifier
              } else {
                Modifier.border(
                  PopopxSize.focusRing,
                  MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.hint),
                  CircleShape,
                )
              }
            ),
          contentAlignment = Alignment.Center,
        ) {
          Text(
            peer.hopCount.toString(),
            style = PopopxTypeScale.metricSmall,
            color = if (online) PopopxOnMesh else MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
          )
        }
      }
      // The centre is this device: the mesh ink carries "this device is itself in the mesh".
      Box(
        Modifier.size(28.dp).background(PopopxMeshInk.copy(alpha = PopopxAlpha.washStrong), CircleShape),
        contentAlignment = Alignment.Center,
      ) {
        Icon(
          painterResource(MR.images.ic_wifi_tethering),
          null,
          Modifier.size(14.dp),
          tint = PopopxMeshInk,
        )
      }
    }
  }
}

/** One device row of the nearby card and of the encrypted-channel lists: name, route facts, hop badge. */
@Composable
internal fun PopopxCabinNodeRow(
  peer: PopopxMeshPeer,
  reachable: Boolean,
  nowMillis: Long,
  onOpenChat: () -> Unit,
) {
  val key = cabinPeerKey(peer)
  val label = cabinPeerLabel(peer.nickname, key, peer.peerID.hex)
  val parts = mutableListOf(
    if (peer.isDirect) stringResource(MR.strings.cabin_link_direct) else stringResource(MR.strings.cabin_link_relayed),
    stringResource(MR.strings.cabin_last_heard, cabinSince(peer.lastSeenAtMillis, nowMillis)),
  )
  peer.rssi?.let { parts.add("${it.toInt()} dBm") }
  if (!reachable) parts.add(stringResource(MR.strings.cabin_out_of_range))
  if (key == null) parts.add(stringResource(MR.strings.cabin_no_key_mark))
  Row(
    Modifier
      .fillMaxWidth()
      .clip(RoundedCornerShape(10.dp))
      .clickable(enabled = key != null, onClick = onOpenChat)
      .padding(vertical = 8.dp, horizontal = 4.dp),
    verticalAlignment = Alignment.CenterVertically,
  ) {
    Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
      Box(
        Modifier
          .fillMaxSize()
          .border(
            PopopxSize.focusRing,
            if (reachable) PopopxMesh else MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.hint),
            CircleShape,
          )
      )
      if (reachable) Box(Modifier.size(4.dp).background(PopopxMesh, CircleShape))
    }
    Spacer(Modifier.width(12.dp))
    Column(Modifier.weight(1f)) {
      val fallback = peer.nickname.isNullOrBlank()
      Text(
        label,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        // A fallback label is a machine value (a key or wire-id prefix) and keeps its LTR order under RTL.
        style = PopopxTypeScale.body.copy(
          fontWeight = FontWeight.SemiBold,
          textDirection = if (fallback) TextDirection.Ltr else TextDirection.Content,
        ),
      )
      Spacer(Modifier.height(2.dp))
      Text(
        parts.joinToString(" · "),
        style = PopopxTypeScale.subheadline,
        color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
      )
    }
    Spacer(Modifier.width(8.dp))
    CabinHopBadge(peer.hopCount)
  }
}

// MARK: - failure words

/** `MeshPlazaView.words(for:)`, branch for branch — including the radio case, which reuses the page's wording. */
@Composable
internal fun cabinFailureWords(failure: PopopxMeshSendFailure): String = when (failure) {
  is PopopxMeshSendFailure.NoLinkToPeer -> stringResource(MR.strings.cabin_fail_no_link)
  is PopopxMeshSendFailure.LinkDropped -> stringResource(MR.strings.cabin_fail_link_dropped)
  is PopopxMeshSendFailure.TtlExhausted -> stringResource(MR.strings.cabin_fail_ttl_exhausted)
  is PopopxMeshSendFailure.Oversized ->
    stringResource(MR.strings.cabin_fail_oversized, failure.payloadBytes, failure.limitBytes)
  is PopopxMeshSendFailure.NoSessionWithPeer -> stringResource(MR.strings.cabin_fail_no_session)
  is PopopxMeshSendFailure.RadioUnavailable -> cabinRadioWords(failure.state)
}

/** One bubble's worth of text on one screen — `PopopxMeshPlazaModel.maxDraftCharacters`. */
internal const val CABIN_MAX_DRAFT_CHARACTERS: Int = 512

private val CABIN_GUTTER = 16.dp
private val CABIN_SECTION_GAP = 24.dp