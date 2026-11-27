package chat.popopx.common.views.cabin

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.DropdownMenu
import androidx.compose.material.DropdownMenuItem
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.mesh.PopopxMeshKillSwitch
import chat.popopx.common.mesh.PopopxMeshNicknameStore
import chat.popopx.common.mesh.PopopxMeshPeer
import chat.popopx.common.mesh.PopopxMeshSendError
import chat.popopx.common.mesh.PopopxMeshSendFailure
import chat.popopx.common.mesh.meshHex
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.platform.showToast
import chat.popopx.common.ui.theme.PopopxMeshInk
import chat.popopx.common.views.helpers.AppBarTitle
import chat.popopx.common.views.helpers.DefaultBasicTextField
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID

// `PopopxCabinHallView` of `apps/ios/Shared/Features/Cabin/PopopxCabinView.swift:1841-2202`: the whole
// "#Cabin Hall" screen — the complete broadcast stream, this device's temporary nickname, and the broadcast
// input. The top-right "discovery mode" mounts the root page's own nearby card (`PopopxCabinNearbyCard`),
// the same view with the same peers, rather than a second list.
//
// Presenting it as the app's full-screen modal keeps the iOS shape: it is a pushed page with its own top
// bar, not a section of the Cabin tab. The composer is pinned below the scroll area, so the keyboard rises
// against it the way it does on the main chat page.
//
// Deliberately absent on Android, and said rather than faked: the speaker menu's "send a friend request"
// action. This engine relays PAIRING_REQUEST frames but exposes no pairing state or send call, so the menu
// offers the one offline action that exists — the private chat — and nothing that cannot happen.

fun showPopopxCabinHall() {
  // Read by both the top-bar chip and the content, so the chip *is* the discovery state and the page does
  // not keep a second copy of it.
  val showsDiscovery = mutableStateOf(false)
  ModalManager.start.showModalCloseable(
    cardScreen = true,
    endButtons = {
      CabinDiscoveryChip(showsDiscovery.value) { showsDiscovery.value = !showsDiscovery.value }
    },
  ) {
    PopopxCabinHallView(showsDiscovery)
  }
}

