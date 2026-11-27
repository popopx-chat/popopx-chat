package chat.popopx.common.views.tabs

import SectionItemView
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.Icon
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Surface
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import chat.popopx.common.copilot.PopopxEcoAssistantHost
import chat.popopx.common.copilot.showPopopxEcoAssistantSheet
import chat.popopx.common.discover.PopopxDiscoverCatalog
import chat.popopx.common.discover.PopopxDiscoverCopy
import chat.popopx.common.discover.PopopxDiscoverFilter
import chat.popopx.common.discover.PopopxDiscoverSection
import chat.popopx.common.discover.PopopxMacNodeBinding
import chat.popopx.common.discover.PopopxNodeConsole
import chat.popopx.common.discover.PopopxNodeFeedItem
import chat.popopx.common.discover.PopopxNodeFeedSnapshot
import chat.popopx.common.discover.PopopxNodeServiceId
import chat.popopx.common.discover.PopopxPairingAccept
import chat.popopx.common.discover.PopopxSubscriptionEngine
import chat.popopx.common.model.ChatInfo
import chat.popopx.common.platform.appPlatform
import chat.popopx.common.platform.chatModel
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.signal.PopopxSilentSignalingRouter
import chat.popopx.common.ui.components.PopopxCard
import chat.popopx.common.ui.components.PopopxChip
import chat.popopx.common.ui.components.PopopxDivider
import chat.popopx.common.ui.theme.PopopxAlpha
import chat.popopx.common.ui.theme.PopopxBrand
import chat.popopx.common.ui.theme.PopopxElevation
import chat.popopx.common.ui.theme.PopopxFieldSurface
import chat.popopx.common.ui.theme.PopopxHairlineStrong
import chat.popopx.common.ui.theme.PopopxLabelHint
import chat.popopx.common.ui.theme.PopopxMeshInk
import chat.popopx.common.ui.theme.PopopxRadiusChip
import chat.popopx.common.ui.theme.PopopxRadiusControl
import chat.popopx.common.ui.theme.PopopxSize
import chat.popopx.common.ui.theme.PopopxSpace
import chat.popopx.common.ui.theme.PopopxSurface
import chat.popopx.common.ui.theme.PopopxTypeScale
import chat.popopx.common.ui.theme.isInDarkTheme
import chat.popopx.common.views.helpers.AppBarTitle
import chat.popopx.common.views.helpers.AutoMirroredIcon
import chat.popopx.common.views.helpers.DefaultBasicTextField
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.common.views.newchat.PopopxCardActionButton
import chat.popopx.common.views.newchat.QRCodeScanner
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.launch

// The Discover tab: the local edge-service shelf. Ported from
// apps/ios/Shared/Features/Discover/PopopxDiscoverView.swift and DiscoverServiceDetailSheet.swift,
// and it deliberately contains no new protocol logic — every name, price and command token on this
// screen comes out of PopopxDiscoverCatalog, so the plaza cannot say something the wire layer does
// not.
//
// What is NOT here yet, and is therefore visibly absent rather than faked:
// - the live per-service cycle state (running / expiring / waiting for credits). The catalogue is
//   static; that state belongs to PopopxSubscriptionEngine, whose wallet seam is commerce's lane.
// - the per-action send. iOS's detail sheet shows the three commands as readable text, not as
//   buttons (DiscoverServiceDetailSheet.swift:418-445: "Nothing is sent from this preview"), so
//   this sheet renders the same preview and offers no control that would do nothing.
//
// The Mac-node QR camera is no longer absent: bonding offers the same two actions iOS does — scan the
// node's QR code (the shared `QRCodeScanner`) or reveal the paste field. Both feed the one engine
// entry, `acceptPastedCode`, so a scanned string passes through exactly the same signature and
// freshness checks a pasted one does; the camera grants no shortcut into the pairing state.

