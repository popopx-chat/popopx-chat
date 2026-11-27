package chat.popopx.common.views.cabin

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.dp
import chat.popopx.common.mesh.PopopxMeshEnvelope
import chat.popopx.common.mesh.PopopxMeshKillSwitch
import chat.popopx.common.mesh.PopopxMeshPeer
import chat.popopx.common.mesh.PopopxMeshSendError
import chat.popopx.common.mesh.PopopxMeshSendFailure
import chat.popopx.common.mesh.meshHex
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.platform.showToast
import chat.popopx.common.ui.components.PopopxPrimaryButton
import chat.popopx.common.ui.components.PopopxSecondaryButton
import chat.popopx.common.ui.components.PopopxSection
import chat.popopx.common.ui.theme.PopopxAlpha
import chat.popopx.common.ui.theme.PopopxFieldSurface
import chat.popopx.common.ui.theme.PopopxMeshInk
import chat.popopx.common.ui.theme.PopopxRadiusControl
import chat.popopx.common.ui.theme.PopopxSize
import chat.popopx.common.ui.theme.PopopxTypeScale
import chat.popopx.common.views.helpers.AppBarTitle
import chat.popopx.common.views.helpers.DefaultBasicTextField
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID

// The 1:1 offline conversation with ONE mesh neighbour — the private half of the Cabin, ported from
// `PopopxMeshPrivateChatView` (`apps/ios/PopopxMeshKit/Sources/PopopxMeshUI/PopopxMeshPrivateChatView.swift`)
// as it is presented from the Cabin (`PopopxCabinView.swift:445-456`): a pushed page titled with the
// peer's name, a reach header, the conversation, and the composer pinned below it.
//
// What the conversation is: one envelope per message through the engine's Noise path, addressed to the
// peer's mesh public key and nothing else — no SMP request and no router is involved. The thread here
// lives in `PopopxCabinStore.privateThreads`, keyed the way the send call takes the peer, so the sent
// and the received halves land in one conversation.
//
// Deliberately absent, and said rather than faked: the iOS screen's pairing banner and its
// "not paired" empty-state family. This port has no pairing state to read (module 3's seam does not
// exist here), so the screen does not claim one; a send that the mesh refuses is reported on its own
// row and in the composer note instead. The nickname row is the same store the hall edits, so there is
// still exactly one nickname.

fun showPopopxCabinPrivateChat(meshPublicKeyHex: String) {
  ModalManager.start.showModalCloseable(cardScreen = true) {
    PopopxCabinPrivateChatView(meshPublicKeyHex)
  }
}

@Composable
private fun PopopxCabinPrivateChatView(meshPublicKeyHex: String) {
  val store = PopopxCabinStore.shared
  val fuse = PopopxMeshKillSwitch.shared
  val uiScope = rememberCoroutineScope()

  val enabled by fuse.isEnabled.collectAsState()
  val radio by store.radioState.collectAsState()
  val peers by store.peers.collectAsState()
  val threads by store.privateThreads.collectAsState()
  val nickname by fuse.nickname.collectAsState()

  var nowMillis by remember { mutableStateOf(System.currentTimeMillis()) }
  LaunchedEffect(Unit) {
    while (true) {
      delay(2_000)
      nowMillis = System.currentTimeMillis()
    }
  }

  val peer = peers.firstOrNull { it.meshPublicKey?.meshHex() == meshPublicKeyHex }
  val peerName = cabinPeerLabel(peer?.nickname, meshPublicKeyHex, meshPublicKeyHex)
  val thread = threads[meshPublicKeyHex].orEmpty()

  val draft = rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue("")) }
  var sending by remember { mutableStateOf(false) }
  var failure by remember { mutableStateOf<PopopxMeshSendFailure?>(null) }
  val nicknameDraft = rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(nickname.orEmpty())) }
  // Save replaces the field with the clamped value the fuse stored; revert puts back the stored name.
  LaunchedEffect(nickname) { nicknameDraft.value = TextFieldValue(nickname.orEmpty()) }

  fun send() {
    val text = draft.value.text.trim()
    if (text.isEmpty() || sending) return
    val body = text.take(CABIN_MAX_DRAFT_CHARACTERS)
    val envelope = PopopxMeshEnvelope.text(UUID.randomUUID().toString().lowercase(), body)
    sending = true
    uiScope.launch {
      try {
        val engine = fuse.engine()
        // The draft survives a refusal, and the row is filed either way so the failure is visible where
        // the words are; only a send the mesh accepted clears the field.
        val result = runCatching { requireNotNull(engine).send(envelope, meshPublicKeyHex) }
        store.noteLocalPrivate(body, meshPublicKeyHex, envelope.id, failed = result.isFailure)
        if (result.isFailure) {
          failure = (result.exceptionOrNull() as? PopopxMeshSendError)?.failure
        } else {
          // A send that sealed an envelope proves the session, which is what the channels list counts.
          store.noteChannel(meshPublicKeyHex)
          draft.value = TextFieldValue("")
          failure = null
        }
      } finally {
        sending = false
      }
    }
  }

  AppBarTitle(peerName)
  Column(Modifier.fillMaxSize().imePadding()) {
    ColumnWithScrollBar(Modifier.weight(1f).fillMaxWidth()) {
      Column(
        Modifier
          .padding(horizontal = 16.dp)
          .padding(top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
      ) {
        if (peer != null) PrivateChatReachLine(peer, nowMillis)
        PopopxSection(
          title = stringResource(MR.strings.cabin_chat_heading),
          footnote = stringResource(MR.strings.cabin_chat_footnote),
        ) {
          if (thread.isEmpty()) {
            Text(
              stringResource(MR.strings.cabin_chat_empty),
              style = PopopxTypeScale.subheadline,
              color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
            )
          } else {
            thread.forEach { post ->
              PrivateChatBubble(post, peerName, peer?.nickname)
            }
          }
        }
        if (!enabled) {
          PopopxSection(
            title = stringResource(MR.strings.cabin_fuse_off_headline),
            footnote = stringResource(MR.strings.cabin_fuse_off_footnote),
          ) {
            PopopxPrimaryButton(
              text = stringResource(MR.strings.cabin_fuse_turn_on),
              icon = MR.images.ic_wifi_tethering,
              modifier = Modifier.fillMaxWidth(),
              onClick = { uiScope.launch { fuse.setEnabled(true) } },
            )
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
            style = PopopxTypeScale.subheadline,
            color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
          )
        }
        val note = failure?.let { cabinFailureWords(it) }
        when {
          note != null -> Text(note, style = PopopxTypeScale.subheadline, color = MaterialTheme.colors.error)
          draft.value.text.length > CABIN_MAX_DRAFT_CHARACTERS ->
            Text(
              "${draft.value.text.length} / $CABIN_MAX_DRAFT_CHARACTERS",
              style = PopopxTypeScale.subheadline,
              color = MaterialTheme.colors.error,
            )
        }
        PrivateChatNicknameRow(
          nicknameDraft = nicknameDraft,
          onSave = {
            uiScope.launch {
              fuse.setNickname(nicknameDraft.value.text)
              showToast(generalGetString(MR.strings.cabin_nickname_saved_toast))
            }
          },
          onRevert = { nicknameDraft.value = TextFieldValue(nickname.orEmpty()) },
        )
        CabinSendRow(
          value = draft,
          fieldLabel = stringResource(MR.strings.cabin_chat_field),
          placeholder = stringResource(MR.strings.cabin_chat_placeholder),
          action = stringResource(MR.strings.cabin_chat_send),
          enabled = radio.isUsable && draft.value.text.isNotBlank() && !sending,
          onSubmit = { send() },
        )
      }
    }
  }
}

