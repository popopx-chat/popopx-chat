package chat.popopx.common.views.eco

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.eco.PopopxEcoAction
import chat.popopx.common.eco.PopopxEcoLimits
import chat.popopx.common.eco.PopopxEcoMenu
import chat.popopx.common.eco.PopopxEcoRuntime
import chat.popopx.common.eco.PopopxEcoSendOutcome
import chat.popopx.common.eco.PopopxEcoStore
import chat.popopx.common.eco.PopopxEcoUplink
import chat.popopx.common.eco.PopopxChannelPublicURI
import chat.popopx.common.eco.PopopxH5Launcher
import chat.popopx.common.eco.PopopxH5OpenOutcome
import chat.popopx.common.ui.theme.PopopxSeparator
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.ImageResource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

// The service account's two-level bottom menu, ported from
// apps/ios/Shared/Features/ServiceAccount/BotMenuBarView.swift. At most three top-level keys
// (`PopopxEcoLimits.MAXIMUM_MENU_ITEMS`); tapping one that carries children springs a second level of at most
// five rows (`MAXIMUM_SUB_ITEMS`) above the row; one key hands the bar back to the keyboard.
//
// Four of iOS's seven recorded deviations land differently here, and the difference is the host's, not the
// menu's:
//
// - iOS's `renderedMenu` reads `menus[contactId] ?? menu` because its host parsed the frame and passed a
//   snapshot in. Android's host knows only the contact id, so the store is the single source and there is no
//   fallback parameter. The same reason iOS gives for not calling `loadIfNeeded()` from the body applies
//   here, and harder: `liveMenu(for:)` loads and writes, which is a state write during composition, so this
//   bar reads `PopopxEcoStore.peekMenu` (the pure read added for exactly this call site).
// - The popup is drawn in the same `Column`, above the row, rather than through a `.overlay` +
//   `alignmentGuide`. Same place on screen, and it cannot be clipped by a host whose top edge is cut.
// - There is no `PopopxToastModel`: iOS's capsule becomes one line of copy under the row, which the bar owns
//   and the host does not have to mount.
// - iOS's `isSingleLine` is weaker than the wire. The gate here is `PopopxEcoUplink.isSendablePayload`, the
//   predicate `wireString` itself uses, so a key that looks tappable always can be sent; on iOS a
//   space-bearing payload was tappable and then reported a failure. The refusal is the same, one step earlier.
//
// `scancode`, `location` and `click_text` show "unavailable" rather than doing anything. iOS documents the
// same choice (BotMenuBarView.swift:15-21): the composer's location picker and draft binding are private to
// its host, and the SMP scanner is a crypto-verification flow, not a general QR reader. Faking them here
// would be a button that lies.

/** The two-level menu of one service account, or the plain row when its menu is not renderable. */
@Composable
fun PopopxEcoMenuBar(contactId: Long, onHideKeyboard: () -> Unit) {
  val store = PopopxEcoStore.shared
  val scope = rememberCoroutineScope()
  val menu = renderableEcoMenu(store.peekMenu(contactId))
  var openParentId by remember(contactId) { mutableStateOf<String?>(null) }
  var inflight by remember(contactId) { mutableStateOf(emptySet<String>()) }
  var receipt by remember(contactId) { mutableStateOf<String?>(null) }

  // iOS closes the popup whenever the menu changes (`onChange(of: live)`), because a row of the old revision
  // can point at an action the new one no longer offers.
  LaunchedEffect(menu) { openParentId = null }

  // One closure owns the in-flight set and the receipt line, so no path can fire without locking its own key.
  val fireItem: (PopopxEcoMenu.Item) -> Unit = { item ->
    val key = item.id
    inflight = inflight + key
    performEcoMenuItem(item, contactId, scope) { text ->
      inflight = inflight - key
      receipt = text.ifBlank { null }
    }
  }

  Column(Modifier.fillMaxWidth()) {
    // iOS draws a full-width separator above the row (BotMenuBarView.swift:108-110): the bar is a second
    // level of chrome, and the line is what tells the eye the input area starts below it.
    Box(Modifier.fillMaxWidth().height(1.dp).background(PopopxSeparator))
    Spacer(Modifier.height(4.dp))
    if (menu == null) {
      PopopxEcoMenuPlainRow(onHideKeyboard = onHideKeyboard)
    } else {
      val rows = ecoMenuPopupRows(menu, openParentId)
      if (rows.isNotEmpty()) {
        PopopxEcoMenuPopup(rows = rows, onSelect = { item ->
          openParentId = null
          fireItem(item)
        })
        Spacer(Modifier.height(4.dp))
      }
      Row(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
      ) {
        menu.items.forEach { item ->
          val hasSub = item.subItems.isNotEmpty()
          val isOpen = openParentId == item.id
          val busy = item.id in inflight
          PopopxEcoMenuKey(
            item = item,
            isOpen = isOpen,
            enabled = (!busy && ecoMenuItemFiring(item) != null) || hasSub,
            modifier = Modifier.weight(1f),
            onTap = {
              if (hasSub) {
                openParentId = if (isOpen) null else item.id
              } else if (!busy) {
                fireItem(item)
              }
            }
          )
        }
        PopopxEcoMenuCollapseKey(onHideKeyboard = onHideKeyboard)
      }
    }
    val shown = receipt
    if (shown != null) {
      Text(
        shown,
        Modifier.fillMaxWidth().padding(bottom = 4.dp),
        fontSize = 13.sp,
        color = MaterialTheme.colors.secondary,
        textAlign = TextAlign.Center
      )
    }
    Spacer(Modifier.height(2.dp))
  }
}