@Composable
fun PopopxDiscoverTabView() {
  val filterIndex = rememberSaveable { mutableStateOf(PopopxDiscoverFilter.ALL.ordinal) }
  val filter = PopopxDiscoverFilter.entries.getOrElse(filterIndex.value) { PopopxDiscoverFilter.ALL }
  val searchText = rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue("")) }
  val shelves = PopopxDiscoverCatalog.visibleSections(filter, searchText.value.text)
  val binding = PopopxSubscriptionEngine.shared.binding
  val nodeFeed = PopopxSubscriptionEngine.shared.nodeFeed

  Column(Modifier.fillMaxSize()) {
    PopopxDiscoverSearchField(searchText)
    PopopxDiscoverFilterChips(filter) { index -> filterIndex.value = index }
    LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
      item { PopopxNodeFeedSection(nodeFeed) }
      items(shelves, key = { it.id }) { shelf ->
        PopopxDiscoverShelf(shelf.section, shelf.services)
      }
      item { PopopxDiscoverAssistantRow() }
      item { PopopxDiscoverNodeRow(binding) }
      item { Spacer(Modifier.height(PopopxSpace.m)) }
    }
  }
}

@Composable
private fun PopopxDiscoverSearchField(searchText: MutableState<TextFieldValue>) {
  Surface(
    modifier = Modifier
      .fillMaxWidth()
      .padding(horizontal = PopopxSpace.gutter, vertical = PopopxSpace.xs),
    shape = RoundedCornerShape(PopopxRadiusControl),
    color = PopopxFieldSurface,
    border = BorderStroke(PopopxSize.hairline, PopopxHairlineStrong),
  ) {
    DefaultBasicTextField(
      modifier = Modifier
        .fillMaxWidth()
        .padding(horizontal = PopopxSpace.s, vertical = PopopxSpace.xs),
      state = searchText,
      leadingIcon = {
        Icon(painterResource(MR.images.ic_search), null, Modifier.size(PopopxSize.iconM), tint = PopopxLabelHint)
      },
      placeholder = {
        Text(
          stringResource(MR.strings.discover_search_services),
          style = PopopxTypeScale.body,
          color = PopopxLabelHint
        )
      },
      keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
      onValueChange = { searchText.value = it },
    )
  }
}

@Composable
private fun PopopxDiscoverFilterChips(selected: PopopxDiscoverFilter, onSelect: (Int) -> Unit) {
  Row(
    Modifier
      .fillMaxWidth()
      .horizontalScroll(rememberScrollState())
      .padding(horizontal = PopopxSpace.gutter, vertical = PopopxSpace.xxs),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs)
  ) {
    PopopxDiscoverFilter.entries.forEach { filter ->
      PopopxChip(
        text = filter.title,
        selected = filter == selected,
        onClick = { onSelect(PopopxDiscoverFilter.entries.indexOf(filter)) }
      )
    }
  }
}

@Composable
private fun PopopxDiscoverShelf(section: PopopxDiscoverSection, services: List<PopopxNodeServiceId>) {
  Column(Modifier.fillMaxWidth().padding(horizontal = PopopxSpace.gutter)) {
    Text(
      section.title,
      style = PopopxTypeScale.headline,
      color = MaterialTheme.colors.onBackground,
      modifier = Modifier.padding(top = PopopxSpace.m, bottom = PopopxSpace.xs)
    )
    services.forEach { service ->
      PopopxDiscoverTile(service)
    }
  }
}

@Composable
private fun PopopxDiscoverTile(service: PopopxNodeServiceId) {
  Surface(
    modifier = Modifier
      .fillMaxWidth()
      .padding(vertical = PopopxSpace.xxs),
    shape = RoundedCornerShape(PopopxRadiusControl),
    color = PopopxSurface,
    border = BorderStroke(PopopxSize.hairline, PopopxHairlineStrong),
    elevation = if (isInDarkTheme()) 0.dp else PopopxElevation.card,
  ) {
    SectionItemView(
      { showServiceDetail(service) },
      padding = PaddingValues(horizontal = PopopxSpace.s, vertical = PopopxSpace.s)
    ) {
      // No glyph: iOS picks these tiles by an SF Symbol name, and the moko drawable set has no
      // equivalent for nine of the ten. A monogram of the plaza name is the honest placeholder until
      // the visual pass, rather than a mapping that would silently rename what a service is.
      Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
          .size(40.dp)
          .clip(RoundedCornerShape(PopopxRadiusChip))
          .background(PopopxBrand.copy(alpha = PopopxAlpha.wash))
      ) {
        Text(
          service.title.take(1),
          style = PopopxTypeScale.headline,
          color = PopopxBrand
        )
      }
      Spacer(Modifier.width(PopopxSpace.s))
      Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(service.title, style = PopopxTypeScale.headline, color = MaterialTheme.colors.onBackground, maxLines = 1)
        Text(
          service.tagline,
          style = PopopxTypeScale.callout,
          color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
          maxLines = 2
        )
        Text(
          service.cycleCost.priceLabel,
          style = PopopxTypeScale.caption,
          color = PopopxBrand,
          modifier = Modifier.padding(top = 2.dp)
        )
      }
    }
  }
}

