package chat.popopx.common.views.chatlist

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.ui.theme.PopopxHairlineInner
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.stringResource

// `PopopxChatsEmptyState` (apps/ios/Shared/Features/Chats/ChatsListView.swift:1795-1854): a leading-aligned
// card — 17pt section header over a 13pt meta line, padding 16, radius 16, hairline stroke — whose copy
// answers "why is it empty". Only the two tiers the Android list can actually be in this round are drawn:
// no chats at all, and no search results. The filter/"list scoped" tiers stay with the existing Android
// view (`NoChatsView`), which already words each filter separately.
@Composable
internal fun PopopxChatsEmptyState(searching: Boolean, query: String) {
  val title = if (searching) stringResource(MR.strings.chats_empty_search_title) else stringResource(MR.strings.chats_empty_none_title)
  val detail = if (searching) stringResource(MR.strings.chats_empty_search_detail, query) else stringResource(MR.strings.chats_empty_none_detail)
  Column(
    Modifier
      .fillMaxWidth()
      .clip(RoundedCornerShape(16.dp))
      .background(MaterialTheme.colors.surface)
      .border(0.5.dp, PopopxHairlineInner, RoundedCornerShape(16.dp))
      .padding(16.dp),
    verticalArrangement = Arrangement.spacedBy(4.dp)
  ) {
    Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colors.onBackground)
    Text(detail, fontSize = 13.sp, color = MaterialTheme.colors.secondary, lineHeight = 18.sp)
  }
}