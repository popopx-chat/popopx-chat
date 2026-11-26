package chat.popopx.common.views.tabs

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Surface
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.AppLock
import chat.popopx.common.StartPartOfScreen
import chat.popopx.common.cfgsec.PopopxOfficialConfigLinks
import chat.popopx.common.cfgsec.PopopxServerConfigSignalHandler
import chat.popopx.common.cfgsec.popopxServerConfigHiddenChat
import chat.popopx.common.eco.PopopxEcoSessionStore
import chat.popopx.common.model.*
import chat.popopx.common.platform.*
import chat.popopx.common.ui.theme.DEFAULT_PADDING
import chat.popopx.common.views.cabin.PopopxCabinView
import chat.popopx.common.views.chatlist.unreadCountStr
import chat.popopx.common.views.contacts.ContactListNavLinkView
import chat.popopx.common.views.helpers.AnimatedViewState
import chat.popopx.common.views.helpers.LocalAppBarHandler
import chat.popopx.common.views.helpers.rememberAppBarHandler
import chat.popopx.common.views.helpers.withBGApi
import chat.popopx.common.views.usersettings.SettingsView
import chat.popopx.res.*
import dev.icerock.moko.resources.ImageResource
import dev.icerock.moko.resources.StringResource
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged

// The four-tab shell, ported from apps/ios/Shared/Navigation/MainTabView.swift. It is mounted by
// AndroidScreen (App.kt:332) and nowhere else, and `AndroidScreen` itself is reached only under
// `appPlatform.isAndroid` (App.kt:166), so the desktop tree — and with it the 376 snapshot
// baselines — is untouched by construction rather than by a second gate here.
//
// iOS has five tabs and this bar now carries all five in the iOS order: Chats / Contacts / Cabin /
// Discover / Me. Cabin is the offline Bluetooth mesh plaza and is shown on Android only —
// `PopopxTab.entries` is filtered by `appPlatform.isAndroid` where the bar is built — so a desktop
// composition sees the same four tabs, in the same positions, as before this tab existed. No "service
// accounts" tab is invented: on iOS the eco service accounts are a page inside the Contacts feature, not
// a tab, and their conversations stay in the chat list.
//
// The three structural decisions of the source file port as follows:
// 1. the conversation stays presented by the Chats page's own tree — here that is the existing
//    `ChatView` slide-over of `AndroidScreen`, which covers this whole column, so nothing is
//    re-parented and `chatModel.chatId` keeps exactly one reader;
// 2. the unread badge reuses the definition the app already maintains (`UserInfo.unreadCount`, the
//    same value the profile picker badges) rather than computing a second one;
// 3. opening a conversation from another tab switches the tab back to Chats, because a chat opened
//    while the Contacts tab is showing must be found again when the slide-over is dismissed.

enum class PopopxTab(val title: StringResource, val icon: ImageResource) {
  CHATS(MR.strings.main_tab_messages, MR.images.ic_chat_bubble),
  CONTACTS(MR.strings.main_tab_contacts, MR.images.ic_group),
  CABIN(MR.strings.cabin_title, MR.images.ic_bluetooth),
  DISCOVER(MR.strings.main_tab_discover, MR.images.ic_travel_explore),
  ME(MR.strings.main_tab_me, MR.images.ic_account_circle_filled),
  ;

  companion object {
    fun fromOrdinal(ordinal: Int): PopopxTab = entries.getOrElse(ordinal) { CHATS }
  }
}

@Composable
fun PopopxTabScaffold(userPickerState: MutableStateFlow<AnimatedViewState>) {
  val selected = rememberSaveable { mutableStateOf(PopopxTab.CHATS.ordinal) }
  val tab = PopopxTab.fromOrdinal(selected.value)

  LaunchedEffect(Unit) {
    snapshotFlow { chatModel.chatId.value }
      .distinctUntilChanged()
      .collect { chatId -> if (chatId != null) selected.value = PopopxTab.CHATS.ordinal }
  }

  // The launch seam for the signed cluster configuration, at the same place iOS puts it
  // (MainTabView.swift:240-262): reaching the tab bar is what proves both halves of the precondition — a
  // profile exists, and the controller has started far enough to answer a request. Keying on the user id is
  // what covers iOS's two separate hooks at once: the first composition is its `onAppear`, and a second profile
  // made inside a running process never passes through `onAppear` but does change this key.
  //
  // `promoteStagedIfNeeded` settles an interrupted probe before it looks at the staged frame, so one call
  // covers both halves of the launch path, and it returns immediately when nothing is staged. The seeding delay
  // is not decoration: a subscription issued into the middle of launch is one whose failure has no dialog left
  // to explain it, and `seedOfficialSubscriptions` is silent by design.
  val userId = chatModel.currentUser.value?.userId
  LaunchedEffect(userId) {
    withBGApi { PopopxServerConfigSignalHandler.shared.promoteStagedIfNeeded() }
    delay(PopopxOfficialConfigLinks.SEEDING_DELAY_MILLIS)
    withBGApi { PopopxServerConfigSignalHandler.shared.seedOfficialSubscriptions() }
  }

  Column(Modifier.fillMaxSize()) {
    Box(Modifier.weight(1f)) {
      when (tab) {
        PopopxTab.CHATS -> StartPartOfScreen(userPickerState)
        PopopxTab.CONTACTS -> WithAppBar { PopopxContactsTabView() }
        PopopxTab.CABIN -> WithAppBar { PopopxCabinView() }
        PopopxTab.DISCOVER -> WithAppBar { PopopxDiscoverTabView() }
        PopopxTab.ME -> WithAppBar { SettingsView(chatModel, AppLock::setPerformLA, close = { }) }
      }
    }
    PopopxTabBar(tab) { selected.value = it.ordinal }
  }
}

