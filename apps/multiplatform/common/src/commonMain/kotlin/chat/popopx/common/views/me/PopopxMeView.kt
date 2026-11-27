package chat.popopx.common.views.me

import SectionBottomSpacer
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import chat.popopx.common.AppLock
import chat.popopx.common.commerce.PopopxP2PVoucherVault
import chat.popopx.common.commerce.PopopxVoucherState
import chat.popopx.common.duress.PopopxDuressAuthManager
import chat.popopx.common.mesh.PopopxMeshKillSwitch
import chat.popopx.common.model.*
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.platform.chatModel
import chat.popopx.common.platform.ColumnWithScrollBarNoAppBar
import chat.popopx.common.platform.showToast
import chat.popopx.common.ui.components.PopopxDivider
import chat.popopx.common.ui.components.PopopxPickerRow
import chat.popopx.common.ui.components.PopopxPrimaryButton
import chat.popopx.common.ui.components.PopopxSecondaryButton
import chat.popopx.common.ui.components.PopopxSection
import chat.popopx.common.ui.components.PopopxToggleRow
import chat.popopx.common.ui.theme.*
import chat.popopx.common.views.CreateProfile
import chat.popopx.common.views.badges.BadgesRedeemCodeView
import chat.popopx.common.views.badges.BadgesView
import chat.popopx.common.views.badges.currentShownBadge
import chat.popopx.common.views.chatlist.unreadCountStr
import chat.popopx.common.views.helpers.*
import chat.popopx.common.views.localauth.PopopxPanicWipeConfirm
import chat.popopx.common.views.localauth.PopopxPanicWipeUiState
import chat.popopx.common.views.usersettings.HelpAndSupportView
import chat.popopx.common.views.usersettings.PopopxDuressSettingsSection
import chat.popopx.common.views.usersettings.PrivacySettingsView
import chat.popopx.common.views.usersettings.SettingsView
import chat.popopx.common.views.usersettings.UserAddressView
import chat.popopx.common.views.usersettings.UserProfileView
import chat.popopx.common.views.usersettings.UserProfilesView
import chat.popopx.common.views.usersettings.doWithAuth
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.datetime.Clock
import kotlin.math.ceil
import kotlin.math.max

// The Me page, ported card for card from `apps/ios/Shared/Features/Me/PopopxMeView.swift`:
// identity header, assets and node benefits, encrypted profile and card vault, preferences, privacy
// defences (with the triple-tap mesh wipe last) and the help card. Reached only through
// `PopopxTab.ME`, which the tab bar shows on Android alone, so the desktop tree and its 376
// snapshot baselines never compose this file.
//
// Three rows of the iOS page have no destination on this tree and are deliberately absent rather
// than faked: the compute-credits wallet and top-up (this build sells nothing), the encrypted
// personal home page (no ProfileBuilder/ProfileStorageManager port) and the gift-send half of the
// card vault (there is no "send a badge" screen; the redeem half does exist). Their footnotes were
// rewritten to say only what the badge rows can actually do.
//
// The two iOS push pages (`UserProfilesView`, `PrivacySettings`, `PopopxHelpView`) exist here as
// modals already, so the row actions mount those same modals instead of inventing Android pages.

@Composable
fun PopopxMeView() {
  val user = remember { chatModel.currentUser }.value
  val startModalCount = ModalManager.start.modalCount.value
  val panic = remember { PopopxPanicWipeUiState() }
  val fuseOn by remember { PopopxMeshKillSwitch.shared.isEnabled }.collectAsState()

  Box(Modifier.fillMaxSize()) {
    ColumnWithScrollBarNoAppBar {
      Column(
        Modifier
          .statusBarsPadding()
          .padding(horizontal = PopopxSpace.m)
          .padding(top = PopopxSpace.l, bottom = PopopxSpace.xxl),
        verticalArrangement = Arrangement.spacedBy(PopopxSpace.l)
      ) {
        if (user == null) {
          MeEmptyIdentityCard()
        } else {
          MeIdentityCard(user)
        }
        MeAssetsCard()
        MeSpaceCard(startModalCount)
        MeGeneralCard()
        MeSecurityCard(panic, fuseOn, startModalCount)
        MeHelpCard()
      }
    }
    PopopxPanicWipeConfirm(panic)
  }
}

// MARK: - identity header

