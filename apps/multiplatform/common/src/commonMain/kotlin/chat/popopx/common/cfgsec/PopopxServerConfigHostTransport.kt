package chat.popopx.common.cfgsec

import chat.popopx.common.model.CC
import chat.popopx.common.model.CIDeleteMode
import chat.popopx.common.model.Chat
import chat.popopx.common.model.ChatInfo
import chat.popopx.common.model.ChatModel
import chat.popopx.common.model.ChatSettings
import chat.popopx.common.model.ChatType
import chat.popopx.common.model.ComposedMessage
import chat.popopx.common.model.ConnectionPlan
import chat.popopx.common.model.ContactAddressPlan
import chat.popopx.common.model.CR
import chat.popopx.common.model.GroupLinkPlan
import chat.popopx.common.model.MsgContent
import chat.popopx.common.model.MsgFilter
import chat.popopx.common.model.SMPServerSummary
import chat.popopx.common.model.ServerAddress.Companion.parseServerAddress
import chat.popopx.common.model.PlanResolveMode
import chat.popopx.common.model.UserOperatorServers
import chat.popopx.common.platform.Log
import chat.popopx.common.platform.ntfManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// The FFI half of the signed cluster configuration, written against the same host calls the eco sender and the
// silent signalling router use, for the same reason: every step here has to be able to fail without speaking.
//
// The app-layer wrappers are unusable, and the reason is the requirement rather than taste:
// `setUserServers` raises a "failed to save servers" alert (PopopxAPI.kt:1453), and `resetAgentServersStats`,
// `apiDeleteChatItems` and `apiSendMessages` route through `apiErrorAlert` on failure; the whole `apiConnect*`
// family either shows a retry dialog (`sendCmdWithRetry`, PopopxAPI.kt:928-937) or an error alert
// (`apiPrepareContact` :1850, `apiPrepareGroup` :1859) — those two are alert-free on iOS and are not here, so
// iOS's call list cannot be copied verbatim. `sendCmd` is the one transport that returns instead of talking, so
// every write below goes through it with `log = false`, which also keeps machine traffic out of the terminal.
//
// Reads that are already silent (`getUserServers`, `validateServers`, `getAgentServersSummary`,
// `testProtoServer`, `apiSetSettings`) are called as they are; rewriting them would duplicate a wire request
// for no gain. Every model mutation hops to `Dispatchers.Main`, which is the discipline the chat-list flows
// keep for the same state.

object PopopxServerConfigHostTransport : PopopxServerConfigTransport {
  private const val TAG = "popopx-server-config"

  override suspend fun signedInUserId(): Long? = ChatModel.currentUser.value?.userId

  override suspend fun serverTable(): List<UserOperatorServers>? = runCatching {
    ChatModel.controller.getUserServers(ChatModel.remoteHostId())
  }.getOrNull()

  override suspend fun replaceTable(servers: List<UserOperatorServers>): Boolean {
    val userId = ChatModel.currentUser.value?.userId ?: return false
    return runCatching {
      val response = ChatModel.controller.sendCmd(
        ChatModel.remoteHostId(),
        CC.ApiSetUserServers(userId, servers),
        log = false,
      )
      if (!response.ok) Log.d(TAG, "set user servers refused: ${response.responseType}")
      response.ok
    }.getOrDefault(false)
  }

  /** Errors only, and -1 when the core could not be asked: an unanswered question is not a refusal. */
  override suspend fun validationErrorCount(servers: List<UserOperatorServers>): Int = runCatching {
    ChatModel.controller.validateServers(ChatModel.remoteHostId(), servers)?.first?.size ?: -1
  }.getOrDefault(-1)

  override suspend fun resetSessionStats(): Boolean = runCatching {
    ChatModel.controller.sendCmd(ChatModel.remoteHostId(), CC.ResetAgentServersStats(), log = false).ok
  }.getOrDefault(false)

  override suspend fun serverRows(): List<SMPServerSummary> = runCatching {
    val summary = ChatModel.controller.getAgentServersSummary(ChatModel.remoteHostId()) ?: return emptyList()
    val smp = summary.currentUserSMP
    smp.currentlyUsedSMPServers + smp.previouslyUsedSMPServers + smp.onlyProxiedSMPServers
  }.getOrDefault(emptyList())