// The pages other than Chats are hosted by the shell, so they need the app-bar collaborator that
// StartPartOfScreen provides for the chat list: `AppBarTitle` and `ColumnWithScrollBar` both read it.
@Composable
private fun WithAppBar(content: @Composable () -> Unit) {
  CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler()) {
    content()
  }
}

@Composable
private fun PopopxContactsTabView() {
  val chats = remember { derivedStateOf { chatModel.chats.value.filter(::popopxContactChat) } }
  if (chats.value.isEmpty()) {
    Column(
      Modifier.fillMaxSize().padding(horizontal = DEFAULT_PADDING),
      verticalArrangement = Arrangement.Center,
      horizontalAlignment = Alignment.CenterHorizontally
    ) {
      Text(stringResource(MR.strings.contacts_tab_empty), style = MaterialTheme.typography.h3, textAlign = TextAlign.Center)
      Spacer(Modifier.height(8.dp))
      Text(
        stringResource(MR.strings.contacts_tab_empty_note),
        style = MaterialTheme.typography.body2,
        color = MaterialTheme.colors.secondary,
        textAlign = TextAlign.Center
      )
    }
  } else {
    LazyColumn(Modifier.fillMaxSize()) {
      itemsIndexed(chats.value, key = { _, chat -> chat.remoteHostId to chat.id }) { index, chat ->
        val nextChatSelected = remember(chat.id, chats.value) {
          derivedStateOf {
            chatModel.chatId.value != null && chats.value.getOrNull(index + 1)?.id == chatModel.chatId.value
          }
        }
        ContactListNavLinkView(chat, nextChatSelected, showDeletedChatIcon = true)
      }
      item { Spacer(Modifier.height(DEFAULT_PADDING)) }
    }
  }
}

/**
 * `PopopxContactsView.contactChats` (PopopxContactsView.swift:397-417), field for field: not a deleted chat, not
 * a contact card, not one of the official configuration conversations, then an active direct contact that is not
 * itself a card and is not a service account, or a group that is neither a business chat nor a channel.
 */
private fun popopxContactChat(chat: Chat): Boolean {
  val info = chat.chatInfo
  if (info.chatDeleted || info.contactCard || popopxServerConfigHiddenChat(chat)) return false
  return when (info) {
    is ChatInfo.Direct -> info.contact.active
      && !info.contact.isContactCard
      && !PopopxEcoSessionStore.hasSession(info.contact.contactId)
    is ChatInfo.Group -> info.groupInfo.businessChat == null && !info.groupInfo.isChannel
    else -> false
  }
}

@Composable
private fun PopopxTabBar(selected: PopopxTab, onSelect: (PopopxTab) -> Unit) {
  val unread = chatModel.users.sumOf { it.unreadCount }
  Surface(
    modifier = Modifier.fillMaxWidth(),
    color = MaterialTheme.colors.surface,
    contentColor = MaterialTheme.colors.onSurface,
    elevation = 8.dp
  ) {
    Column {
      Row(Modifier.fillMaxWidth()) {
        // The tab the red line keeps off every other platform, filtered where the bar is built rather than
        // inside the page: an entry that renders nothing would still take a slot in the row.
        PopopxTab.entries.filter { it != PopopxTab.CABIN || appPlatform.isAndroid }.forEach { tab ->
          PopopxTabBarItem(tab, tab == selected, if (tab == PopopxTab.CHATS) unread else 0, onSelect)
        }
      }
      Spacer(Modifier.windowInsetsBottomHeight(WindowInsets.navigationBars))
    }
  }
}

@Composable
private fun RowScope.PopopxTabBarItem(tab: PopopxTab, isSelected: Boolean, unread: Int, onSelect: (PopopxTab) -> Unit) {
  val tint = if (isSelected) MaterialTheme.colors.primary else MaterialTheme.colors.secondary
  Column(
    Modifier
      .weight(1f)
      .clickable(onClickLabel = stringResource(tab.title)) { onSelect(tab) }
      .padding(top = 8.dp, bottom = 6.dp),
    horizontalAlignment = Alignment.CenterHorizontally
  ) {
    Box(contentAlignment = Alignment.TopEnd) {
      Icon(painterResource(tab.icon), null, Modifier.size(24.dp), tint = tint)
      if (unread > 0) {
        val offset = with(LocalDensity.current) { (4.sp).toDp() }
        Text(
          unreadCountStr(unread),
          color = Color.White,
          fontSize = 10.sp,
          maxLines = 1,
          modifier = Modifier
            .offset(x = offset, y = -offset)
            .background(MaterialTheme.colors.secondary, shape = CircleShape)
            .padding(horizontal = 4.dp, vertical = 1.dp)
        )
      }
    }
    Spacer(Modifier.height(3.dp))
    Text(
      stringResource(tab.title),
      fontSize = 10.sp,
      fontWeight = FontWeight.Medium,
      color = tint,
      maxLines = 1,
      overflow = TextOverflow.Ellipsis
    )
  }
}