@Composable
private fun MeIdentityCard(user: User) {
  val clipboard = LocalClipboardManager.current
  val others = chatModel.users
    .filter { !it.user.hidden && it.user.userId != user.userId }
    .sortedByDescending { it.user.activeOrder }
  val lockedCount = chatModel.users.count { it.user.hidden }
  var busyUserId by remember { mutableStateOf<Long?>(null) }

  PopopxSection(footnote = meFootnote(others.size, lockedCount)) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
      Row(
        Modifier
          .weight(1f)
          .heightIn(min = PopopxSize.control)
          .clickable { showManageIdentities() }
          .padding(vertical = PopopxSpace.xxs),
        verticalAlignment = Alignment.CenterVertically
      ) {
        ProfileImage(64.dp, user.profile.image, color = MaterialTheme.colors.secondaryVariant)
        Spacer(Modifier.width(PopopxSpace.s))
        Column(Modifier.weight(1f)) {
          Text(
            user.displayName,
            style = PopopxTypeScale.headline,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis
          )
          if (user.fullName.isNotEmpty() && user.fullName != user.displayName) {
            Text(
              user.fullName,
              style = PopopxTypeScale.subheadline,
              color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
              maxLines = 1,
              overflow = TextOverflow.Ellipsis
            )
          }
          Spacer(Modifier.height(PopopxSpace.xxs))
          MeStatusCapsule()
        }
      }
      // The QR micro-badge is a sibling of the name row, never nested inside it: a nested tap target
      // only lets the outer one win, and then this button would never open.
      Box(
        Modifier
          .size(PopopxSize.control)
          .clickable { showProfileQR() },
        contentAlignment = Alignment.Center
      ) {
        Icon(painterResource(MR.images.ic_qr_code), null, Modifier.size(22.dp), tint = PopopxBrand)
      }
      AutoMirroredIcon(
        painterResource(MR.images.ic_chevron_right),
        null,
        Modifier.size(PopopxSize.iconS),
        tint = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.hint)
      )
    }
    PopopxDivider()
    Row(
      Modifier.fillMaxWidth().padding(vertical = PopopxSpace.xxs),
      verticalAlignment = Alignment.CenterVertically
    ) {
      Text(
        stringResource(MR.strings.me_identity_number),
        style = PopopxTypeScale.subheadline,
        color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary)
      )
      Spacer(Modifier.width(PopopxSpace.xs))
      Text("${user.userId}", style = PopopxTypeScale.metric)
      Spacer(Modifier.weight(1f))
      Text(
        stringResource(MR.strings.me_copy_number),
        style = PopopxTypeScale.callout,
        fontWeight = FontWeight.SemiBold,
        color = PopopxBrand,
        modifier = Modifier
          .heightIn(min = PopopxSize.control)
          .clickable {
            clipboard.setText(AnnotatedString("${user.userId}"))
            showToast(generalGetString(MR.strings.me_identity_number_copied))
          }
          .padding(vertical = PopopxSpace.s)
      )
    }
    if (others.isNotEmpty()) {
      PopopxDivider()
      Column(Modifier.fillMaxWidth().padding(vertical = PopopxSpace.xxs)) {
        Text(
          stringResource(MR.strings.me_other_identities),
          style = PopopxTypeScale.subheadline,
          color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary)
        )
        LazyRow(
          horizontalArrangement = Arrangement.spacedBy(PopopxSpace.s),
          contentPadding = PaddingValues(vertical = PopopxSpace.xs)
        ) {
          items(others, key = { it.user.userId }) { info ->
            MeIdentityChip(
              info = info,
              busy = busyUserId == info.user.userId,
              blocked = busyUserId != null && busyUserId != info.user.userId,
            ) {
              busyUserId = info.user.userId
              withBGApi {
                try {
                  chatModel.controller.changeActiveUser_(info.user.remoteHostId, info.user.userId, null)
                  showToast(generalGetString(MR.strings.me_switch_done))
                } catch (e: Exception) {
                  showToast(generalGetString(MR.strings.me_switch_failed))
                } finally {
                  busyUserId = null
                }
              }
            }
          }
        }
      }
    }
    PopopxDivider()
    PopopxSecondaryButton(
      stringResource(MR.strings.me_create_identity),
      onClick = {
        doWithAuth(
          generalGetString(MR.strings.auth_open_chat_profiles),
          generalGetString(MR.strings.auth_log_in_using_credential)
        ) {
          ModalManager.start.showModalCloseable(cardScreen = true) { close -> CreateProfile(chatModel, close) }
        }
      },
      modifier = Modifier.padding(vertical = PopopxSpace.xxs)
    )
  }
}