  /** `testProtoServer` answers null for success and throws when the test never ran, so the two stay distinct. */
  override suspend fun directTest(uri: String): Boolean? = runCatching {
    ChatModel.controller.testProtoServer(ChatModel.remoteHostId(), uri) == null
  }.getOrNull()

  override fun acceptsServerUri(uri: String): Boolean = parseServerAddress(uri) != null

  override suspend fun sendText(chatType: ChatType, chatApiId: Long, text: String): Boolean {
    val chat = chatFor(chatType, chatApiId) ?: return false
    val cInfo = chat.chatInfo
    return runCatching {
      val response = ChatModel.controller.sendCmd(
        chat.remoteHostId,
        CC.ApiSendMessages(
          type = cInfo.chatType,
          id = cInfo.apiId,
          scope = cInfo.groupChatScope(),
          sendAsGroup = cInfo.sendAsGroup,
          // The receipt is not a live message and must not be signed or expire: it names a generation, and a
          // ttl would let it arrive after the operator has moved past it.
          live = false,
          ttl = null,
          sign = false,
          composedMessages = listOf(
            ComposedMessage(
              fileSource = null,
              quotedItemId = null,
              msgContent = MsgContent.MCText(text),
              mentions = emptyMap(),
            )
          ),
        ),
        log = false,
      )
      val items = (response.result as? CR.NewChatItems)?.chatItems ?: return@runCatching false
      if (items.isEmpty()) return@runCatching false
      // A row that exists on the server and in the database but not in the open conversation is the bug the
      // router's own send documents, so the sent items go into the model here.
      withContext(Dispatchers.Main) {
        for (item in items) ChatModel.chatsContext.addChatItem(chat.remoteHostId, item.chatInfo, item.chatItem)
      }
      true
    }.getOrDefault(false)
  }

  /**
   * Removes this device's row for a handled frame.
   *
   * `cidmInternal`, for the reason the signalling router records for the same choice: a broadcast deletion
   * would tell the sender that a configuration frame arrived, which is a fact this feature does not disclose.
   * Suppression only stops a row from rendering, so the model is updated as well.
   */
  override suspend fun deleteRow(chatType: ChatType, chatApiId: Long, itemId: Long): Boolean {
    val chat = chatFor(chatType, chatApiId) ?: return false
    val cInfo = chat.chatInfo
    return runCatching {
      val response = ChatModel.controller.sendCmd(
        chat.remoteHostId,
        CC.ApiDeleteChatItem(
          type = cInfo.chatType,
          id = cInfo.apiId,
          scope = cInfo.groupChatScope(),
          itemIds = listOf(itemId),
          mode = CIDeleteMode.cidmInternal,
        ),
        log = false,
      )
      val deletions = (response.result as? CR.ChatItemsDeleted)?.chatItemDeletions ?: return@runCatching false
      withContext(Dispatchers.Main) {
        for (deletion in deletions) {
          val toChatItem = deletion.toChatItem
          if (toChatItem != null) {
            ChatModel.chatsContext.upsertChatItem(chat.remoteHostId, toChatItem.chatInfo, toChatItem.chatItem)
          } else {
            ChatModel.chatsContext.removeChatItem(chat.remoteHostId, deletion.deletedChatItem.chatInfo, deletion.deletedChatItem.chatItem)
          }
          ChatModel.chatsContext.updateChatInfo(chat.remoteHostId, deletion.deletedChatItem.chatInfo)
        }
      }
      true
    }.getOrDefault(false)
  }