/** `peerReachDescription`: how far the peer is, how it is carried, and when it was last heard. */
@Composable
private fun PrivateChatReachLine(peer: PopopxMeshPeer, nowMillis: Long) {
  val reach = listOfNotNull(
    cabinReachRadius(peer.hopCount),
    stringResource(if (peer.isDirect) MR.strings.cabin_link_direct else MR.strings.cabin_link_relayed),
    stringResource(MR.strings.cabin_last_heard, cabinSince(peer.lastSeenAtMillis, nowMillis)),
  ).joinToString(" · ")
  Text(
    reach,
    style = PopopxTypeScale.caption,
    color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
  )
}

/** The plaza's nickname, edited on the same store: one name, two rooms that show it. */
@Composable
private fun PrivateChatNicknameRow(
  nicknameDraft: MutableState<TextFieldValue>,
  onSave: () -> Unit,
  onRevert: () -> Unit,
) {
  val fieldLabel = stringResource(MR.strings.cabin_nickname_field)
  Row(
    Modifier.fillMaxWidth(),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    DefaultBasicTextField(
      modifier = Modifier
        .weight(1f)
        .background(PopopxFieldSurface, RoundedCornerShape(PopopxRadiusControl))
        .heightIn(min = PopopxSize.control)
        .padding(horizontal = 12.dp, vertical = 10.dp)
        .semantics { contentDescription = fieldLabel },
      state = nicknameDraft,
      placeholder = {
        Text(
          stringResource(MR.strings.cabin_nickname_prompt),
          style = PopopxTypeScale.calloutSmall,
          color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
        )
      },
      onValueChange = { nicknameDraft.value = it },
    )
    // The shared button fills its width; inside this row it keeps the intrinsic one.
    PopopxSecondaryButton(
      text = stringResource(MR.strings.cabin_nickname_save),
      modifier = Modifier.width(IntrinsicSize.Max),
      onClick = { onSave() },
    )
    Text(
      stringResource(MR.strings.cabin_nickname_revert),
      style = PopopxTypeScale.calloutSmall,
      color = PopopxMeshInk,
      modifier = Modifier
        .heightIn(min = PopopxSize.control)
        .clickable { onRevert() }
        .padding(horizontal = 4.dp, vertical = 12.dp),
    )
  }
}

/** One row of the conversation: outgoing to the trailing edge, incoming to the leading one, and the
 * failed marker on the row the mesh refused rather than on the screen. */
@Composable
private fun PrivateChatBubble(
  post: PopopxCabinPost,
  peerName: String,
  peerNickname: String?,
) {
  val bubbleWords = stringResource(MR.strings.cabin_bubble_label, peerName, post.hopCount, post.text)
  Column(
    Modifier
      .fillMaxWidth()
      .padding(vertical = 4.dp),
    horizontalAlignment = if (post.mine) Alignment.End else Alignment.Start,
  ) {
    Text(
      post.text,
      style = PopopxTypeScale.callout,
      modifier = if (post.mine) Modifier else Modifier.semantics { contentDescription = bubbleWords },
    )
    Row(
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
      if (!post.mine) {
        Text(
          peerName,
          style = if (peerNickname.isNullOrBlank()) {
            PopopxTypeScale.overline.copy(textDirection = TextDirection.Ltr)
          } else {
            PopopxTypeScale.overline
          },
          color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
        )
      }
      if (post.failed) {
        Text(stringResource(MR.strings.cabin_failed), style = PopopxTypeScale.overline, color = MaterialTheme.colors.error)
      }
      Text(
        cabinClock(post.atMillis),
        style = PopopxTypeScale.metricSmall,
        color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
      )
    }
  }
}