/**
 * The menu this bar draws; null means the plain row. Two checks, both iOS's
 * (BotMenuBarView.swift:134-140): the whole menu must pass `isSane`, and a third level of nesting makes the
 * menu unrenderable rather than half-renderable, because the bar owns exactly two levels.
 *
 * Also the gate the mount site consults, so a chat with a human contact never grows a service row.
 */
internal fun renderableEcoMenu(menu: PopopxEcoMenu?): PopopxEcoMenu? {
  if (menu == null || !menu.isSane) return null
  val thirdLevel = menu.items.any { top -> top.subItems.any { it.subItems.isNotEmpty() } }
  return if (thirdLevel) null else menu
}

/**
 * The rows of the popup for the open parent. A parent carrying both its own action and fewer than
 * `MAXIMUM_SUB_ITEMS` children gets its own action folded in as the first row — iOS's answer to WeChat's
 * "a parent with children is view-only" rule (BotMenuBarView.swift:143-152): the action is reachable instead
 * of silently dropped, but never at the cost of a sixth row.
 */
private fun ecoMenuPopupRows(menu: PopopxEcoMenu, openParentId: String?): List<PopopxEcoMenu.Item> {
  if (openParentId == null) return emptyList()
  val parent = menu.items.firstOrNull { it.id == openParentId } ?: return emptyList()
  val rows = parent.subItems
  if (rows.isEmpty() || parent.action == null || parent.payload == null) return rows
  return if (rows.size < PopopxEcoLimits.MAXIMUM_SUB_ITEMS) listOf(parent) + rows else rows
}

@Composable
private fun PopopxEcoMenuKey(item: PopopxEcoMenu.Item, isOpen: Boolean, enabled: Boolean, onTap: () -> Unit, modifier: Modifier = Modifier) {
  // The key is a card-coloured pill 12dp round and 44dp tall, matching iOS's `menuKey`
  // (BotMenuBarView.swift:180-223): card fill + hairline when closed, brand fill with no stroke when open.
  val shape = RoundedCornerShape(12.dp)
  Row(
    modifier
      .heightIn(min = 44.dp)
      .clip(shape)
      .background(if (isOpen) MaterialTheme.colors.primary else MaterialTheme.colors.surface)
      .border(0.5.dp, if (isOpen) Color.Transparent else PopopxSeparator, shape)
      .then(if (enabled) Modifier.clickable(onClick = onTap) else Modifier)
      .alpha(if (enabled) 1f else 0.45f)
      .padding(horizontal = 12.dp, vertical = 8.dp),
    horizontalArrangement = Arrangement.Center,
    verticalAlignment = Alignment.CenterVertically
  ) {
    Text(
      item.title,
      fontSize = 15.sp,
      color = if (isOpen) MaterialTheme.colors.onPrimary else MaterialTheme.colors.onSurface,
      maxLines = 2,
      textAlign = TextAlign.Center
    )
    if (item.subItems.isNotEmpty()) {
      Spacer(Modifier.width(4.dp))
      Icon(
        painterResource(if (isOpen) MR.images.ic_chevron_down else MR.images.ic_chevron_up),
        null,
        Modifier.size(12.dp),
        tint = MaterialTheme.colors.secondary
      )
    }
  }
}