  /**
   * Stops a conversation this device joined by itself from making noise.
   *
   * `apiSetSettings` is already alert-free, so it is called as it is. The core does not update the model and an
   * already-scheduled notification survives the setting, so both are done here exactly as the chat-list toggle
   * does them (`ChatListNavLinkView.kt:963-993`), including rebuilding the chat info per subtype because
   * `ChatInfo` has no `copy` that carries a settings change.
   */
  override suspend fun silenceChat(chatType: ChatType, chatApiId: Long): Boolean {
    val chat = chatFor(chatType, chatApiId) ?: return false
    val cInfo = chat.chatInfo
    val updated = when (cInfo) {
      is ChatInfo.Direct ->
        ChatInfo.Direct(cInfo.contact.copy(chatSettings = (cInfo.chatSettings ?: ChatSettings.defaults).copy(enableNtfs = MsgFilter.None)))
      is ChatInfo.Group ->
        ChatInfo.Group(cInfo.groupInfo.copy(chatSettings = (cInfo.chatSettings ?: ChatSettings.defaults).copy(enableNtfs = MsgFilter.None)), groupChatScope = null)
      else -> null
    } ?: return false
    val applied = runCatching {
      ChatModel.controller.apiSetSettings(chat.remoteHostId, cInfo.chatType, cInfo.apiId, updated.chatSettings ?: ChatSettings.defaults)
    }.getOrDefault(false)
    if (!applied) return false
    withContext(Dispatchers.Main) { ChatModel.chatsContext.updateChatInfo(chat.remoteHostId, updated) }
    // The manager is a `lateinit` global that a headless test never initialises; a notification that was
    // already scheduled is a nuisance, not a safety property, so its absence must not fail the silence.
    runCatching { ntfManager.cancelNotificationsForChat(cInfo.id) }
    return true
  }

  /**
   * Plans one official address and joins it, with no dialog, no sheet, and no change to the open chat.
   *
   * A plan that answers anything other than "join this" is left alone. The cases that report an existing
   * connection return quietly; the cases with no silent recipe — link data the server did not give, a group
   * whose relay list needs a decision — are logged and skipped rather than guessed at, because a half-made
   * conversation in the chat list is worse than a missing one.
   *
   * `incognito` is false on both prepared connects, verbatim from
   * `PopopxServerConfigSignalHandler.swift:856` and `:874`: the configuration chats belong to the profile the
   * user is already in, and an incognito identity would put the receipts somewhere the operator never looks.
   */
  override suspend fun joinOfficial(uri: String): PopopxOfficialJoin? {
    val userId = ChatModel.currentUser.value?.userId ?: return null
    val rhId = ChatModel.remoteHostId()
    val controller = ChatModel.controller
    return runCatching {
      val planned = controller.sendCmd(rhId, CC.APIConnectPlan(userId, uri, PlanResolveMode.PRMUnknown, null), log = false)
        .result as? CR.CRConnectionPlan
        ?: return@runCatching null
      val connLink = planned.connLink
      when (val plan = planned.connectionPlan) {
        is ConnectionPlan.ContactAddress -> {
          val ok = plan.contactAddressPlan as? ContactAddressPlan.Ok
            ?: return@runCatching null.also { Log.d(TAG, "the official service account is already connected or needs a decision") }
          val data = ok.contactSLinkData_ ?: return@runCatching null
          val prepared = controller.sendCmd(rhId, CC.APIPrepareContact(userId, connLink, data), log = false)
            .result as? CR.NewPreparedChat ?: return@runCatching null
          val started = controller.sendCmd(rhId, CC.APIConnectPreparedContact(prepared.chat.chatInfo.apiId, false, null), log = false)
            .result is CR.StartedConnectionToContact
          if (!started) null else PopopxOfficialJoin(ChatType.Direct, prepared.chat.chatInfo.apiId)
        }
        is ConnectionPlan.GroupLink -> {
          val ok = plan.groupLinkPlan as? GroupLinkPlan.Ok
            ?: return@runCatching null.also { Log.d(TAG, "the official channel is already joined or needs a relay decision") }
          val data = ok.groupSLinkData_ ?: return@runCatching null
          val prepared = controller.sendCmd(rhId, CC.APIPrepareGroup(userId, connLink, ok.groupSLinkInfo_?.direct ?: true, data), log = false)
            .result as? CR.NewPreparedChat ?: return@runCatching null
          val started = controller.sendCmd(rhId, CC.APIConnectPreparedGroup(prepared.chat.chatInfo.apiId, false, null), log = false)
            .result is CR.StartedConnectionToGroup
          if (!started) null else PopopxOfficialJoin(ChatType.Group, prepared.chat.chatInfo.apiId)
        }
        else -> {
          Log.d(TAG, "an official address did not plan as a channel or a service account")
          null
        }
      }
    }.getOrNull()
  }

  /** Resolved by the type *and* the api id, because the two id spaces overlap by design. */
  private fun chatFor(chatType: ChatType, chatApiId: Long): Chat? =
    ChatModel.chats.value.firstOrNull { it.chatInfo.apiId == chatApiId && it.chatInfo.chatType == chatType }
}