@Composable
private fun PopopxCabinHallView(showsDiscovery: MutableState<Boolean>) {
  val store = PopopxCabinStore.shared
  val fuse = PopopxMeshKillSwitch.shared
  val uiScope = rememberCoroutineScope()

  val enabled by fuse.isEnabled.collectAsState()
  val radio by store.radioState.collectAsState()
  val peers by store.peers.collectAsState()
  val posts by store.broadcasts.collectAsState()
  val nickname by fuse.nickname.collectAsState()

  var nowMillis by remember { mutableStateOf(System.currentTimeMillis()) }
  LaunchedEffect(Unit) {
    while (true) {
      delay(2_000)
      nowMillis = System.currentTimeMillis()
    }
  }

  val draft = rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue("")) }
  var sending by remember { mutableStateOf(false) }
  var failure by remember { mutableStateOf<PopopxMeshSendFailure?>(null) }
  val nicknameDraft = rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(nickname.orEmpty())) }
  // A save replaces the draft with the clamped value the fuse actually stored, so the field never shows a
  // name the mesh did not take.
  LaunchedEffect(nickname) { nicknameDraft.value = TextFieldValue(nickname.orEmpty()) }

  fun send() {
    val text = draft.value.text.trim()
    if (text.isEmpty() || sending) return
    val body = text.take(CABIN_MAX_DRAFT_CHARACTERS)
    sending = true
    uiScope.launch {
      try {
        val engine = fuse.engine()
        // iOS keeps the draft until the send succeeds and only then clears it, so a failure never destroys
        // the words; the row is added either way and marked when the radio refused it.
        val result = runCatching { requireNotNull(engine).sendBroadcast(body) }
        val messageId = result.getOrNull() ?: UUID.randomUUID().toString().lowercase()
        store.noteLocal(body, messageId, failed = result.isFailure)
        if (result.isFailure) {
          failure = (result.exceptionOrNull() as? PopopxMeshSendError)?.failure
        } else {
          draft.value = TextFieldValue("")
          failure = null
        }
      } finally {
        sending = false
      }
    }
  }

  AppBarTitle(stringResource(MR.strings.cabin_hall_row))
  Column(Modifier.fillMaxSize().imePadding()) {
    ColumnWithScrollBar(Modifier.weight(1f).fillMaxWidth()) {
      Column(
        Modifier
          .padding(horizontal = 16.dp)
          .padding(top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
      ) {
        if (showsDiscovery.value) {
          PopopxCabinNearbyCard(
            peers = peers,
            radio = radio,
            enabled = enabled,
            nowMillis = nowMillis,
            onOpenChat = { peer -> openPeerChat(peer) },
            onTurnOnFuse = { uiScope.launch { fuse.setEnabled(true) } },
            onRescan = { uiScope.launch { fuse.engine()?.let { store.seed(it) } } },
          )
        }

        CabinSectionCard(
          title = stringResource(MR.strings.cabin_hall_channel, posts.size),
          footnote = stringResource(MR.strings.cabin_hall_footnote),
        ) {
          HallFeed(posts, peers)
        }

        if (enabled) {
          CabinSectionCard(
            title = stringResource(MR.strings.cabin_nickname_title),
            footnote = stringResource(
              MR.strings.cabin_nickname_footnote,
              PopopxMeshNicknameStore.DEFAULT_NICKNAME,
              PopopxMeshNicknameStore.MAX_CHARACTERS,
            ),
          ) {
            Row(
              Modifier.fillMaxWidth(),
              verticalAlignment = Alignment.CenterVertically,
              horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
              DefaultBasicTextField(
                modifier = Modifier
                  .weight(1f)
                  .background(MaterialTheme.colors.surface, RoundedCornerShape(12.dp))
                  .heightIn(min = 44.dp)
                  .padding(horizontal = 12.dp, vertical = 10.dp),
                state = nicknameDraft,
                placeholder = { Text(stringResource(MR.strings.cabin_nickname_prompt), fontSize = 14.sp, color = MaterialTheme.colors.onSurface.copy(alpha = cabinSecondaryAlpha)) },
                onValueChange = { nicknameDraft.value = it },
              )
              CabinSecondaryButton(stringResource(MR.strings.cabin_nickname_save)) {
                uiScope.launch {
                  fuse.setNickname(nicknameDraft.value.text)
                  showToast(generalGetString(MR.strings.cabin_nickname_saved_toast))
                }
              }
            }
          }
        } else {
          CabinSectionCard(
            title = stringResource(MR.strings.cabin_fuse_off_headline),
            footnote = stringResource(MR.strings.cabin_fuse_off_footnote),
          ) {
            CabinPrimaryButton(
              stringResource(MR.strings.cabin_fuse_turn_on),
              MR.images.ic_wifi_tethering,
              modifier = Modifier.fillMaxWidth(),
            ) { uiScope.launch { fuse.setEnabled(true) } }
          }
        }
      }
    }

    if (enabled) {
      Column(
        Modifier
          .fillMaxWidth()
          .background(MaterialTheme.colors.background)
          .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
      ) {
        if (!radio.isUsable) {
          Text(
            stringResource(MR.strings.cabin_composer_radio_off),
            fontSize = 13.sp,
            color = MaterialTheme.colors.onSurface.copy(alpha = cabinSecondaryAlpha),
          )
        }
        val note = failure?.let { cabinFailureWords(it) }
        when {
          note != null -> Text(note, fontSize = 13.sp, color = MaterialTheme.colors.error)
          draft.value.text.length > CABIN_MAX_DRAFT_CHARACTERS ->
            Text("${draft.value.text.length} / $CABIN_MAX_DRAFT_CHARACTERS", fontSize = 13.sp, color = MaterialTheme.colors.error)
        }
        CabinSendRow(
          value = draft,
          fieldLabel = stringResource(MR.strings.cabin_composer_field),
          placeholder = stringResource(MR.strings.cabin_composer_prompt),
          action = stringResource(MR.strings.cabin_broadcast_send),
          enabled = radio.isUsable && draft.value.text.isNotBlank() && !sending,
          onSubmit = { send() },
        )
      }
    }
  }
}

