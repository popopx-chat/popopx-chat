package chat.popopx.common.signal

import chat.popopx.common.model.CIDeleteMode
import chat.popopx.common.model.Chat
import chat.popopx.common.model.ChatDeleteMode
import chat.popopx.common.model.ChatInfo
import chat.popopx.common.model.ChatModel
import chat.popopx.common.model.ChatType
import chat.popopx.common.model.ComposedMessage
import chat.popopx.common.model.CreatedConnLink
import chat.popopx.common.model.MsgContent

// The FFI half of the silent signalling router, written against the same host calls
// `chat.popopx.common.eco.PopopxEcoHostSender` uses, for the same reasons: these frames go out as ordinary
// text messages with `live = false, ttl = null` and disappear again through an INTERNAL deletion, so the peer
// sees a message and never a "message was deleted" notice (router:675-676, :690-693).
//
// The stub `PopopxSilentTransportAdapter` answers every call with failure on purpose; this class is the bound
// build it says a bound build must be. Nothing here decides protocol semantics — it only reaches the model,
// turns a host answer into the Bool/Long?/Invite? the router expects, and pushes the sent rows into the
// timeline so the sender's own conversation stays consistent with the database.

/**
 * Resolving the chat is done by [PopopxSignalTarget]'s own id space: the router passes `chatInfo.apiId`
 * (contactId for a direct chat, groupId for a group), which is what `apiSendMessages` and
 * `apiDeleteChatItems` take as `id`, and never the local `ChatInfo.id`.
 */
/**
 * The two answers the router is documented to get from the app layer rather than compute itself.
 * Settable so a test can drive a leg without a live model; the defaults read the real one.
 */
object PopopxSilentSignalHost {
  /**
   * router:574-583 — "is this device's member record really an ACTIVE admin or above in that channel".
   * `GroupInfo.canAddMembers` is the model's own definition of that criterion (role ≥ Admin and the member row
   * is active), so the interface and the send share one value instead of two similar-looking predicates.
   */
  var channelAdminAt: (groupId: Long) -> Boolean = { groupId ->
    val info = ChatModel.chats.value.firstOrNull {
      it.chatInfo.apiId == groupId && it.chatInfo.chatType == ChatType.Group
    }?.chatInfo as? ChatInfo.Group
    info?.groupInfo?.canAddMembers == true
  }
}

class PopopxSilentHostTransport : PopopxSilentTransport {
  override suspend fun send(
    chatId: Long,
    isGroup: Boolean,
    text: String,
    live: Boolean,
    ttlSeconds: Int?,
  ): Boolean {
    val chat = chatFor(chatId, isGroup) ?: return false
    val cInfo = chat.chatInfo
    val rhId = chat.remoteHostId
    val items = ChatModel.controller.apiSendMessages(
      rh = rhId,
      type = cInfo.chatType,
      id = cInfo.apiId,
      scope = cInfo.groupChatScope(),
      sendAsGroup = cInfo.sendAsGroup,
      // Verbatim from the caller, never defaulted here: the router's own measurements pin live=false and
      // ttl=null, and a live send would pin the peer's SMP connection open.
      live = live,
      ttl = ttlSeconds,
      sign = false,
      composedMessages = listOf(ComposedMessage(null, null, MsgContent.MCText(text), mapOf()))
    )
    if (items.isNullOrEmpty()) return false
    for (item in items) ChatModel.chatsContext.addChatItem(rhId, item.chatInfo, item.chatItem)
    return true
  }

  override suspend fun delete(chatId: Long, itemIds: List<Long>, mode: PopopxSilentDeleteMode): Boolean {
    val chat = chatFor(chatId, isGroup = true) ?: chatFor(chatId, isGroup = false) ?: return false
    val cInfo = chat.chatInfo
    val deletions = ChatModel.controller.apiDeleteChatItems(
      chat.remoteHostId,
      type = cInfo.chatType,
      id = cInfo.apiId,
      scope = cInfo.groupChatScope(),
      itemIds = itemIds,
      // The two enums name the same four core tiers with the same wire strings, so the mapping is a lookup on
      // that string rather than four branches that can silently disagree when a tier is added to one side.
      // Signalling only ever passes INTERNAL; the other three are here because the seam accepts them.
      mode = CIDeleteMode.entries.firstOrNull { it.deleteMode == mode.wireName } ?: CIDeleteMode.cidmInternal
    )
    if (deletions == null) return false
    for (deletion in deletions) {
      val toChatItem = deletion.toChatItem
      if (toChatItem != null) {
        ChatModel.chatsContext.upsertChatItem(chat.remoteHostId, toChatItem.chatInfo, toChatItem.chatItem)
      } else {
        ChatModel.chatsContext.removeChatItem(chat.remoteHostId, deletion.deletedChatItem.chatInfo, deletion.deletedChatItem.chatItem)
      }
    }
    return true
  }

  override suspend fun addContact(incognito: Boolean): PopopxSignalInvite? {
    val rhId = ChatModel.currentUser.value?.remoteHostId
    val (created, _) = ChatModel.controller.apiAddContact(rhId, incognito) ?: return null
    // The second half of the host's pair is the UI's "discard this invitation" closure. It is deliberately
    // not invoked: the link this call made is the one the code is about to be printed on, and discarding it
    // here would leave the caller with a link that no longer exists.
    if (created == null) return null
    return PopopxSignalInvite(connFullLink = created.first.connFullLink, connId = created.second.pccConnId)
  }

  override suspend fun connect(incognito: Boolean, connFullLink: String): Long? {
    val rhId = ChatModel.currentUser.value?.remoteHostId
    // The stored wire is the full link; the short link is not kept in the pending table, so it is absent
    // here and `apiConnect` only reads `connFullLink` (PopopxAPI.kt:1697).
    val pcc = ChatModel.controller.apiConnect(rhId, incognito, CreatedConnLink(connFullLink, null)) ?: return null
    ChatModel.chatsContext.updateContactConnection(rhId, pcc)
    return pcc.pccConnId
  }

  override suspend fun deleteContact(contactId: Long, notifyPeer: Boolean): Boolean {
    val rhId = ChatModel.currentUser.value?.remoteHostId
    val contact = ChatModel.controller.apiDeleteContact(rhId, contactId, chatDeleteMode = chatDeleteMode(notifyPeer))
    if (contact == null) return false
    ChatModel.chatsContext.updateContact(rhId, contact)
    return true
  }

  /** Kept out of the model file: the notify flag is the only difference the signalling layer cares about. */
  private fun chatDeleteMode(notifyPeer: Boolean): ChatDeleteMode = ChatDeleteMode.Full(notify = notifyPeer)

  private fun chatFor(apiId: Long, isGroup: Boolean): Chat? {
    val type = if (isGroup) ChatType.Group else ChatType.Direct
    return ChatModel.chats.value.firstOrNull { it.chatInfo.apiId == apiId && it.chatInfo.chatType == type }
  }
}
