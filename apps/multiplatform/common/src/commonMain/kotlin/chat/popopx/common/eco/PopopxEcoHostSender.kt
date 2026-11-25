package chat.popopx.common.eco

import chat.popopx.common.model.CIDeleteMode
import chat.popopx.common.model.ChatModel
import chat.popopx.common.model.ChatType
import chat.popopx.common.model.ComposedMessage
import chat.popopx.common.model.MsgContent

// The FFI half of the eco router. Nothing in `PopopxEcoRouter` reaches the model, so this file is the only
// place the two meet, and it is deliberately thin: a decision that belongs to the protocol would go untested.

/**
 * Sends an eco uplink as a plain text message, following the silent-signalling router's own spelling of the
 * FFI call rather than inventing a third one.
 *
 * `apiSendMessages` does not throw — a refusal pops an app-layer prompt and returns nothing — so "null or
 * empty" IS the failure signal, and the returned items must be pushed into the model by hand or the row
 * exists on the server and in the database but not in the open conversation.
 */
class PopopxEcoHostSender : PopopxEcoSender {
  override suspend fun sendUplink(contactId: Long, text: String): PopopxEcoSendOutcome {
    val chat = ChatModel.getContactChat(contactId) ?: return PopopxEcoSendOutcome.failed(PopopxEcoSendFailure.NO_ROUTE)
    val cInfo = chat.chatInfo
    val rhId = chat.remoteHostId
    val items = ChatModel.controller.apiSendMessages(
      rh = rhId,
      type = cInfo.chatType,
      id = cInfo.apiId,
      scope = cInfo.groupChatScope(),
      sendAsGroup = cInfo.sendAsGroup,
      live = false,
      ttl = null,
      sign = false,
      composedMessages = listOf(ComposedMessage(null, null, MsgContent.MCText(text), mapOf()))
    )
    if (items.isNullOrEmpty()) return PopopxEcoSendOutcome.failed(PopopxEcoSendFailure.SEND_REFUSED)
    for (item in items) ChatModel.chatsContext.addChatItem(rhId, item.chatInfo, item.chatItem)
    return PopopxEcoSendOutcome.Sent
  }

  override suspend fun eraseControlRow(chatType: ChatType, chatId: Long, itemId: Long) {
    val chat = ChatModel.chats.value.firstOrNull { it.chatInfo.apiId == chatId } ?: return
    val cInfo = chat.chatInfo
    val rhId = chat.remoteHostId
    val deletions = ChatModel.controller.apiDeleteChatItems(
      rhId,
      type = cInfo.chatType,
      id = cInfo.apiId,
      scope = cInfo.groupChatScope(),
      itemIds = listOf(itemId),
      // INTERNAL and nothing else: a broadcast deletion tells the peer a message was deleted, which writes
      // the control frame's existence back into their timeline.
      mode = CIDeleteMode.cidmInternal
    ) ?: return
    for (deletion in deletions) {
      val toChatItem = deletion.toChatItem
      if (toChatItem != null) {
        ChatModel.chatsContext.upsertChatItem(rhId, toChatItem.chatInfo, toChatItem.chatItem)
      } else {
        ChatModel.chatsContext.removeChatItem(rhId, deletion.deletedChatItem.chatInfo, deletion.deletedChatItem.chatItem)
      }
    }
  }

}