private fun meFootnote(others: Int, locked: Int): String? =
  when {
    others == 0 && locked > 0 -> generalGetString(MR.strings.me_locked_only_note).format(locked)
    others == 0 -> null
    locked > 0 -> generalGetString(MR.strings.me_switch_note_with_locked).format(locked)
    else -> generalGetString(MR.strings.me_switch_note)
  }

@Composable
private fun MeEmptyIdentityCard() {
  PopopxSection(footnote = stringResource(MR.strings.me_empty_footnote)) {
    Row(Modifier.fillMaxWidth().padding(vertical = PopopxSpace.xxs)) {
      ProfileImage(32.dp, null, color = MaterialTheme.colors.secondaryVariant)
      Spacer(Modifier.width(PopopxSpace.s))
      Column(Modifier.weight(1f)) {
        Text(stringResource(MR.strings.me_empty_title), style = PopopxTypeScale.headline)
        Spacer(Modifier.height(PopopxSpace.xxs))
        Text(
          stringResource(MR.strings.me_empty_note),
          style = PopopxTypeScale.subheadline,
          color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary)
        )
      }
    }
    PopopxDivider()
    PopopxPickerRow(
      label = stringResource(MR.strings.me_create_identity),
      value = null,
      icon = MR.images.ic_manage_accounts,
      tint = PopopxBrand,
      onClick = {
        doWithAuth(
          generalGetString(MR.strings.auth_open_chat_profiles),
          generalGetString(MR.strings.auth_log_in_using_credential)
        ) {
          ModalManager.start.showModalCloseable(cardScreen = true) { close -> CreateProfile(chatModel, close) }
        }
      }
    )
  }
}

@Composable
private fun MeStatusCapsule() {
  val badge = currentShownBadge()
  val lit = badge != null && badge.paidThrough > Clock.System.now()
  val tint = if (lit) PopopxSuccess else MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary)
  Row(
    Modifier
      .heightIn(min = 22.dp)
      .background(PopopxBrand.copy(alpha = PopopxAlpha.wash), CircleShape)
      .border(PopopxSize.hairline, tint.copy(alpha = PopopxAlpha.hint), CircleShape)
      .padding(horizontal = 10.dp, vertical = PopopxSpace.xxs),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xxs)
  ) {
    val encrypted = stringResource(MR.strings.me_smp_encrypted)
    val badgeWords =
      if (badge != null && lit) stringResource(MR.strings.me_badge_routing).format(meDaysLeft(badge))
      else stringResource(MR.strings.me_badge_dormant)
    Icon(painterResource(MR.images.ic_lock_filled), null, Modifier.size(10.dp), tint = tint)
    Text(
      "$encrypted · $badgeWords",
      style = PopopxTypeScale.overline,
      color = tint,
      maxLines = 1,
      overflow = TextOverflow.Ellipsis
    )
  }
}

@Composable
private fun MeIdentityChip(info: UserInfo, busy: Boolean, blocked: Boolean, action: () -> Unit) {
  val shape = RoundedCornerShape(PopopxRadiusControl)
  Row(
    Modifier
      .heightIn(min = PopopxSize.control)
      .background(PopopxFieldSurface, shape)
      .border(PopopxSize.hairline, PopopxHairlineStrong, shape)
      .clickable(enabled = !busy && !blocked, onClick = action)
      .padding(horizontal = 10.dp),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(6.dp)
  ) {
    if (busy) {
      CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = PopopxBrand)
    } else {
      ProfileImage(32.dp, info.user.profile.image, color = MaterialTheme.colors.secondaryVariant)
    }
    Text(info.user.displayName, style = PopopxTypeScale.callout, maxLines = 1, overflow = TextOverflow.Ellipsis)
    if (info.unreadCount > 0) {
      Box(
        Modifier
          .background(PopopxBrand, CircleShape)
          .padding(horizontal = 6.dp, vertical = 1.dp)
      ) {
        Text(unreadCountStr(info.unreadCount), style = PopopxTypeScale.metricSmall, color = PopopxOnBrand)
      }
    }
  }
}

private fun showManageIdentities() {
  ModalManager.start.showCustomModal(keyboardCoversBar = false) { close ->
    val search = rememberSaveable { mutableStateOf("") }
    val profileHidden = rememberSaveable { mutableStateOf(false) }
    val authorized = remember { stateGetOrPut("authorized") { false } }
    ModalView(
      { close() },
      showSearch = true,
      searchAlwaysVisible = true,
      onSearchValueChanged = { search.value = it },
      content = {
        UserProfilesView(chatModel, search, profileHidden) { block ->
          if (authorized.value) {
            block()
          } else {
            doWithAuth(
              generalGetString(MR.strings.auth_open_chat_profiles),
              generalGetString(MR.strings.auth_log_in_using_credential)
            ) {
              authorized.value = true
              block()
            }
          }
        }
      }
    )
  }
}