private fun showServiceDetail(service: PopopxNodeServiceId) {
  ModalManager.start.showModalCloseable(cardScreen = true) { close ->
    PopopxDiscoverServiceSheet(service, close)
  }
}

@Composable
private fun PopopxDiscoverServiceSheet(service: PopopxNodeServiceId, close: () -> Unit) {
  val clipboard = LocalClipboardManager.current
  ColumnWithScrollBar {
    AppBarTitle(service.title)
    Column(Modifier.padding(horizontal = PopopxSpace.gutter)) {
      Text(service.tagline, style = PopopxTypeScale.callout, color = MaterialTheme.colors.onBackground)
      Spacer(Modifier.height(PopopxSpace.xs))
      Text(service.cycleCost.priceLabel, style = PopopxTypeScale.subheadline, color = PopopxBrand)

      SheetHeading(stringResource(MR.strings.discover_highlights))
      service.highlights.forEach { highlight ->
        Row(Modifier.padding(vertical = 2.dp)) {
          Text(
            "•",
            style = PopopxTypeScale.subheadline,
            color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary)
          )
          Spacer(Modifier.width(PopopxSpace.xs))
          Text(
            highlight,
            style = PopopxTypeScale.callout,
            color = MaterialTheme.colors.onBackground,
            modifier = Modifier.weight(1f)
          )
        }
      }

      SheetHeading(stringResource(MR.strings.discover_menu))
      service.menuActions.forEach { action ->
        Row(
          Modifier.fillMaxWidth().padding(vertical = 4.dp),
          verticalAlignment = Alignment.CenterVertically
        ) {
          Text(
            action.title,
            style = PopopxTypeScale.callout,
            color = MaterialTheme.colors.onBackground,
            modifier = Modifier.weight(1f)
          )
          Text(
            "${service.rawValue} · ${action.action}",
            style = PopopxTypeScale.codeSmall,
            color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
            maxLines = 1
          )
        }
      }
      Text(
        stringResource(MR.strings.discover_menu_hint),
        style = PopopxTypeScale.caption,
        color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
        modifier = Modifier.padding(top = PopopxSpace.xxs, bottom = PopopxSpace.m)
      )

      SheetHeading(stringResource(MR.strings.discover_bridge_title))
      Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(PopopxRadiusControl),
        color = PopopxSurface,
        border = BorderStroke(PopopxSize.hairline, PopopxHairlineStrong),
      ) {
        SectionItemView(
          { clipboard.setText(AnnotatedString(PopopxNodeConsole.copyText())) },
          padding = PaddingValues(horizontal = PopopxSpace.s, vertical = PopopxSpace.xs)
        ) {
          Column(Modifier.weight(1f)) {
            Text(
              stringResource(MR.strings.discover_bridge_address),
              style = PopopxTypeScale.caption,
              color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary)
            )
            Text(
              PopopxNodeConsole.consoleDisplayUrl(),
              style = PopopxTypeScale.code,
              color = MaterialTheme.colors.onBackground
            )
          }
          Text(stringResource(MR.strings.copy_verb), style = PopopxTypeScale.subheadline, color = PopopxBrand)
        }
      }
      Text(
        PopopxNodeConsole.tokenContractText(),
        style = PopopxTypeScale.codeSmall,
        color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary)
      )
      Text(
        PopopxNodeConsole.LOCAL_ONLY_NOTE,
        style = PopopxTypeScale.caption,
        color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
        modifier = Modifier.padding(top = PopopxSpace.xxs)
      )
      Spacer(Modifier.height(PopopxSpace.m))
      SheetDone(close)
    }
  }
}