@Composable
private fun PopopxEcoMenuPopup(rows: List<PopopxEcoMenu.Item>, onSelect: (PopopxEcoMenu.Item) -> Unit) {
  val shape = RoundedCornerShape(16.dp)
  Column(
    Modifier.fillMaxWidth().clip(shape).background(MaterialTheme.colors.surface)
      .border(0.5.dp, PopopxSeparator, shape)
      .padding(vertical = 4.dp)
  ) {
    rows.forEachIndexed { index, item ->
      if (index > 0) Spacer(Modifier.height(0.5.dp).fillMaxWidth().background(PopopxSeparator))
      Row(
        Modifier.fillMaxWidth().clickable { onSelect(item) }
          .heightIn(min = 44.dp).padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
      ) {
        Text(item.title, fontSize = 15.sp, color = MaterialTheme.colors.onSurface, maxLines = 2, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(12.dp))
        Icon(painterResource(ecoMenuGlyph(item)), null, Modifier.size(14.dp), tint = MaterialTheme.colors.secondary)
      }
    }
  }
}

@Composable
private fun PopopxEcoMenuPlainRow(onHideKeyboard: () -> Unit) {
  Row(
    Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(horizontal = 12.dp, vertical = 4.dp),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Text(generalGetString(MR.strings.eco_menu_label), fontSize = 15.sp, color = MaterialTheme.colors.secondary)
    Spacer(Modifier.weight(1f))
    PopopxEcoMenuCollapseKey(onHideKeyboard = onHideKeyboard)
  }
}

@Composable
private fun PopopxEcoMenuCollapseKey(onHideKeyboard: () -> Unit) {
  val shape = RoundedCornerShape(12.dp)
  Icon(
    painterResource(MR.images.ic_keyboard),
    generalGetString(MR.strings.eco_menu_collapse),
    Modifier.size(44.dp).clip(shape).background(MaterialTheme.colors.surface)
      .border(0.5.dp, PopopxSeparator, shape)
      .clickable { onHideKeyboard() }
      .padding(11.dp),
    tint = MaterialTheme.colors.secondary
  )
}

private fun ecoMenuGlyph(item: PopopxEcoMenu.Item): ImageResource = when (item.kind) {
  PopopxEcoMenu.Item.Kind.SCANCODE -> MR.images.ic_qr_code_scanner
  PopopxEcoMenu.Item.Kind.LOCATION -> MR.images.ic_maps_ugc
  PopopxEcoMenu.Item.Kind.CLICK_TEXT -> MR.images.ic_edit_note
  PopopxEcoMenu.Item.Kind.VIEW -> MR.images.ic_open_in_new
  PopopxEcoMenu.Item.Kind.CLICK -> when (item.action) {
    PopopxEcoAction.Kind.SEND_COMMAND -> MR.images.ic_outbound
    PopopxEcoAction.Kind.CALLBACK -> MR.images.ic_arrow_upward
    PopopxEcoAction.Kind.OPEN_URL -> MR.images.ic_open_in_new
    PopopxEcoAction.Kind.OPEN_CHANNEL -> MR.images.ic_link
    else -> MR.images.ic_circle
  }
}

/** What a key would do, if anything. iOS's `Firing` (BotMenuBarView.swift:318-354), where null is its `.unreachable`. */
private enum class EcoMenuFiring {
  SEND,
  CALLBACK,
  URL,
  CHANNEL,
}

private class EcoMenuFire(val firing: EcoMenuFiring, val text: String)

/**
 * The decision, kept out of the composable so it can be read and tested as one block. The re-validation here
 * is deliberate: `PopopxEcoMenu.Item.isSane` checks presence, not reachability (it does not call
 * `isHttpUrl` or `PopopxChannelPublicURI.parse`), so a `javascript:` URL or a malformed channel URI is
 * unreachable here rather than forwarded to a host that would have to catch it — iOS's deviation 7.
 */
