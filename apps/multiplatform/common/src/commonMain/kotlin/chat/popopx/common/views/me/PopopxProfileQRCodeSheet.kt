package chat.popopx.common.views.me

import SectionBottomSpacer
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import chat.popopx.common.invite.PopopxInviteShareForm
import chat.popopx.common.model.*
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.platform.chatModel
import chat.popopx.common.ui.theme.*
import chat.popopx.common.views.helpers.AppBarTitle
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.common.views.helpers.withBGApi
import chat.popopx.common.views.newchat.PopopxCardActionButton
import chat.popopx.common.views.newchat.PopopxCardActionRow
import chat.popopx.common.views.newchat.PopopxCardSecurityNote
import chat.popopx.common.views.newchat.PopopxPassCard
import chat.popopx.common.views.newchat.PopopxPassQRPlate
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// The profile card code, ported from apps/ios/Shared/Features/PersonalProfile/ProfileQRCodeSheet.swift.
//
// What it is: the QR carries a one-time contact address minted when the sheet opens, never the
// profile itself. Each opening mints a new invitation, so a code that has already been scanned cannot
// be photographed off the screen and reused.
//
// What is deliberately absent, because this client has no honest counterpart:
// - the send-mode card (standard / burn-after-reading) and the arming mirror. Both are displays of
//   `ProfileAutoSender`, the iOS-only engine that pushes the saved encrypted profile after a scan
//   connects. Android ships no profile sender and no saved-profile store, so a mode picker here
//   would store a preference nothing consumes — the exact kind of dead control this port avoids.
// - "Save to Photos": Android already saves a tapped QR through `QRCode`'s own tap-to-share, and the
//   plate keeps that behavior.
// Everything else — the card face, the mint-on-open lifecycle, the failure/retry field, the security
// note, share/copy/new-code — matches the iOS sheet, and the display string is the sealed `/i/v1/`
// form (`PopopxInviteShareForm`), never the server address.

@Composable
fun PopopxProfileQRCodeSheet(close: () -> Unit) {
  val identityName = chatModel.currentUser.value?.displayName
    ?.takeIf { it.isNotBlank() }
    ?: stringResource(MR.strings.profile_qr_identity_fallback)
  val minting = remember { mutableStateOf(false) }
  val failure = remember { mutableStateOf(false) }
  val form = remember { mutableStateOf<PopopxInviteShareForm?>(null) }

  fun mint() {
    if (minting.value) return
    minting.value = true
    failure.value = false
    form.value = null
    withBGApi {
      val rh = chatModel.currentRemoteHost.value?.remoteHostId
      val (minted, alert) = chatModel.controller.apiAddContact(rh, incognito = chatModel.controller.appPrefs.incognito.get())
      withContext(Dispatchers.Main) {
        minting.value = false
        if (minted != null) {
          form.value = PopopxInviteShareForm.make(minted.first, short = true)
        } else {
          failure.value = true
          alert?.invoke()
        }
      }
    }
  }

  LaunchedEffect(Unit) { mint() }

  ColumnWithScrollBar {
    AppBarTitle(stringResource(MR.strings.profile_qr_sheet_title))
    Column(
      Modifier.fillMaxWidth().padding(horizontal = PopopxSpace.m),
      verticalArrangement = Arrangement.spacedBy(PopopxSpace.m)
    ) {
      PopopxPassCard(identityName) {
        val display = form.value?.display
        when {
          display != null -> PopopxPassQRPlate(display)
          failure.value -> ProfileQRPlateFailure(onRetry = { mint() })
          else -> ProfileQRPlateMinting()
        }
      }
      PopopxCardSecurityNote(stringResource(MR.strings.profile_qr_security_note))
      form.value?.let { share ->
        PopopxCardActionRow(share.display)
        PopopxCardActionButton(
          stringResource(MR.strings.profile_qr_new_code),
          painterResource(MR.images.ic_refresh),
          primary = false,
          Modifier.fillMaxWidth()
        ) { mint() }
      }
      SectionBottomSpacer()
    }
  }
}

fun showPopopxProfileQRCodeSheet() {
  ModalManager.start.showModalCloseable(cardScreen = true) { close ->
    PopopxProfileQRCodeSheet(close)
  }
}

/** The field before a code exists, on the same `card` surface the QR will occupy: minting and failing
 * speak two different sentences, so a failure never reads as "wait a moment". */
@Composable
private fun ProfileQRPlateMinting() {
  val shape = RoundedCornerShape(PopopxRadiusControl)
  Column(
    Modifier
      .fillMaxWidth()
      .clip(shape)
      .background(PopopxSurface)
      .border(PopopxSize.hairline, PopopxHairlineStrong, shape)
      .heightIn(min = 220.dp),
    horizontalAlignment = Alignment.CenterHorizontally,
    verticalArrangement = Arrangement.Center
  ) {
    CircularProgressIndicator(color = PopopxBrand)
    Spacer(Modifier.height(PopopxSpace.s))
    Text(
      stringResource(MR.strings.profile_qr_minting),
      style = PopopxTypeScale.subheadline,
      color = MaterialTheme.colors.secondary
    )
  }
}

@Composable
private fun ProfileQRPlateFailure(onRetry: () -> Unit) {
  val shape = RoundedCornerShape(PopopxRadiusControl)
  Column(
    Modifier
      .fillMaxWidth()
      .clip(shape)
      .background(PopopxSurface)
      .border(PopopxSize.hairline, PopopxHairlineStrong, shape)
      .heightIn(min = 220.dp)
      .padding(PopopxSpace.m),
    horizontalAlignment = Alignment.CenterHorizontally,
    verticalArrangement = Arrangement.Center
  ) {
    Text(
      stringResource(MR.strings.profile_qr_mint_failed),
      style = PopopxTypeScale.subheadline,
      color = PopopxDangerFill,
      textAlign = TextAlign.Center
    )
    Spacer(Modifier.height(PopopxSpace.s))
    Text(
      stringResource(MR.strings.profile_qr_retry),
      style = PopopxTypeScale.headline,
      color = PopopxBrand,
      modifier = Modifier
        .clip(RoundedCornerShape(PopopxRadiusControl))
        .clickable { onRetry() }
        .padding(PopopxSpace.xs)
    )
  }
}