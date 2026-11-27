package chat.popopx.common.views.newchat

import SectionBottomSpacer
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.platform.shareText
import chat.popopx.common.platform.showToast
import chat.popopx.common.ui.theme.*
import chat.popopx.common.views.helpers.AppBarTitle
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource

// The pass-card screens, ported from the iOS pair
// (apps/ios/Shared/Features/AddFriend/PopopxQRCardSheet.swift and
// Shared/Features/PersonalProfile/ProfileQRCodeSheet.swift).
//
// Both are built from the same four atoms — the brand-gradient card face, the QR plate on a `card`
// surface, the link caption, and the copy/share action row — because iOS copied its profile card from
// its invitation card and kept the geometry identical. The QR itself is the existing `QRCode`
// composable, so the sealed `/i/v1/` link these sheets receive is the one thing that turns into
// pixels; no second encoder exists here.
//
// Chrome: these screens mount through `showModalCloseable(cardScreen = true)`, i.e. they run inside
// the app's own `ModalView` and take their back affordance from it. The iOS sheets are presented with
// caller-owned detents and draw their own close button; on Android the modal chrome is that caller.

private const val PASS_LINK_PREVIEW_CHARS = 28

/**
 * The card face: the only surface in the design where a gradient is allowed, built from one hue
 * (`PopopxBrand`) fading into itself. The tail stop is translucent, and the dark/light `onBackground`
 * underlay is what keeps the tail from washing out — the same construction as iOS `passSurface`
 * (`PopopxPalette.label` underneath, `PopopxPalette.onBrand` on top).
 */
@Composable
internal fun PopopxPassCard(
  identityName: String,
  modifier: Modifier = Modifier,
  plate: @Composable () -> Unit,
) {
  val brand = PopopxBrand
  val onBrand = PopopxOnBrand
  val shape = RoundedCornerShape(16.dp)
  Column(
    modifier
      .fillMaxWidth()
      // `popopxCardElevation` (PopopxTheme.swift:226-233): a 3pt blur one point down, light mode only.
      // Compose's shadow is the closest portable equivalent; dark mode stays flat, as on iOS.
      .shadow(if (isInDarkTheme()) 0.dp else 2.dp, shape)
      .clip(shape)
      .background(MaterialTheme.colors.onBackground)
      .border(0.5.dp, PopopxHairlineInner, shape)
  ) {
    Column(
      Modifier
        .fillMaxWidth()
        .background(
          Brush.linearGradient(
            listOf(
              brand,
              brand.copy(alpha = 0.92f),
              brand.copy(alpha = if (isInDarkTheme()) 0.70f else 0.55f)
            )
          )
        )
        .padding(16.dp),
      verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
      Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
          Text(
            stringResource(MR.strings.profile_qr_issuer),
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = onBrand
          )
          Text(
            identityName,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            color = onBrand,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis
          )
        }
        Spacer(Modifier.width(8.dp))
        Image(
          painterResource(MR.images.ic_popopx),
          contentDescription = null,
          modifier = Modifier.size(32.dp).clip(RoundedCornerShape(8.dp))
        )
      }
      plate()
    }
  }
}

/**
 * The QR plate on the card: the code and the link it encodes sit on the `card` surface, never on the
 * gradient — scanners read luminance difference, not brand polish (iOS `qrPlate`). The caption is one
 * truncated line of the sealed form, forced LTR because a machine value must not mirror in RTL.
 */
@Composable
internal fun PopopxPassQRPlate(uri: String) {
  val shape = RoundedCornerShape(12.dp)
  Column(
    Modifier
      .fillMaxWidth()
      .clip(shape)
      .background(MaterialTheme.colors.surface)
      .border(0.5.dp, PopopxHairlineInner, shape)
      .padding(16.dp),
    horizontalAlignment = Alignment.CenterHorizontally
  ) {
    QRCode(
      uri,
      small = uri.length < 200,
      modifier = Modifier.fillMaxWidth(),
      padding = PaddingValues(0.dp),
      tintColor = PopopxBrand
    )
    Spacer(Modifier.height(12.dp))
    val preview = if (uri.length > PASS_LINK_PREVIEW_CHARS) uri.take(PASS_LINK_PREVIEW_CHARS) + "…" else uri
    Text(
      preview,
      style = MaterialTheme.typography.body2.copy(textDirection = TextDirection.Ltr),
      fontSize = 12.sp,
      color = MaterialTheme.colors.secondary,
      maxLines = 1,
      overflow = TextOverflow.Clip,
      textAlign = TextAlign.Center
    )
  }
}

/** The lock line under the card. iOS draws it with the same two tokens on both sheets — including the
 * `lock.shield.fill` badge, which this app's icon set carries as a plain shield. */