@Composable
private fun SheetHeading(text: String) {
  Text(
    text,
    style = PopopxTypeScale.headline,
    color = MaterialTheme.colors.onBackground,
    modifier = Modifier.padding(top = PopopxSpace.m, bottom = PopopxSpace.xs)
  )
}

@Composable
private fun SheetDone(close: () -> Unit) {
  Text(
    stringResource(MR.strings.ok),
    style = PopopxTypeScale.callout,
    fontWeight = FontWeight.SemiBold,
    color = PopopxBrand,
    modifier = Modifier.clickable { close() }.padding(vertical = PopopxSpace.xs)
  )
}

@Composable
private fun PopopxDiscoverAssistantRow() {
  // 「发现 → 我的私人助理」. Shown only where a copilot glue was installed, so the entry never leads to
  // a sheet that cannot answer: on a platform without calendar access the assistant does not exist, and
  // an absent row is honest where a dead one would not be.
  if (!PopopxEcoAssistantHost.available) return
  PopopxCard(
    modifier = Modifier.padding(horizontal = PopopxSpace.gutter, vertical = PopopxSpace.xs),
    contentPadding = PaddingValues(0.dp),
  ) {
    Row(
      Modifier
        .fillMaxWidth()
        .clickable { showPopopxEcoAssistantSheet() }
        .padding(PopopxSpace.s),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(PopopxSpace.s)
    ) {
      Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
          .size(38.dp)
          .clip(RoundedCornerShape(PopopxRadiusControl))
          .background(PopopxBrand.copy(alpha = PopopxAlpha.wash))
      ) {
        Text(
          stringResource(MR.strings.discover_private_assistant).take(1),
          style = PopopxTypeScale.headline,
          color = PopopxBrand
        )
      }
      Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
          stringResource(MR.strings.discover_private_assistant),
          style = PopopxTypeScale.headline,
          color = MaterialTheme.colors.onBackground,
          maxLines = 1
        )
        Text(
          stringResource(MR.strings.copilot_local_only_note),
          style = PopopxTypeScale.subheadline,
          color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
          maxLines = 2
        )
      }
    }
  }
}

@Composable
private fun PopopxDiscoverNodeRow(binding: PopopxMacNodeBinding?) {
  // `PopopxDiscoverBanner` (PopopxDiscoverView.swift:129-203): one tappable card, because the only next
  // action a status row can offer is the bonding sheet, and making the user hunt for a separate link is
  // what that banner exists to avoid. Desktop keeps the plain text row so its layout stays unchanged.
  if (appPlatform.isAndroid) {
    PopopxDiscoverNodeBanner(binding)
    return
  }
  Column(Modifier.fillMaxWidth().padding(horizontal = PopopxSpace.gutter, vertical = PopopxSpace.m)) {
    if (binding == null) {
      Text(
        stringResource(MR.strings.discover_node_heading),
        style = PopopxTypeScale.headline,
        color = MaterialTheme.colors.onBackground
      )
      Text(
        PopopxDiscoverCopy.NO_NODE_BONDED_NOTICE,
        style = PopopxTypeScale.caption,
        color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
        modifier = Modifier.padding(top = 2.dp)
      )
    } else {
      val hasDeviceLabel = binding.deviceLabel.isNotEmpty()
      Text(
        if (hasDeviceLabel) binding.deviceLabel else binding.nodeId,
        style = if (hasDeviceLabel) PopopxTypeScale.headline else PopopxTypeScale.code,
        color = MaterialTheme.colors.onBackground
      )
      Text(
        binding.offerFingerprint,
        style = PopopxTypeScale.codeSmall,
        color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
        modifier = Modifier.padding(top = 2.dp)
      )
    }
    Text(
      stringResource(MR.strings.discover_bond_action),
      style = PopopxTypeScale.callout,
      fontWeight = FontWeight.SemiBold,
      color = PopopxBrand,
      modifier = Modifier.clickable { showNodePairingSheet() }.padding(top = PopopxSpace.xs)
    )
  }
}

/**
 * The iOS node banner rebuilt on Android tokens: a `radiusCard` card on the page, a `radiusControl`
 * icon chip tinted at 12%, an emphasis headline, a two-line caption and a trailing chevron in
 * `labelHint`. The tint is the whole status: `meshInk` once the node answered, brand while bonded
 * but unanswered, `labelHint` before any bonding — the same three states and the same strings as
 * `DiscoverCopy` on iOS.
 */