private fun ecoMenuItemFiring(item: PopopxEcoMenu.Item): EcoMenuFire? {
  val unreachable = item.kind == PopopxEcoMenu.Item.Kind.SCANCODE ||
    item.kind == PopopxEcoMenu.Item.Kind.LOCATION ||
    item.kind == PopopxEcoMenu.Item.Kind.CLICK_TEXT
  if (unreachable) return null
  if (item.kind == PopopxEcoMenu.Item.Kind.VIEW) {
    val url = item.url ?: return null
    return if (PopopxEcoAction.isHttpUrl(url)) EcoMenuFire(EcoMenuFiring.URL, url) else null
  }
  return when (item.action) {
    PopopxEcoAction.Kind.SEND_COMMAND -> {
      val payload = item.payload ?: return null
      if (PopopxEcoUplink.isSendablePayload(payload)) EcoMenuFire(EcoMenuFiring.SEND, payload) else null
    }

    PopopxEcoAction.Kind.CALLBACK -> {
      val payload = item.payload ?: return null
      if (PopopxEcoUplink.isSendablePayload(payload)) EcoMenuFire(EcoMenuFiring.CALLBACK, payload) else null
    }

    PopopxEcoAction.Kind.OPEN_URL -> {
      val url = item.url ?: return null
      if (PopopxEcoAction.isHttpUrl(url)) EcoMenuFire(EcoMenuFiring.URL, url) else null
    }

    PopopxEcoAction.Kind.OPEN_CHANNEL -> {
      val payload = item.payload ?: return null
      if (PopopxChannelPublicURI.parse(payload) != null) EcoMenuFire(EcoMenuFiring.CHANNEL, payload) else null
    }

    else -> null
  }
}

/**
 * One key press. `send_cmd`/`callback` go to the router, which is the dual-mode uplink (the card runner is
 * card-scoped and returns IGNORED for a command action — iOS's deviation 2); `view`/`click`+`open_url` go to
 * the H5 launcher, which owns the session check and the signature; `open_channel` goes to the router, which
 * raises the key page request the host drains.
 */
private fun performEcoMenuItem(item: PopopxEcoMenu.Item, contactId: Long, scope: CoroutineScope, onReceipt: (String) -> Unit) {
  val fire = ecoMenuItemFiring(item)
  if (fire == null) {
    onReceipt(generalGetString(MR.strings.eco_menu_unavailable))
    return
  }
  val router = PopopxEcoRuntime.router
  when (fire.firing) {
    EcoMenuFiring.SEND, EcoMenuFiring.CALLBACK -> {
      val callback = fire.firing == EcoMenuFiring.CALLBACK
      scope.launch {
        val outcome = if (callback) router.sendCallback(fire.text, contactId) else router.send(fire.text, contactId)
        onReceipt(ecoMenuSendReceipt(outcome))
      }
    }

    EcoMenuFiring.URL -> onReceipt(ecoMenuH5Receipt(PopopxH5Launcher.shared.open(fire.text, contactId)))
    EcoMenuFiring.CHANNEL -> onReceipt(if (router.openChannel(fire.text)) generalGetString(MR.strings.ok) else generalGetString(MR.strings.eco_h5_invalid))
  }
}

private fun ecoMenuSendReceipt(outcome: PopopxEcoSendOutcome): String = when (outcome) {
  PopopxEcoSendOutcome.Sent -> generalGetString(MR.strings.eco_card_sent)
  is PopopxEcoSendOutcome.Failed -> generalGetString(MR.strings.eco_card_failed)
}

/**
 * The launcher's own refusal, in the launcher's words. `SIGNED` says nothing because the sheet is on screen,
 * and a receipt under the bar would be the app describing a page the user is already looking at; iOS keeps
 * the same silence and hands `alreadyPresenting` no copy at all.
 */
private fun ecoMenuH5Receipt(outcome: PopopxH5OpenOutcome): String = when (outcome) {
  PopopxH5OpenOutcome.SIGNED, PopopxH5OpenOutcome.ALREADY_PRESENTING -> ""
  PopopxH5OpenOutcome.NO_SESSION -> generalGetString(MR.strings.eco_h5_needs_contact)
  PopopxH5OpenOutcome.SESSION_UNUSABLE, PopopxH5OpenOutcome.INVALID_URL -> generalGetString(MR.strings.eco_h5_invalid)
}