@Composable
internal fun PopopxCardSecurityNote(text: String) {
  Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
    Icon(
      painterResource(MR.images.ic_shield),
      contentDescription = null,
      modifier = Modifier.padding(top = 2.dp).size(14.dp),
      tint = PopopxBrand
    )
    Spacer(Modifier.width(6.dp))
    Text(text, fontSize = 13.sp, color = MaterialTheme.colors.secondary)
  }
}

/**
 * The footer pair: Share carries the same sealed string the QR encodes, Copy puts it on the
 * clipboard. Neither mints or re-forms anything — re-sealing here would hand the user a second code
 * for one card.
 */
@Composable
internal fun PopopxCardActionRow(display: String) {
  val clipboard = LocalClipboardManager.current
  Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
    PopopxCardActionButton(
      stringResource(MR.strings.share_verb),
      painterResource(MR.images.ic_share_filled),
      primary = true,
      Modifier.weight(1f)
    ) { clipboard.shareText(display) }
    PopopxCardActionButton(
      stringResource(MR.strings.copy_verb),
      painterResource(MR.images.ic_content_copy),
      primary = false,
      Modifier.weight(1f)
    ) {
      clipboard.setText(AnnotatedString(display))
      showToast(generalGetString(MR.strings.copied))
    }
  }
}

@Composable
internal fun PopopxCardActionButton(
  text: String,
  icon: Painter,
  primary: Boolean,
  modifier: Modifier = Modifier,
  enabled: Boolean = true,
  click: () -> Unit,
) {
  val shape = RoundedCornerShape(12.dp)
  val fill = if (primary) PopopxBrand else MaterialTheme.colors.surface
  val ink = if (!enabled) MaterialTheme.colors.secondary else if (primary) PopopxOnBrand else PopopxBrand
  Row(
    modifier
      .heightIn(min = 44.dp)
      .clip(shape)
      .background(fill)
      .border(0.5.dp, if (primary) Color.Transparent else PopopxHairlineInner, shape)
      .clickable(enabled = enabled) { click() }
      .padding(horizontal = 16.dp, vertical = 12.dp),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.Center
  ) {
    Icon(icon, null, Modifier.size(18.dp), tint = ink)
    Spacer(Modifier.width(8.dp))
    Text(text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = ink)
  }
}

/**
 * The invitation card: one full screen for a link the invite flow already minted. `uri` must already
 * be the sealed `/i/v1/` display form; `originalURI` is the same invitation with the server address
 * visible, offered behind the fold exactly as on the settings page.
 */
@Composable
fun PopopxQRCardSheet(
  uri: String,
  identityName: String,
  originalURI: String?,
  close: () -> Unit,
) {
  ColumnWithScrollBar {
    AppBarTitle(stringResource(MR.strings.qr_card_sheet_title))
    Column(
      Modifier.fillMaxWidth().padding(horizontal = 16.dp),
      verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
      PopopxPassCard(identityName) { PopopxPassQRPlate(uri) }
      if (originalURI != null && originalURI != uri) {
        PopopxCardOriginalFold(originalURI)
      }
      PopopxCardSecurityNote(stringResource(MR.strings.qr_card_security_note))
      PopopxCardActionRow(uri)
      SectionBottomSpacer()
    }
  }
}

fun showPopopxQRCardSheet(uri: String, identityName: String, originalURI: String?) {
  ModalManager.start.showModalCloseable(cardScreen = true) { close ->
    PopopxQRCardSheet(uri, identityName, originalURI, close)
  }
}

/** The iOS card draws its own fold rather than reusing the settings screen's, so a host without the
 * `AppTheme` environment cannot crash on it; here the strings are the same resources the settings
 * fold prints, so one translation serves both surfaces. */
@Composable
private fun PopopxCardOriginalFold(original: String) {
  var showing by remember { mutableStateOf(false) }
  Column(Modifier.fillMaxWidth()) {
    Row(
      Modifier
        .fillMaxWidth()
        .clickable { showing = !showing }
        .padding(vertical = 4.dp),
      verticalAlignment = Alignment.CenterVertically
    ) {
      Text(
        stringResource(if (showing) MR.strings.invite_hide_original_link else MR.strings.invite_show_original_link),
        fontSize = 13.sp,
        color = MaterialTheme.colors.secondary
      )
      Spacer(Modifier.width(4.dp))
      Icon(
        painterResource(if (showing) MR.images.ic_chevron_up else MR.images.ic_chevron_down),
        null,
        Modifier.size(16.dp),
        tint = MaterialTheme.colors.secondary
      )
    }
    if (showing) {
      Text(
        original,
        style = MaterialTheme.typography.body2.copy(textDirection = TextDirection.Ltr),
        fontSize = 12.sp,
        modifier = Modifier.fillMaxWidth().padding(top = 4.dp)
      )
      Text(
        stringResource(MR.strings.invite_original_link_note),
        fontSize = 12.sp,
        color = MaterialTheme.colors.secondary,
        modifier = Modifier.fillMaxWidth().padding(top = 4.dp)
      )
    }
  }
}