@Composable
private fun PopopxDiscoverNodeBanner(binding: PopopxMacNodeBinding?) {
  val connected = binding?.handshakeConfirmed == true && binding?.contactId != null
  val tint = when {
    connected -> PopopxMeshInk
    binding == null -> PopopxLabelHint
    else -> PopopxBrand
  }
  val label = binding?.let {
    it.deviceLabel.ifEmpty {
      it.contactDisplayName?.takeIf { name -> name.isNotEmpty() }
        ?: generalGetString(MR.strings.discover_node_heading)
    }
  }
  val headline = when {
    binding == null -> stringResource(MR.strings.discover_banner_no_node)
    connected -> String.format(generalGetString(MR.strings.discover_banner_connected_format), label)
    else -> label.orEmpty()
  }
  val subline = when {
    binding == null -> stringResource(MR.strings.discover_pairing_intro)
    binding.contactId == null -> stringResource(MR.strings.discover_banner_needs_chat)
    connected -> stringResource(MR.strings.discover_banner_ready)
    else -> stringResource(MR.strings.discover_banner_idle)
  }
  PopopxCard(
    modifier = Modifier
      .padding(horizontal = PopopxSpace.gutter)
      .padding(top = PopopxSpace.xxs),
    contentPadding = PaddingValues(0.dp),
  ) {
    Row(
      Modifier
        .fillMaxWidth()
        .clickable { showNodePairingSheet() }
        .padding(PopopxSpace.s),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs)
    ) {
      Box(
        Modifier
          .size(38.dp)
          .clip(RoundedCornerShape(PopopxRadiusControl))
          .background(tint.copy(alpha = PopopxAlpha.wash)),
        contentAlignment = Alignment.Center
      ) {
        Icon(painterResource(MR.images.ic_desktop), null, Modifier.size(22.dp), tint = tint)
      }
      Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
          headline,
          style = PopopxTypeScale.headline,
          color = MaterialTheme.colors.onBackground,
          maxLines = 1,
          overflow = TextOverflow.Ellipsis
        )
        Text(
          subline,
          style = PopopxTypeScale.subheadline,
          color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
          maxLines = 2,
          overflow = TextOverflow.Ellipsis
        )
      }
      Spacer(Modifier.width(PopopxSpace.xxs))
      AutoMirroredIcon(painterResource(MR.images.ic_chevron_right), null, Modifier.size(PopopxSize.iconXs), tint = PopopxLabelHint)
    }
  }
}

private fun showNodePairingSheet() {
  ModalManager.start.showModalCloseable(cardScreen = true) { close ->
    PopopxNodePairingSheet(close)
  }
}