private fun showProfileQR() {
  // The full-screen profile card: mints a fresh one-time address on open and shows it in the iOS
  // pass-card layout. The address page stays reachable from the "Your POPOPX address" row below.
  showPopopxProfileQRCodeSheet()
}

// MARK: - group 1: assets and node benefits

@Composable
private fun MeAssetsCard() {
  val badge = currentShownBadge()
  val active = badge != null && badge.paidThrough > Clock.System.now()
  val value =
    if (active) stringResource(MR.strings.me_badge_running).format(meDaysLeft(badge!!))
    else stringResource(MR.strings.me_badge_dormant)

  PopopxSection(
    title = stringResource(MR.strings.me_group_assets),
    footnote = stringResource(MR.strings.me_badge_footnote)
  ) {
    PopopxPickerRow(
      label = stringResource(MR.strings.me_badge_row),
      value = value,
      icon = MR.images.ic_shield,
      tint = if (active) PopopxSuccess else MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
      onClick = { showBadges() }
    )
    Spacer(Modifier.height(PopopxSpace.xs))
    PopopxPrimaryButton(stringResource(if (active) MR.strings.me_badge_renew else MR.strings.me_badge_buy), onClick = {
      showBadges()
    })
  }
}

private fun meDaysLeft(badge: BadgeState): Int {
  val ms = (badge.paidThrough - Clock.System.now()).inWholeMilliseconds
  return max(1, ceil(ms / 86_400_000.0).toInt())
}

private fun showBadges() {
  ModalManager.start.showCustomModal(id = ModalViewId.BADGES) { close -> BadgesView(ModalManager.start, close) }
}

// MARK: - group 2: encrypted profile and card vault

@Composable
private fun MeSpaceCard(startModalCount: Int) {
  val voucherCount = remember(startModalCount) {
    PopopxP2PVoucherVault.shared.badgeVouchers(PopopxVoucherState.UNUSED).count()
  }
  PopopxSection(title = stringResource(MR.strings.me_group_space)) {
    PopopxPickerRow(
      label = stringResource(MR.strings.me_my_profile),
      value = null,
      icon = MR.images.ic_person,
      tint = PopopxBrand,
      onClick = {
        ModalManager.start.showCustomModal { close -> UserProfileView(chatModel, close) }
      }
    )
    PopopxDivider()
    val user = remember { chatModel.currentUser }.value
    PopopxPickerRow(
      label = stringResource(MR.strings.your_popopx_contact_address),
      value = null,
      icon = MR.images.ic_qr_code,
      tint = PopopxBrand,
      onClick = {
        if (user != null) {
          ModalManager.start.showCustomModal { close ->
            UserAddressView(chatModel, shareViaProfile = user.addressShared, close = close)
          }
        }
      }
    )
    PopopxDivider()
    PopopxPickerRow(
      label = stringResource(MR.strings.badges_redeem_code_button),
      value = if (voucherCount > 0) stringResource(MR.strings.me_vouchers_available).format(voucherCount) else null,
      icon = MR.images.ic_redeem,
      tint = PopopxBrand,
      onClick = {
        val depth = ModalManager.start.openModalCount()
        ModalManager.start.showModal(id = ModalViewId.BADGE_REDEEM_CODE) {
          BadgesRedeemCodeView(ModalManager.start, depth)
        }
      }
    )
  }
}

// MARK: - group 3: preferences

@Composable
private fun MeGeneralCard() {
  PopopxSection(title = stringResource(MR.strings.me_group_general)) {
    PopopxPickerRow(
      label = stringResource(MR.strings.me_settings),
      value = null,
      icon = MR.images.ic_settings,
      tint = PopopxBrand,
      onClick = {
        ModalManager.start.showModalCloseable(cardScreen = true) { close ->
          SettingsView(chatModel, AppLock::setPerformLA, close)
        }
      }
    )
  }
}

// MARK: - group 4: privacy and security defences

