package chat.popopx.common.views.chatlist

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import chat.popopx.common.platform.onRightClick
import chat.popopx.common.ui.theme.PopopxHairlineInner
import chat.popopx.common.views.helpers.*

// The row is a card, as on iOS (`PopopxChatRow` in ChatsListView.swift: card radius 16, 0.5 hairline,
// padding 12, gutter/space2XS insets): a rounded surface on the page instead of a full-bleed row with a
// divider under it. Long-press opens the existing dropdown menu; swipe actions have no Android port yet.
@Composable
actual fun ChatListNavLinkLayout(
  chatLinkPreview: @Composable () -> Unit,
  click: () -> Unit,
  dropdownMenuItems: (@Composable () -> Unit)?,
  showMenu: MutableState<Boolean>,
  disabled: Boolean,
  selectedChat: State<Boolean>,
  nextChatSelected: State<Boolean>,
) {
  val shape = RoundedCornerShape(16.dp)
  var modifier = Modifier
    .fillMaxWidth()
    .padding(horizontal = 16.dp, vertical = 4.dp)

  if (!disabled) modifier = modifier
    .clip(shape)
    .combinedClickable(onClick = click, onLongClick = { showMenu.value = true })
    .onRightClick { showMenu.value = true }
  Box(modifier) {
    Row(
      modifier = Modifier
        .fillMaxWidth()
        .background(MaterialTheme.colors.surface, shape)
        .border(0.5.dp, PopopxHairlineInner, shape)
        .padding(12.dp),
      verticalAlignment = Alignment.Top
    ) {
      chatLinkPreview()
    }
    if (dropdownMenuItems != null) {
      DefaultDropdownMenu(showMenu, dropdownMenuItems = dropdownMenuItems)
    }
  }
}