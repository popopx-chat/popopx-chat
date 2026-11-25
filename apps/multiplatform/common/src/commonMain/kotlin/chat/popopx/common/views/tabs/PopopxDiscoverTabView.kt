package chat.popopx.common.views.tabs

import SectionItemView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.discover.PopopxDiscoverCatalog
import chat.popopx.common.discover.PopopxDiscoverCopy
import chat.popopx.common.discover.PopopxDiscoverFilter
import chat.popopx.common.discover.PopopxDiscoverSection
import chat.popopx.common.discover.PopopxMacNodeBinding
import chat.popopx.common.discover.PopopxNodeConsole
import chat.popopx.common.discover.PopopxNodeServiceId
import chat.popopx.common.discover.PopopxPairingAccept
import chat.popopx.common.discover.PopopxSubscriptionEngine
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.ui.theme.DEFAULT_PADDING
import chat.popopx.common.ui.theme.DEFAULT_PADDING_HALF
import chat.popopx.common.views.helpers.AppBarTitle
import chat.popopx.common.views.helpers.DefaultBasicTextField
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.stringResource

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
// - the QR camera. Bonding is paste-and-verify only, by ruling.

@Composable
fun PopopxDiscoverTabView() {
  val filterIndex = rememberSaveable { mutableStateOf(PopopxDiscoverFilter.ALL.ordinal) }
  val filter = PopopxDiscoverFilter.entries.getOrElse(filterIndex.value) { PopopxDiscoverFilter.ALL }
  val searchText = rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue("")) }
  val shelves = PopopxDiscoverCatalog.visibleSections(filter, searchText.value.text)
  val binding = PopopxSubscriptionEngine.shared.binding

  Column(Modifier.fillMaxSize()) {
    PopopxDiscoverSearchField(searchText)
    PopopxDiscoverFilterChips(filter) { index -> filterIndex.value = index }
    LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
      items(shelves, key = { it.id }) { shelf ->
        PopopxDiscoverShelf(shelf.section, shelf.services)
      }
      item { PopopxDiscoverNodeRow(binding) }
      item { Spacer(Modifier.height(DEFAULT_PADDING)) }
    }
  }
}

@Composable
private fun PopopxDiscoverSearchField(searchText: MutableState<TextFieldValue>) {
  DefaultBasicTextField(
    modifier = Modifier
      .fillMaxWidth()
      .padding(horizontal = DEFAULT_PADDING, vertical = DEFAULT_PADDING_HALF)
      .background(MaterialTheme.colors.background, shape = RoundedCornerShape(12.dp))
      .padding(horizontal = 12.dp, vertical = 10.dp),
    state = searchText,
    placeholder = {
      Text(
        stringResource(MR.strings.discover_search_services),
        color = MaterialTheme.colors.secondary,
        fontSize = MaterialTheme.typography.body1.fontSize
      )
    },
    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
    onValueChange = { searchText.value = it },
  )
}

@Composable
private fun PopopxDiscoverFilterChips(selected: PopopxDiscoverFilter, onSelect: (Int) -> Unit) {
  Row(
    Modifier
      .fillMaxWidth()
      .horizontalScroll(rememberScrollState())
      .padding(horizontal = DEFAULT_PADDING, vertical = DEFAULT_PADDING_HALF),
    horizontalArrangement = Arrangement.spacedBy(8.dp)
  ) {
    PopopxDiscoverFilter.entries.forEach { filter ->
      val active = filter == selected
      Text(
        filter.title,
        fontSize = 13.sp,
        color = if (active) MaterialTheme.colors.onPrimary else MaterialTheme.colors.onBackground,
        modifier = Modifier
          .clip(RoundedCornerShape(14.dp))
          .background(if (active) MaterialTheme.colors.primary else MaterialTheme.colors.background)
          .clickable { onSelect(PopopxDiscoverFilter.entries.indexOf(filter)) }
          .padding(horizontal = 12.dp, vertical = 6.dp)
      )
    }
  }
}