/** The one landing point of a node row's or a bubble's tap while C3 is still to come: the private chat. */
private fun openPeerChat(peer: PopopxMeshPeer) {
  cabinPeerKey(peer)?.let { showPopopxCabinPrivateChat(it) }
}

@Composable
private fun HallFeed(posts: List<PopopxCabinPost>, peers: List<PopopxMeshPeer>) {
  if (posts.isEmpty()) {
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
      Text(
        stringResource(MR.strings.cabin_hall_empty_headline),
        fontSize = 13.sp,
        color = MaterialTheme.colors.onSurface.copy(alpha = cabinSecondaryAlpha),
      )
      Text(
        stringResource(MR.strings.cabin_hall_empty_detail),
        fontSize = 12.sp,
        color = MaterialTheme.colors.onSurface.copy(alpha = cabinSecondaryAlpha),
      )
    }
    return
  }
  val shown = posts.takeLast(60)
  shown.forEachIndexed { index, post ->
    HallBubble(post, peers)
    if (index < shown.size - 1) HallRowSeparator()
  }
}

@Composable
private fun HallBubble(post: PopopxCabinPost, peers: List<PopopxMeshPeer>) {
  val key = post.meshPublicKeyHex
  val known = peers.firstOrNull {
    if (key != null) it.meshPublicKey?.meshHex() == key else it.peerID.hex == post.author
  }
  val name = if (post.mine) {
    stringResource(MR.strings.cabin_local_author)
  } else {
    cabinPeerLabel(known?.nickname, key, post.author)
  }
  val bubbleWords = stringResource(MR.strings.cabin_bubble_label, name, post.hopCount, post.text)
  Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
      Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        if (post.mine || key == null) {
          // The local row has nothing to attach, and a neighbour whose key is not resolved has no action
          // that could succeed; both are plain text. The menu explanation lives in the hall's refusal
          // sentence instead of a dead button.
          Text(
            name,
            fontSize = 13.sp,
            color = if (post.mine) MaterialTheme.colors.onSurface else MaterialTheme.colors.onSurface.copy(alpha = cabinSecondaryAlpha),
            style = if (!post.mine && known?.nickname.isNullOrBlank()) TextStyle(textDirection = TextDirection.Ltr) else TextStyle.Default,
          )
        } else {
          HallAuthorMenu(name) { showPopopxCabinPrivateChat(key) }
        }
        if (!post.mine) CabinHopBadge(post.hopCount)
        if (post.failed) {
          Text(stringResource(MR.strings.cabin_failed), fontSize = 11.sp, color = MaterialTheme.colors.error)
        }
      }
      Text(
        post.text,
        fontSize = 15.sp,
        modifier = Modifier.semantics { contentDescription = bubbleWords },
      )
    }
    Spacer(Modifier.width(12.dp))
    Text(
      cabinClock(post.atMillis),
      fontSize = 11.sp,
      color = MaterialTheme.colors.onSurface.copy(alpha = cabinSecondaryAlpha),
    )
  }
}

/** `authorControl`: the speaker's name is the one entry point of a neighbour's broadcast. */
@Composable
private fun HallAuthorMenu(name: String, onOpenChat: () -> Unit) {
  var expanded by remember { mutableStateOf(false) }
  val hint = stringResource(MR.strings.cabin_author_menu_hint)
  Box {
    Text(
      name,
      fontSize = 13.sp,
      color = PopopxMeshInk,
      modifier = Modifier
        .heightIn(min = 44.dp)
        .clickable { expanded = true }
        .padding(horizontal = 4.dp, vertical = 12.dp)
        .semantics { contentDescription = hint },
    )
    DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
      DropdownMenuItem(onClick = {
        expanded = false
        onOpenChat()
      }) {
        Text(stringResource(MR.strings.cabin_author_chat), fontSize = 14.sp)
      }
    }
  }
}

@Composable
private fun HallRowSeparator() {
  Box(
    Modifier
      .fillMaxWidth()
      .padding(vertical = 8.dp)
      .height(1.dp)
      .background(MaterialTheme.colors.onSurface.copy(alpha = 0.08f))
  )
}