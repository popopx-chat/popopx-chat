package chat.popopx.common.views.chatlist

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import chat.popopx.common.ui.components.PopopxCard
import chat.popopx.common.ui.theme.PopopxSpace
import chat.popopx.common.ui.theme.PopopxTypeScale
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
  PopopxCard {
    Text(title, style = PopopxTypeScale.headline, color = MaterialTheme.colors.onBackground)
    Spacer(Modifier.height(PopopxSpace.xxs))
    Text(detail, style = PopopxTypeScale.subheadline, color = MaterialTheme.colors.secondary)
  }
}