@Composable
private fun PopopxNodePairingSheet(close: () -> Unit) {
  val engine = PopopxSubscriptionEngine.shared
  val code = rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue("")) }
  // The engine's own paste gate: trim, empty means ignore, and every failure collapses into ONE
  // sentence, so this screen structurally cannot tell "not a code" from "forged code".
  val verdict = remember(code.value.text) { engine.acceptPastedCode(code.value.text) }
  var bondedTo: String? by remember { mutableStateOf(null) }
  // iOS's shape (MacNodePairingSheet.swift:126-149): Scan is the primary action, paste is revealed
  // behind its own button. The field also appears by itself once a scan or paste put a string in
  // `code`, so the result being verified is never invisible.
  var scanning by remember { mutableStateOf(false) }
  var pasteFieldShown by remember { mutableStateOf(false) }
  val scannerEnabled = remember { mutableStateOf(true) }

  ColumnWithScrollBar {
    AppBarTitle(stringResource(if (scanning) MR.strings.discover_pairing_scan else MR.strings.discover_pairing_title))
    Column(Modifier.padding(horizontal = PopopxSpace.gutter)) {
      if (scanning) {
        // The shared camera from the connect screen. Recognition hands the string to the same
        // `acceptPastedCode` verdict below — a scan grants no shortcut into the pairing state.
        QRCodeScanner(scannerEnabled) { text ->
          code.value = TextFieldValue(text.trim())
          scanning = false
          true
        }
      } else {
        Text(
          stringResource(MR.strings.discover_pairing_intro),
          style = PopopxTypeScale.callout,
          color = MaterialTheme.colors.onBackground
        )
        Spacer(Modifier.height(PopopxSpace.xs))
        PopopxCardActionButton(
          stringResource(MR.strings.discover_pairing_scan),
          painterResource(MR.images.ic_qr_code_scanner),
          primary = true,
          Modifier.fillMaxWidth()
        ) {
          scannerEnabled.value = true
          scanning = true
        }
        Spacer(Modifier.height(PopopxSpace.xs))
        PopopxCardActionButton(
          stringResource(MR.strings.discover_pairing_paste),
          painterResource(MR.images.ic_content_paste),
          primary = false,
          Modifier.fillMaxWidth()
        ) { pasteFieldShown = true }
        if (pasteFieldShown || code.value.text.isNotEmpty()) {
          Spacer(Modifier.height(PopopxSpace.xs))
          Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(PopopxRadiusControl),
            color = PopopxFieldSurface,
            border = BorderStroke(PopopxSize.hairline, PopopxHairlineStrong),
          ) {
            DefaultBasicTextField(
              modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = PopopxSpace.s, vertical = PopopxSpace.xs),
              state = code,
              textStyle = PopopxTypeScale.code,
              placeholder = {
                Text(
                  stringResource(MR.strings.discover_paste_placeholder),
                  style = PopopxTypeScale.body,
                  color = PopopxLabelHint
                )
              },
              keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
              onValueChange = { code.value = it },
            )
          }
        }
        when (val result = verdict) {
          is PopopxPairingAccept.Pending -> {
            Text(
              result.offer.nodeId,
              style = PopopxTypeScale.code,
              color = MaterialTheme.colors.onBackground,
              modifier = Modifier.padding(top = PopopxSpace.xs)
            )
            Text(
              stringResource(MR.strings.discover_pairing_window),
              style = PopopxTypeScale.caption,
              color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary)
            )
            Text(
              stringResource(MR.strings.discover_bond_action),
              style = PopopxTypeScale.callout,
              fontWeight = FontWeight.SemiBold,
              color = PopopxBrand,
              modifier = Modifier
                .clickable { bondedTo = if (engine.bond(result.offer)) result.offer.nodeId else null }
                .padding(top = PopopxSpace.xs, bottom = PopopxSpace.xs)
            )
          }
          is PopopxPairingAccept.Rejected -> Text(
            PopopxDiscoverCopy.GENERIC_PAIRING_NOTICE,
            style = PopopxTypeScale.subheadline,
            color = MaterialTheme.colors.error,
            modifier = Modifier.padding(top = PopopxSpace.xs)
          )
          else -> {}
        }
        bondedTo?.let { nodeId ->
          Text(
            stringResource(MR.strings.discover_bonded_format).format(nodeId),
            style = PopopxTypeScale.subheadline,
            color = PopopxBrand
          )
        }
        // Ruling ③: the bond is half of it. `PopopxSubscriptionEngine` can store a node and still have
        // `contactId = null`, which makes every protocol that ANSWERS the node — the feed's TOFU gate, the
        // upgrade card's two buttons — refuse quietly forever. iOS asks "which conversation is this Mac?"
        // (MacNodePairingSheet.swift:401-413); this asks the same question in the same sheet.
        engine.binding?.let { PopopxNodeContactPicker(it) }
      }
      Spacer(Modifier.height(PopopxSpace.m))
      SheetDone(close)
    }
  }
}

/**
 * The second half of bonding: naming the conversation the Mac answers on.
 *
 * The list is the app's own contact chats, unfiltered by name — iOS does the same and states the reason
 * (MacNodePairingSheet.swift:405-413): the chat is whatever the user called the machine, and a search box
 * here would imply the app knows which one it is. Nothing may guess either; a wrong guess sends control
 * signals into a person's private thread, which is why [PopopxSubscriptionEngine.attach] is only ever
 * reached from this tap.
 */
