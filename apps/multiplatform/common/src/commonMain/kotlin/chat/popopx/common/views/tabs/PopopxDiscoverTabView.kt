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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
import chat.popopx.common.ui.theme.DEFAULT_PADDING
import chat.popopx.common.ui.theme.DEFAULT_PADDING_HALF
import chat.popopx.common.ui.theme.PopopxBrand
import chat.popopx.common.ui.theme.PopopxHairlineInner
import chat.popopx.common.ui.theme.PopopxLabelHint
import chat.popopx.common.ui.theme.PopopxMeshInk
import chat.popopx.common.ui.theme.PopopxRadiusCard
import chat.popopx.common.ui.theme.PopopxRadiusControl
import chat.popopx.common.ui.theme.isInDarkTheme
import chat.popopx.common.ui.theme.sectionCardColor
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
            style = TextStyle(textDirection = TextDirection.Ltr),
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
          Text(
            PopopxNodeConsole.consoleDisplayUrl(),
            style = MaterialTheme.typography.body2.copy(textDirection = TextDirection.Ltr)
          )
        }
        Text(stringResource(MR.strings.copy_verb), fontSize = 13.sp, color = MaterialTheme.colors.primary)
      }
      Text(
        PopopxNodeConsole.tokenContractText(),
        style = TextStyle(textDirection = TextDirection.Ltr),
        fontSize = 12.sp,
        color = MaterialTheme.colors.secondary
      )
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
private fun PopopxDiscoverAssistantRow() {
  // 「发现 → 我的私人助理」. Shown only where a copilot glue was installed, so the entry never leads to
  // a sheet that cannot answer: on a platform without calendar access the assistant does not exist, and
  // an absent row is honest where a dead one would not be.
  if (!PopopxEcoAssistantHost.available) return
  SectionItemView({ showPopopxEcoAssistantSheet() }) {
    Box(
      contentAlignment = Alignment.Center,
      modifier = Modifier
        .size(40.dp)
        .clip(RoundedCornerShape(10.dp))
        .background(MaterialTheme.colors.background)
    ) {
      Text(
        stringResource(MR.strings.discover_private_assistant).take(1),
        fontSize = 16.sp,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colors.primary
      )
    }
    Spacer(Modifier.width(12.dp))
    Column(Modifier.weight(1f)) {
      Text(stringResource(MR.strings.discover_private_assistant), style = MaterialTheme.typography.body1, maxLines = 1)
      Text(
        stringResource(MR.strings.copilot_local_only_note),
        style = MaterialTheme.typography.body2,
        color = MaterialTheme.colors.secondary,
        maxLines = 2
      )
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
  Surface(
    Modifier
      .fillMaxWidth()
      .padding(horizontal = 16.dp)
      .padding(top = 4.dp),
    shape = RoundedCornerShape(PopopxRadiusCard),
    color = sectionCardColor(),
    border = BorderStroke(0.5.dp, PopopxHairlineInner),
    elevation = if (isInDarkTheme()) 0.dp else 1.dp,
  ) {
    Row(
      Modifier.fillMaxWidth().clickable { showNodePairingSheet() }.padding(8.dp),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
      Box(
        Modifier
          .size(38.dp)
          .clip(RoundedCornerShape(PopopxRadiusControl))
          .background(tint.copy(alpha = 0.12f)),
        contentAlignment = Alignment.Center
      ) {
        Icon(painterResource(MR.images.ic_desktop), null, Modifier.size(22.dp), tint = tint)
      }
      Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
          headline,
          fontSize = 17.sp,
          fontWeight = FontWeight.SemiBold,
          color = MaterialTheme.colors.onBackground,
          maxLines = 1,
          overflow = TextOverflow.Ellipsis
        )
        Text(
          subline,
          fontSize = 13.sp,
          color = MaterialTheme.colors.secondary,
          maxLines = 2,
          overflow = TextOverflow.Ellipsis
        )
      }
      Spacer(Modifier.width(4.dp))
      AutoMirroredIcon(painterResource(MR.images.ic_chevron_right), null, Modifier.size(12.dp), tint = PopopxLabelHint)
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
    Column(Modifier.padding(horizontal = DEFAULT_PADDING)) {
      if (scanning) {
        // The shared camera from the connect screen. Recognition hands the string to the same
        // `acceptPastedCode` verdict below — a scan grants no shortcut into the pairing state.
        QRCodeScanner(scannerEnabled) { text ->
          code.value = TextFieldValue(text.trim())
          scanning = false
          true
        }
      } else {
        Text(stringResource(MR.strings.discover_pairing_intro), style = MaterialTheme.typography.body2)
        Spacer(Modifier.height(DEFAULT_PADDING_HALF))
        PopopxCardActionButton(
          stringResource(MR.strings.discover_pairing_scan),
          painterResource(MR.images.ic_qr_code_scanner),
          primary = true,
          Modifier.fillMaxWidth()
        ) {
          scannerEnabled.value = true
          scanning = true
        }
        Spacer(Modifier.height(8.dp))
        PopopxCardActionButton(
          stringResource(MR.strings.discover_pairing_paste),
          painterResource(MR.images.ic_content_paste),
          primary = false,
          Modifier.fillMaxWidth()
        ) { pasteFieldShown = true }
        if (pasteFieldShown || code.value.text.isNotEmpty()) {
          Spacer(Modifier.height(DEFAULT_PADDING_HALF))
          DefaultBasicTextField(
            modifier = Modifier
              .fillMaxWidth()
              .background(MaterialTheme.colors.background, shape = RoundedCornerShape(12.dp))
              .padding(horizontal = 12.dp, vertical = 10.dp),
            state = code,
            textStyle = TextStyle(textDirection = TextDirection.Ltr),
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
        }
        when (val result = verdict) {
          is PopopxPairingAccept.Pending -> {
            Text(
              result.offer.nodeId,
              style = MaterialTheme.typography.body2.copy(textDirection = TextDirection.Ltr),
              modifier = Modifier.padding(top = DEFAULT_PADDING_HALF)
            )
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
        // Ruling ③: the bond is half of it. `PopopxSubscriptionEngine` can store a node and still have
        // `contactId = null`, which makes every protocol that ANSWERS the node — the feed's TOFU gate, the
        // upgrade card's two buttons — refuse quietly forever. iOS asks "which conversation is this Mac?"
        // (MacNodePairingSheet.swift:401-413); this asks the same question in the same sheet.
        engine.binding?.let { PopopxNodeContactPicker(it) }
      }
      Spacer(Modifier.height(DEFAULT_PADDING))
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
    fontSize = 12.sp,
    color = MaterialTheme.colors.secondary
  )
  when (probe) {
    NodeProbeState.IDLE -> {}
    NodeProbeState.SENDING -> Text(
      stringResource(MR.strings.discover_node_probe_sending),
      fontSize = 12.sp,
      color = MaterialTheme.colors.secondary,
      modifier = Modifier.padding(top = 4.dp)
    )
    NodeProbeState.CONFIRMED -> Text(
      stringResource(MR.strings.discover_node_probe_confirmed),
      fontSize = 12.sp,
      color = MaterialTheme.colors.primary,
      modifier = Modifier.padding(top = 4.dp)
    )
    NodeProbeState.FAILED -> Text(
      stringResource(MR.strings.discover_node_probe_failed),
      fontSize = 12.sp,
      color = MaterialTheme.colors.error,
      modifier = Modifier.padding(top = 4.dp)
    )
  }

  val contacts = popopxNodePickableContacts()
  if (contacts.isEmpty()) {
    Text(
      stringResource(MR.strings.discover_node_chat_picker_none),
      fontSize = 13.sp,
      color = MaterialTheme.colors.secondary,
      modifier = Modifier.padding(top = DEFAULT_PADDING_HALF)
    )
  }
  contacts.forEach { contact ->
    SectionItemView({
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
    }) {
      Column(Modifier.weight(1f)) {
        Text(contact.displayName, style = MaterialTheme.typography.body1, maxLines = 1)
        Text(
          stringResource(MR.strings.discover_node_chat_picker_confirm),
          fontSize = 12.sp,
          color = MaterialTheme.colors.primary
        )
      }
      if (contact.contactId == attachedId) {
        Text(
          stringResource(MR.strings.discover_node_chat_picker_selected),
          fontSize = 12.sp,
          color = MaterialTheme.colors.primary
        )
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

  Column(Modifier.fillMaxWidth().padding(horizontal = DEFAULT_PADDING)) {
    Row(
      Modifier.fillMaxWidth().padding(top = DEFAULT_PADDING, bottom = DEFAULT_PADDING_HALF),
      verticalAlignment = Alignment.CenterVertically
    ) {
      Text(
        stringResource(MR.strings.discover_node_feed_title),
        style = MaterialTheme.typography.h3,
        modifier = Modifier.weight(1f)
      )
      val generatedAt = snapshot?.generatedAt.orEmpty().substringBefore('T')
      if (generatedAt.isNotEmpty()) {
        Text(
          stringResource(MR.strings.discover_node_feed_updated).format(generatedAt),
          fontSize = 12.sp,
          color = MaterialTheme.colors.secondary
        )
      }
    }
    if (keyChanged) {
      // The one refusal that is not silent: content that stopped updating looks exactly like content that
      // did not change, so the panel says the key no longer matches rather than holding a stale list.
      Text(
        stringResource(MR.strings.discover_node_feed_key_changed),
        fontSize = 12.sp,
        color = MaterialTheme.colors.error,
        modifier = Modifier.padding(bottom = DEFAULT_PADDING_HALF)
      )
    }
    items.forEach { item -> PopopxNodeFeedRow(item, uriHandler) }
    Text(
      stringResource(MR.strings.discover_node_feed_footer),
      fontSize = 12.sp,
      color = MaterialTheme.colors.secondary,
      modifier = Modifier.padding(top = DEFAULT_PADDING_HALF, bottom = DEFAULT_PADDING)
    )
  }
}

@Composable
private fun PopopxNodeFeedRow(item: PopopxNodeFeedItem, uriHandler: UriHandler) {
  // Only a web address becomes a tap target. The producer allows a local path in this same field
  // (`PopopxNodeFeedItem.link`), and turning that into a tap would have this app open a file the user never
  // saw, so anything else renders as text.
  val target = popopxNodeFeedTarget(item.link)
  Column(
    Modifier
      .fillMaxWidth()
      .padding(bottom = DEFAULT_PADDING_HALF)
      .clip(RoundedCornerShape(10.dp))
      .background(MaterialTheme.colors.background)
      .let { if (target != null) it.clickable { uriHandler.openUri(target) } else it }
      .padding(horizontal = 12.dp, vertical = 8.dp),
    verticalArrangement = Arrangement.spacedBy(2.dp)
  ) {
    Text(item.title, style = MaterialTheme.typography.body2)
    if (item.summary.isNotEmpty()) {
      Text(item.summary, fontSize = 12.sp, color = MaterialTheme.colors.secondary, maxLines = 3)
    }
    Text(
      listOf(item.sourceLabel.ifEmpty { item.source }, item.timestamp)
        .filter { it.isNotEmpty() }
        .joinToString(" · "),
      fontSize = 11.sp,
      color = MaterialTheme.colors.secondary,
      maxLines = 1
    )
  }
}

private fun popopxNodeFeedTarget(link: String): String? {
  val scheme = link.substringBefore("://", "").lowercase()
  return if (scheme == "http" || scheme == "https") link else null
}