@Composable
private fun MeSecurityCard(panic: PopopxPanicWipeUiState, fuseOn: Boolean, startModalCount: Int) {
  val appPrefs = chatModel.controller.appPrefs
  var protectScreen by remember(startModalCount) { mutableStateOf(appPrefs.privacyProtectScreen.get()) }
  var sanitizeLinks by remember(startModalCount) { mutableStateOf(appPrefs.privacySanitizeLinks.get()) }
  val antiTheftOn = remember(startModalCount) {
    PopopxDuressAuthManager.shared.refreshConfiguration()
    PopopxDuressAuthManager.shared.duressEnabled
  }
  // Taps one and two leave the arming machine's countable state changing without touching a
  // Compose snapshot, so this counter is what makes the row's own value line honest.
  var tapSignal by remember { mutableStateOf(0) }

  PopopxSection(title = stringResource(MR.strings.me_group_security)) {
    PopopxPickerRow(
      label = stringResource(MR.strings.me_privacy_settings),
      value = null,
      icon = MR.images.ic_lock,
      tint = PopopxBrand,
      onClick = {
        ModalManager.start.showModal(settings = true, cardScreen = true) {
          PrivacySettingsView(
            chatModel,
            { modalView -> { ModalManager.start.showModal(settings = true, cardScreen = true) { modalView(chatModel) } } },
            AppLock::setPerformLA
          )
        }
      }
    )
    PopopxDivider()
    PopopxToggleRow(
      title = stringResource(MR.strings.protect_app_screen),
      checked = protectScreen,
      note = stringResource(MR.strings.me_protect_note),
      icon = MR.images.ic_lock,
      tint = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
      onCheckedChange = {
        appPrefs.privacyProtectScreen.set(it)
        protectScreen = it
      }
    )
    PopopxDivider()
    PopopxToggleRow(
      title = stringResource(MR.strings.sanitize_links_toggle),
      checked = sanitizeLinks,
      note = stringResource(MR.strings.me_sanitize_note),
      icon = MR.images.ic_link,
      tint = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
      onCheckedChange = {
        appPrefs.privacySanitizeLinks.set(it)
        sanitizeLinks = it
      }
    )
    PopopxDivider()
    PopopxPickerRow(
      label = stringResource(MR.strings.me_anti_theft),
      value = stringResource(if (antiTheftOn) MR.strings.me_turned_on else MR.strings.me_turned_off),
      icon = MR.images.ic_shield,
      tint = PopopxBrand,
      onClick = {
        ModalManager.start.showModal(settings = true, cardScreen = true) {
          ColumnWithScrollBar {
            AppBarTitle(stringResource(MR.strings.duress_settings_title))
            PopopxDuressSettingsSection()
            SectionBottomSpacer()
          }
        }
      }
    )
    PopopxDivider()
    Column(Modifier.fillMaxWidth().padding(vertical = PopopxSpace.xxs)) {
      val panicValue = when {
        panic.isConfirming.value -> stringResource(MR.strings.me_panic_awaiting)
        !fuseOn -> stringResource(MR.strings.me_panic_disabled)
        tapSignal > 0 && panic.arming.tapCount > 0 ->
          stringResource(MR.strings.me_panic_taps).format(panic.arming.tapCount)
        else -> stringResource(MR.strings.me_panic_ready)
      }
      PopopxPickerRow(
        label = stringResource(MR.strings.me_panic_row),
        value = panicValue,
        icon = MR.images.ic_warning_filled,
        tint = PopopxDangerFill,
        enabled = fuseOn,
        onClick = {
          if (fuseOn) {
            panic.tap()
            tapSignal++
          }
        }
      )
      Text(
        stringResource(MR.strings.me_panic_note),
        style = PopopxTypeScale.caption,
        color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
        modifier = Modifier.padding(horizontal = PopopxSpace.xxs)
      )
      Spacer(Modifier.height(PopopxSpace.xxs))
      Text(
        stringResource(MR.strings.me_panic_scope),
        style = PopopxTypeScale.overline,
        color = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
        modifier = Modifier.padding(horizontal = PopopxSpace.xxs)
      )
    }
  }
}

// MARK: - group 5: help and about

@Composable
private fun MeHelpCard() {
  PopopxSection {
    PopopxPickerRow(
      label = stringResource(MR.strings.me_help_row),
      value = null,
      icon = MR.images.ic_help,
      tint = MaterialTheme.colors.onSurface.copy(alpha = PopopxAlpha.secondary),
      onClick = {
        ModalManager.start.showModal(cardScreen = true) {
          HelpAndSupportView(
            chatModel,
            { modalView -> { ModalManager.start.showModal { modalView(chatModel) } } },
            { modalView -> { ModalManager.start.showCustomModal { close -> modalView(chatModel, close) } } }
          )
        }
      }
    )
  }
}