@Composable
private fun PopopxNodeContactPicker(binding: PopopxMacNodeBinding) {
  val engine = PopopxSubscriptionEngine.shared
  val scope = rememberCoroutineScope()
  // Read live off the engine instead of using the `binding` argument: `attach` writes through to the store, and
  // a copy taken when this sheet was composed would keep showing the OLD conversation as the chosen one after
  // the user picks another. Only the probe line needs local state, because it is this tap's outcome.
  val attachedId = engine.nodeContactId
  var probe by remember(binding.nodeId) {
    mutableStateOf(if (binding.handshakeConfirmed) NodeProbeState.CONFIRMED else NodeProbeState.IDLE)
  }

  SheetHeading(stringResource(MR.strings.discover_node_chat_picker_title))
  Text(
    stringResource(MR.strings.discover_node_chat_picker_hint),
    style = PopopxTypeScale.caption,
    color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary)
  )
  when (probe) {
    NodeProbeState.IDLE -> {}
    NodeProbeState.SENDING -> Text(
      stringResource(MR.strings.discover_node_probe_sending),
      style = PopopxTypeScale.caption,
      color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
      modifier = Modifier.padding(top = PopopxSpace.xxs)
    )
    NodeProbeState.CONFIRMED -> Text(
      stringResource(MR.strings.discover_node_probe_confirmed),
      style = PopopxTypeScale.caption,
      color = PopopxBrand,
      modifier = Modifier.padding(top = PopopxSpace.xxs)
    )
    NodeProbeState.FAILED -> Text(
      stringResource(MR.strings.discover_node_probe_failed),
      style = PopopxTypeScale.caption,
      color = MaterialTheme.colors.error,
      modifier = Modifier.padding(top = PopopxSpace.xxs)
    )
  }

  val contacts = popopxNodePickableContacts()
  if (contacts.isEmpty()) {
    Text(
      stringResource(MR.strings.discover_node_chat_picker_none),
      style = PopopxTypeScale.subheadline,
      color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
      modifier = Modifier.padding(top = PopopxSpace.xs)
    )
  }
  if (contacts.isNotEmpty()) {
    PopopxCard(contentPadding = PaddingValues(vertical = PopopxSpace.xxs)) {
      contacts.forEachIndexed { index, contact ->
        if (index > 0) PopopxDivider()
        SectionItemView(
          {
            engine.attach(contact.contactId, contact.displayName)
            probe = NodeProbeState.SENDING
            // The probe IS the handshake: `sendPairingProbe` emits the same `edge_compute_mesh::status` pairing
            // line the engine's `sendHandshake` documents, and only a delivered one may confirm the binding —
            // otherwise the sheet would carry a confirmation the node never saw.
            scope.launch {
              val delivered = PopopxSilentSignalingRouter.shared.sendPairingProbe(contact.contactId)
              if (delivered) engine.confirmHandshake()
              probe = if (delivered) NodeProbeState.CONFIRMED else NodeProbeState.FAILED
            }
          },
          padding = PaddingValues(horizontal = PopopxSpace.s, vertical = PopopxSpace.xs)
        ) {
          Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
              contact.displayName,
              style = PopopxTypeScale.headline,
              color = MaterialTheme.colors.onBackground,
              maxLines = 1
            )
            Text(
              stringResource(MR.strings.discover_node_chat_picker_confirm),
              style = PopopxTypeScale.caption,
              color = PopopxBrand
            )
          }
          if (contact.contactId == attachedId) {
            Text(
              stringResource(MR.strings.discover_node_chat_picker_selected),
              style = PopopxTypeScale.caption,
              color = PopopxBrand
            )
          }
        }
      }
    }
  }
}

private enum class NodeProbeState { IDLE, SENDING, CONFIRMED, FAILED }

private class PopopxNodePickableContact(val contactId: Long, val displayName: String)

/**
 * iOS's `contacts` (MacNodePairingSheet.swift:405-413): direct chats whose contact is still active and whose
 * chat has not been deleted, because a command sent into a deleted chat goes nowhere, which is the whole
 * point of attaching.
 */
private fun popopxNodePickableContacts(): List<PopopxNodePickableContact> =
  chatModel.chats.value.mapNotNull { chat ->
    val info = chat.chatInfo
    if (info !is ChatInfo.Direct || !info.contact.active || info.chatDeleted) return@mapNotNull null
    PopopxNodePickableContact(info.apiId, info.displayName)
  }