@Composable
private fun PopopxDiscoverShelf(section: PopopxDiscoverSection, services: List<PopopxNodeServiceId>) {
  Column(Modifier.fillMaxWidth().padding(horizontal = DEFAULT_PADDING)) {
    Text(
      section.title,
      style = MaterialTheme.typography.h3,
      modifier = Modifier.padding(top = DEFAULT_PADDING, bottom = DEFAULT_PADDING_HALF)
    )
    services.forEach { service ->
      PopopxDiscoverTile(service)
    }
  }
}

@Composable
private fun PopopxDiscoverTile(service: PopopxNodeServiceId) {
  SectionItemView({ showServiceDetail(service) }) {
    // No glyph: iOS picks these tiles by an SF Symbol name, and the moko drawable set has no
    // equivalent for nine of the ten. A monogram of the plaza name is the honest placeholder until
    // the visual pass, rather than a mapping that would silently rename what a service is.
    Box(
      contentAlignment = Alignment.Center,
      modifier = Modifier
        .size(40.dp)
        .clip(RoundedCornerShape(10.dp))
        .background(MaterialTheme.colors.background)
    ) {
      Text(
        service.title.take(1),
        fontSize = 16.sp,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colors.primary
      )
    }
    Spacer(Modifier.width(12.dp))
    Column(Modifier.weight(1f)) {
      Text(service.title, style = MaterialTheme.typography.body1, maxLines = 1)
      Text(
        service.tagline,
        style = MaterialTheme.typography.body2,
        color = MaterialTheme.colors.secondary,
        maxLines = 2
      )
      Text(
        service.cycleCost.priceLabel,
        fontSize = 12.sp,
        color = MaterialTheme.colors.primary,
        modifier = Modifier.padding(top = 2.dp)
      )
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
    Column(Modifier.padding(horizontal = DEFAULT_PADDING)) {
      Text(service.tagline, style = MaterialTheme.typography.body1)
      Spacer(Modifier.height(DEFAULT_PADDING_HALF))
      Text(service.cycleCost.priceLabel, fontSize = 13.sp, color = MaterialTheme.colors.primary)

      SheetHeading(stringResource(MR.strings.discover_highlights))
      service.highlights.forEach { highlight ->
        Row(Modifier.padding(vertical = 2.dp)) {
          Text("•", color = MaterialTheme.colors.secondary, fontSize = 13.sp)
          Spacer(Modifier.width(8.dp))
          Text(highlight, style = MaterialTheme.typography.body2, modifier = Modifier.weight(1f))
        }
      }

      SheetHeading(stringResource(MR.strings.discover_menu))
      service.menuActions.forEach { action ->
        Row(
          Modifier.fillMaxWidth().padding(vertical = 4.dp),
          verticalAlignment = Alignment.CenterVertically
        ) {
          Text(action.title, style = MaterialTheme.typography.body2, modifier = Modifier.weight(1f))
          Text(
            "${service.rawValue} · ${action.action}",
            fontSize = 11.sp,
            color = MaterialTheme.colors.secondary,
            maxLines = 1
          )
        }
      }
      Text(
        stringResource(MR.strings.discover_menu_hint),
        fontSize = 12.sp,
        color = MaterialTheme.colors.secondary,
        modifier = Modifier.padding(top = 4.dp, bottom = DEFAULT_PADDING)
      )

      SheetHeading(stringResource(MR.strings.discover_bridge_title))
      SectionItemView({ clipboard.setText(AnnotatedString(PopopxNodeConsole.copyText())) }) {
        Column(Modifier.weight(1f)) {
          Text(stringResource(MR.strings.discover_bridge_address), fontSize = 12.sp, color = MaterialTheme.colors.secondary)
          Text(PopopxNodeConsole.consoleDisplayUrl(), style = MaterialTheme.typography.body2)
        }
        Text(stringResource(MR.strings.copy_verb), fontSize = 13.sp, color = MaterialTheme.colors.primary)
      }
      Text(PopopxNodeConsole.tokenContractText(), fontSize = 12.sp, color = MaterialTheme.colors.secondary)
      Text(
        PopopxNodeConsole.LOCAL_ONLY_NOTE,
        fontSize = 12.sp,
        color = MaterialTheme.colors.secondary,
        modifier = Modifier.padding(top = 4.dp)
      )
      Spacer(Modifier.height(DEFAULT_PADDING))
      SheetDone(close)
    }
  }
}

@Composable
private fun SheetHeading(text: String) {
  Text(
    text,
    style = MaterialTheme.typography.h4,
    modifier = Modifier.padding(top = DEFAULT_PADDING, bottom = DEFAULT_PADDING_HALF)
  )
}

@Composable
private fun SheetDone(close: () -> Unit) {
  Text(
    stringResource(MR.strings.ok),
    color = MaterialTheme.colors.primary,
    fontSize = 14.sp,
    modifier = Modifier.clickable { close() }.padding(vertical = 8.dp)
  )
}

@Composable
private fun PopopxDiscoverNodeRow(binding: PopopxMacNodeBinding?) {
  Column(Modifier.fillMaxWidth().padding(horizontal = DEFAULT_PADDING, vertical = DEFAULT_PADDING)) {
    if (binding == null) {
      Text(stringResource(MR.strings.discover_node_heading), style = MaterialTheme.typography.body1)
      Text(
        PopopxDiscoverCopy.NO_NODE_BONDED_NOTICE,
        fontSize = 12.sp,
        color = MaterialTheme.colors.secondary,
        modifier = Modifier.padding(top = 2.dp)
      )
    } else {
      Text(
        binding.deviceLabel.ifEmpty { binding.nodeId },
        style = MaterialTheme.typography.body1
      )
      Text(
        binding.offerFingerprint,
        fontSize = 12.sp,
        color = MaterialTheme.colors.secondary,
        modifier = Modifier.padding(top = 2.dp)
      )
    }
    Text(
      stringResource(MR.strings.discover_bond_action),
      fontSize = 14.sp,
      color = MaterialTheme.colors.primary,
      modifier = Modifier.clickable { showNodePairingSheet() }.padding(top = 8.dp)
    )
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

  ColumnWithScrollBar {
    AppBarTitle(stringResource(MR.strings.discover_pairing_title))
    Column(Modifier.padding(horizontal = DEFAULT_PADDING)) {
      Text(stringResource(MR.strings.discover_pairing_intro), style = MaterialTheme.typography.body2)
      Spacer(Modifier.height(DEFAULT_PADDING_HALF))
      DefaultBasicTextField(
        modifier = Modifier
          .fillMaxWidth()
          .background(MaterialTheme.colors.background, shape = RoundedCornerShape(12.dp))
          .padding(horizontal = 12.dp, vertical = 10.dp),
        state = code,
        placeholder = {
          Text(
            stringResource(MR.strings.discover_paste_placeholder),
            color = MaterialTheme.colors.secondary,
            fontSize = MaterialTheme.typography.body1.fontSize
          )
        },
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
        onValueChange = { code.value = it },
      )
      when (val result = verdict) {
        is PopopxPairingAccept.Pending -> {
          Text(result.offer.nodeId, style = MaterialTheme.typography.body2, modifier = Modifier.padding(top = DEFAULT_PADDING_HALF))
          Text(
            stringResource(MR.strings.discover_pairing_window),
            fontSize = 12.sp,
            color = MaterialTheme.colors.secondary
          )
          Text(
            stringResource(MR.strings.discover_bond_action),
            fontSize = 14.sp,
            color = MaterialTheme.colors.primary,
            modifier = Modifier
              .clickable { bondedTo = if (engine.bond(result.offer)) result.offer.nodeId else null }
              .padding(top = 8.dp, bottom = 8.dp)
          )
        }
        is PopopxPairingAccept.Rejected -> Text(
          PopopxDiscoverCopy.GENERIC_PAIRING_NOTICE,
          fontSize = 13.sp,
          color = MaterialTheme.colors.error,
          modifier = Modifier.padding(top = DEFAULT_PADDING_HALF)
        )
        else -> {}
      }
      bondedTo?.let { nodeId ->
        Text(
          stringResource(MR.strings.discover_bonded_format).format(nodeId),
          fontSize = 13.sp,
          color = MaterialTheme.colors.primary
        )
      }
      Spacer(Modifier.height(DEFAULT_PADDING))
      SheetDone(close)
    }
  }
}