/**
 * 「发现 → 来自你的 Mac」 — the signed content a bonded Mac published, already decoded and verified by
 * `PopopxNodeFeedWire` before it was stored.
 *
 * It is not a shelf: a shelf is a service credits are spent to run, and these rows are the user's own
 * machine's content. Among the tiles they would read as something that bills.
 *
 * The rows show the envelope's bytes. Each item's seven fields are covered by a digest and a signature, so
 * rewriting or trimming one here would put on screen something no key attests to; only the header's own
 * timestamp is reformatted, and that is display, not content.
 *
 * Like `binding` above, this reads the engine directly instead of observing it, so a feed that arrives while
 * the tab is open shows on the tab's next recomposition.
 */
@Composable
private fun PopopxNodeFeedSection(snapshot: PopopxNodeFeedSnapshot?) {
  val items = snapshot?.items.orEmpty()
  val keyChanged = snapshot?.keyChangedAtMs != null
  if (items.isEmpty() && !keyChanged) return
  val uriHandler = LocalUriHandler.current

  Column(Modifier.fillMaxWidth().padding(horizontal = PopopxSpace.gutter)) {
    Row(
      Modifier.fillMaxWidth().padding(top = PopopxSpace.m, bottom = PopopxSpace.xs),
      verticalAlignment = Alignment.CenterVertically
    ) {
      Text(
        stringResource(MR.strings.discover_node_feed_title),
        style = PopopxTypeScale.headline,
        color = MaterialTheme.colors.onBackground,
        modifier = Modifier.weight(1f)
      )
      val generatedAt = snapshot?.generatedAt.orEmpty().substringBefore('T')
      if (generatedAt.isNotEmpty()) {
        Text(
          stringResource(MR.strings.discover_node_feed_updated).format(generatedAt),
          style = PopopxTypeScale.caption,
          color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary)
        )
      }
    }
    if (keyChanged) {
      // The one refusal that is not silent: content that stopped updating looks exactly like content that
      // did not change, so the panel says the key no longer matches rather than holding a stale list.
      Text(
        stringResource(MR.strings.discover_node_feed_key_changed),
        style = PopopxTypeScale.caption,
        color = MaterialTheme.colors.error,
        modifier = Modifier.padding(bottom = PopopxSpace.xs)
      )
    }
    items.forEach { item -> PopopxNodeFeedRow(item, uriHandler) }
    Text(
      stringResource(MR.strings.discover_node_feed_footer),
      style = PopopxTypeScale.caption,
      color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
      modifier = Modifier.padding(top = PopopxSpace.xs, bottom = PopopxSpace.m)
    )
  }
}

@Composable
private fun PopopxNodeFeedRow(item: PopopxNodeFeedItem, uriHandler: UriHandler) {
  // Only a web address becomes a tap target. The producer allows a local path in this same field
  // (`PopopxNodeFeedItem.link`), and turning that into a tap would have this app open a file the user never
  // saw, so anything else renders as text.
  val target = popopxNodeFeedTarget(item.link)
  Surface(
    modifier = Modifier
      .fillMaxWidth()
      .padding(bottom = PopopxSpace.xs),
    shape = RoundedCornerShape(PopopxRadiusControl),
    color = PopopxSurface,
    border = BorderStroke(PopopxSize.hairline, PopopxHairlineStrong),
  ) {
    Column(
      Modifier
        .fillMaxWidth()
        .let { if (target != null) it.clickable { uriHandler.openUri(target) } else it }
        .padding(horizontal = PopopxSpace.s, vertical = PopopxSpace.xs),
      verticalArrangement = Arrangement.spacedBy(2.dp)
    ) {
      Text(item.title, style = PopopxTypeScale.callout, color = MaterialTheme.colors.onBackground)
      if (item.summary.isNotEmpty()) {
        Text(
          item.summary,
          style = PopopxTypeScale.caption,
          color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
          maxLines = 3
        )
      }
      Text(
        listOf(item.sourceLabel.ifEmpty { item.source }, item.timestamp)
          .filter { it.isNotEmpty() }
          .joinToString(" · "),
        style = PopopxTypeScale.metricSmall,
        color = MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary),
        maxLines = 1
      )
    }
  }
}

private fun popopxNodeFeedTarget(link: String): String? {
  val scheme = link.substringBefore("://", "").lowercase()
  return if (scheme == "http" || scheme == "https") link else null
}
