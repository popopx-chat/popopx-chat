package chat.popopx.common.views.me

import SectionBottomSpacer
import androidx.compose.foundation.BorderStroke
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
import dev.icerock.moko.resources.ImageResource
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

private val meCardRadius = 16.dp
private val meIconSide = 32.dp
private val meChevronSide = 14.dp

// iOS `PopopxPalette` equivalents that are not in the shared theme yet. Kept file-private: they are
// this page's reading of the iOS palette, not a second theme.
private val labelHintAlpha = 0.35f
private val secondaryAlpha = 0.62f
private val separatorAlpha = 0.08f

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
          .padding(horizontal = 16.dp)
          .padding(top = 24.dp, bottom = 48.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp)
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

  MeSectionCard(footnote = meFootnote(others.size, lockedCount)) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
      Row(
        Modifier
          .weight(1f)
          .heightIn(min = 44.dp)
          .clickable { showManageIdentities() }
          .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
      ) {
        ProfileImage(64.dp, user.profile.image, color = MaterialTheme.colors.secondaryVariant)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
          Text(
            user.displayName,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis
          )
          if (user.fullName.isNotEmpty() && user.fullName != user.displayName) {
            Text(
              user.fullName,
              fontSize = 13.sp,
              color = MaterialTheme.colors.onSurface.copy(alpha = secondaryAlpha),
              maxLines = 1,
              overflow = TextOverflow.Ellipsis
            )
          }
          Spacer(Modifier.height(4.dp))
          MeStatusCapsule()
        }
      }
      // The QR micro-badge is a sibling of the name row, never nested inside it: a nested tap target
      // only lets the outer one win, and then this button would never open.
      Box(
        Modifier
          .size(44.dp)
          .clickable { showProfileQR() },
        contentAlignment = Alignment.Center
      ) {
        Icon(painterResource(MR.images.ic_qr_code), null, Modifier.size(22.dp), tint = PopopxBrand)
      }
      AutoMirroredIcon(
        painterResource(MR.images.ic_chevron_right),
        null,
        Modifier.size(meChevronSide),
        tint = MaterialTheme.colors.onSurface.copy(alpha = labelHintAlpha)
      )
    }
    MeDivider()
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
      Text(
        stringResource(MR.strings.me_identity_number),
        fontSize = 13.sp,
        color = MaterialTheme.colors.onSurface.copy(alpha = secondaryAlpha)
      )
      Spacer(Modifier.width(8.dp))
      Text("${user.userId}", fontSize = 13.sp)
      Spacer(Modifier.weight(1f))
      Text(
        stringResource(MR.strings.me_copy_number),
        fontSize = 15.sp,
        fontWeight = FontWeight.SemiBold,
        color = PopopxBrand,
        modifier = Modifier
          .heightIn(min = 44.dp)
          .clickable {
            clipboard.setText(AnnotatedString("${user.userId}"))
            showToast(generalGetString(MR.strings.me_identity_number_copied))
          }
          .padding(vertical = 12.dp)
      )
    }
    if (others.isNotEmpty()) {
      MeDivider()
      Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Text(
          stringResource(MR.strings.me_other_identities),
          fontSize = 13.sp,
          color = MaterialTheme.colors.onSurface.copy(alpha = secondaryAlpha)
        )
        LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(vertical = 8.dp)) {
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
    MeDivider()
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
      Spacer(Modifier.weight(1f))
      MeSecondaryButton(stringResource(MR.strings.me_create_identity)) {
        doWithAuth(
          generalGetString(MR.strings.auth_open_chat_profiles),
          generalGetString(MR.strings.auth_log_in_using_credential)
        ) {
          ModalManager.start.showModalCloseable(cardScreen = true) { close -> CreateProfile(chatModel, close) }
        }
      }
    }
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
  MeSectionCard(footnote = stringResource(MR.strings.me_empty_footnote)) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
      ProfileImage(32.dp, null, color = MaterialTheme.colors.secondaryVariant)
      Spacer(Modifier.width(12.dp))
      Column(Modifier.weight(1f)) {
        Text(stringResource(MR.strings.me_empty_title), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(4.dp))
        Text(
          stringResource(MR.strings.me_empty_note),
          fontSize = 13.sp,
          color = MaterialTheme.colors.onSurface.copy(alpha = secondaryAlpha)
        )
      }
    }
    MeDivider()
    MePickerRow(
      title = stringResource(MR.strings.me_create_identity),
      icon = MR.images.ic_manage_accounts,
      tint = PopopxBrand,
    ) {
      doWithAuth(
        generalGetString(MR.strings.auth_open_chat_profiles),
        generalGetString(MR.strings.auth_log_in_using_credential)
      ) {
        ModalManager.start.showModalCloseable(cardScreen = true) { close -> CreateProfile(chatModel, close) }
      }
    }
  }
}

@Composable
private fun MeStatusCapsule() {
  val badge = currentShownBadge()
  val lit = badge != null && badge.paidThrough > Clock.System.now()
  val tint = if (lit) PopopxSuccess else MaterialTheme.colors.onSurface.copy(alpha = secondaryAlpha)
  Row(
    Modifier
      .heightIn(min = 22.dp)
      .background(PopopxBrand.copy(alpha = 0.10f), CircleShape)
      .border(0.5.dp, tint.copy(alpha = 0.35f), CircleShape)
      .padding(horizontal = 10.dp, vertical = 4.dp),
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(4.dp)
  ) {
    val encrypted = stringResource(MR.strings.me_smp_encrypted)
    val badgeWords =
      if (badge != null && lit) stringResource(MR.strings.me_badge_routing).format(meDaysLeft(badge))
      else stringResource(MR.strings.me_badge_dormant)
    Icon(painterResource(MR.images.ic_lock_filled), null, Modifier.size(10.dp), tint = tint)
    Text(
      "$encrypted · $badgeWords",
      fontSize = 11.sp,
      color = tint,
      maxLines = 1,
      overflow = TextOverflow.Ellipsis
    )
  }
}

@Composable
private fun MeIdentityChip(info: UserInfo, busy: Boolean, blocked: Boolean, action: () -> Unit) {
  Row(
    Modifier
      .heightIn(min = 44.dp)
      .background(MaterialTheme.colors.onSurface.copy(alpha = separatorAlpha), RoundedCornerShape(12.dp))
      .border(0.5.dp, PopopxHairlineInner, RoundedCornerShape(12.dp))
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
    Text(info.user.displayName, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    if (info.unreadCount > 0) {
      Box(
        Modifier
          .background(PopopxBrand, CircleShape)
          .padding(horizontal = 6.dp, vertical = 1.dp)
      ) {
        Text(unreadCountStr(info.unreadCount), fontSize = 11.sp, color = PopopxOnBrand)
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

  MeSectionCard(title = stringResource(MR.strings.me_group_assets), footnote = stringResource(MR.strings.me_badge_footnote)) {
    MePickerRow(
      title = stringResource(MR.strings.me_badge_row),
      value = value,
      icon = MR.images.ic_shield,
      tint = if (active) PopopxSuccess else MaterialTheme.colors.onSurface.copy(alpha = secondaryAlpha),
    ) {
      showBadges()
    }
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
      Spacer(Modifier.weight(1f))
      MePrimaryButton(stringResource(if (active) MR.strings.me_badge_renew else MR.strings.me_badge_buy)) {
        showBadges()
      }
    }
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
  MeSectionCard(title = stringResource(MR.strings.me_group_space)) {
    MePickerRow(
      title = stringResource(MR.strings.me_my_profile),
      icon = MR.images.ic_person,
      tint = PopopxBrand,
    ) {
      ModalManager.start.showCustomModal { close -> UserProfileView(chatModel, close) }
    }
    MeDivider()
    val user = remember { chatModel.currentUser }.value
    MePickerRow(
      title = stringResource(MR.strings.your_popopx_contact_address),
      icon = MR.images.ic_qr_code,
      tint = PopopxBrand,
    ) {
      if (user != null) {
        ModalManager.start.showCustomModal { close ->
          UserAddressView(chatModel, shareViaProfile = user.addressShared, close = close)
        }
      }
    }
    MeDivider()
    MePickerRow(
      title = stringResource(MR.strings.badges_redeem_code_button),
      value = if (voucherCount > 0) stringResource(MR.strings.me_vouchers_available).format(voucherCount) else null,
      icon = MR.images.ic_redeem,
      tint = PopopxBrand,
    ) {
      val depth = ModalManager.start.openModalCount()
      ModalManager.start.showModal(id = ModalViewId.BADGE_REDEEM_CODE) {
        BadgesRedeemCodeView(ModalManager.start, depth)
      }
    }
  }
}

// MARK: - group 3: preferences

@Composable
private fun MeGeneralCard() {
  MeSectionCard(title = stringResource(MR.strings.me_group_general)) {
    MePickerRow(
      title = stringResource(MR.strings.me_settings),
      icon = MR.images.ic_settings,
      tint = PopopxBrand,
    ) {
      ModalManager.start.showModalCloseable(cardScreen = true) { close ->
        SettingsView(chatModel, AppLock::setPerformLA, close)
      }
    }
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

  MeSectionCard(title = stringResource(MR.strings.me_group_security)) {
    MePickerRow(
      title = stringResource(MR.strings.me_privacy_settings),
      icon = MR.images.ic_lock,
      tint = PopopxBrand,
    ) {
      ModalManager.start.showModal(settings = true, cardScreen = true) {
        PrivacySettingsView(
          chatModel,
          { modalView -> { ModalManager.start.showModal(settings = true, cardScreen = true) { modalView(chatModel) } } },
          AppLock::setPerformLA
        )
      }
    }
    MeDivider()
    MeToggleRow(
      title = stringResource(MR.strings.protect_app_screen),
      note = stringResource(MR.strings.me_protect_note),
      icon = MR.images.ic_lock,
      checked = protectScreen,
    ) {
      appPrefs.privacyProtectScreen.set(it)
      protectScreen = it
    }
    MeDivider()
    MeToggleRow(
      title = stringResource(MR.strings.sanitize_links_toggle),
      note = stringResource(MR.strings.me_sanitize_note),
      icon = MR.images.ic_link,
      checked = sanitizeLinks,
    ) {
      appPrefs.privacySanitizeLinks.set(it)
      sanitizeLinks = it
    }
    MeDivider()
    MePickerRow(
      title = stringResource(MR.strings.me_anti_theft),
      value = stringResource(if (antiTheftOn) MR.strings.me_turned_on else MR.strings.me_turned_off),
      icon = MR.images.ic_shield,
      tint = PopopxBrand,
    ) {
      ModalManager.start.showModal(settings = true, cardScreen = true) {
        ColumnWithScrollBar {
          AppBarTitle(stringResource(MR.strings.duress_settings_title))
          PopopxDuressSettingsSection()
          SectionBottomSpacer()
        }
      }
    }
    MeDivider()
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
      val panicValue = when {
        panic.isConfirming.value -> stringResource(MR.strings.me_panic_awaiting)
        !fuseOn -> stringResource(MR.strings.me_panic_disabled)
        tapSignal > 0 && panic.arming.tapCount > 0 ->
          stringResource(MR.strings.me_panic_taps).format(panic.arming.tapCount)
        else -> stringResource(MR.strings.me_panic_ready)
      }
      MePickerRow(
        title = stringResource(MR.strings.me_panic_row),
        value = panicValue,
        icon = MR.images.ic_warning_filled,
        tint = PopopxDangerFill,
        enabled = fuseOn,
      ) {
        if (fuseOn) {
          panic.tap()
          tapSignal++
        }
      }
      Text(
        stringResource(MR.strings.me_panic_note),
        fontSize = 12.sp,
        color = MaterialTheme.colors.onSurface.copy(alpha = secondaryAlpha),
        modifier = Modifier.padding(horizontal = 4.dp)
      )
      Spacer(Modifier.height(4.dp))
      Text(
        stringResource(MR.strings.me_panic_scope),
        fontSize = 11.sp,
        color = MaterialTheme.colors.onSurface.copy(alpha = secondaryAlpha),
        modifier = Modifier.padding(horizontal = 4.dp)
      )
    }
  }
}

// MARK: - group 5: help and about

@Composable
private fun MeHelpCard() {
  MeSectionCard {
    MePickerRow(
      title = stringResource(MR.strings.me_help_row),
      icon = MR.images.ic_help,
      tint = MaterialTheme.colors.onSurface.copy(alpha = secondaryAlpha),
    ) {
      ModalManager.start.showModal(cardScreen = true) {
        HelpAndSupportView(
          chatModel,
          { modalView -> { ModalManager.start.showModal { modalView(chatModel) } } },
          { modalView -> { ModalManager.start.showCustomModal { close -> modalView(chatModel, close) } } }
        )
      }
    }
  }
}

// MARK: - atoms (the Android reading of PopopxSectionCard / PopopxPickerRow / PopopxToggleRow)

@Composable
private fun MeSectionCard(
  title: String? = null,
  footnote: String? = null,
  content: @Composable ColumnScope.() -> Unit,
) {
  Column(Modifier.fillMaxWidth()) {
    if (title != null) {
      Text(
        title,
        fontSize = 17.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(start = 4.dp, bottom = 8.dp)
      )
    }
    Surface(
      Modifier.fillMaxWidth(),
      shape = RoundedCornerShape(meCardRadius),
      color = sectionCardColor(),
      border = BorderStroke(0.5.dp, PopopxHairlineInner),
      elevation = if (isInDarkTheme()) 0.dp else 1.dp,
    ) {
      Column(Modifier.padding(16.dp), content = content)
    }
    if (footnote != null) {
      Text(
        footnote,
        fontSize = 13.sp,
        color = MaterialTheme.colors.onSurface.copy(alpha = secondaryAlpha),
        modifier = Modifier.padding(start = 4.dp, top = 8.dp)
      )
    }
  }
}

@Composable
private fun MeDivider() {
  Box(
    Modifier
      .fillMaxWidth()
      .padding(vertical = 8.dp)
      .height(1.dp)
      .background(MaterialTheme.colors.onSurface.copy(alpha = separatorAlpha))
  )
}

@Composable
private fun MeIconBadge(icon: ImageResource, tint: Color) {
  Box(
    Modifier
      .size(meIconSide)
      .background(tint.copy(alpha = 0.12f), RoundedCornerShape(8.dp)),
    contentAlignment = Alignment.Center
  ) {
    Icon(painterResource(icon), null, Modifier.size(18.dp), tint = tint)
  }
}

@Composable
private fun MePickerRow(
  title: String,
  value: String? = null,
  icon: ImageResource,
  tint: Color,
  enabled: Boolean = true,
  action: () -> Unit,
) {
  Row(
    Modifier
      .fillMaxWidth()
      .heightIn(min = 44.dp)
      .clickable(enabled = enabled, onClick = action)
      .padding(vertical = 8.dp),
    verticalAlignment = Alignment.CenterVertically
  ) {
    MeIconBadge(icon, tint)
    Spacer(Modifier.width(12.dp))
    Text(
      title,
      fontSize = 17.sp,
      color = MaterialTheme.colors.onSurface.copy(alpha = if (enabled) 1f else 0.45f),
      modifier = Modifier.weight(1f)
    )
    if (value != null) {
      Spacer(Modifier.width(12.dp))
      Text(
        value,
        fontSize = 15.sp,
        color = MaterialTheme.colors.onSurface.copy(alpha = if (enabled) secondaryAlpha else 0.35f),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis
      )
    }
    Spacer(Modifier.width(8.dp))
    AutoMirroredIcon(
      painterResource(MR.images.ic_chevron_right),
      null,
      Modifier.size(meChevronSide),
      tint = MaterialTheme.colors.onSurface.copy(alpha = labelHintAlpha)
    )
  }
}

@Composable
private fun MeToggleRow(
  title: String,
  note: String,
  icon: ImageResource,
  checked: Boolean,
  onCheckedChange: (Boolean) -> Unit,
) {
  Row(
    Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(vertical = 8.dp),
    verticalAlignment = Alignment.CenterVertically
  ) {
    MeIconBadge(icon, MaterialTheme.colors.onSurface.copy(alpha = secondaryAlpha))
    Spacer(Modifier.width(12.dp))
    Column(Modifier.weight(1f)) {
      Text(title, fontSize = 17.sp)
      Spacer(Modifier.height(2.dp))
      Text(
        note,
        fontSize = 13.sp,
        color = MaterialTheme.colors.onSurface.copy(alpha = secondaryAlpha)
      )
    }
    Spacer(Modifier.width(12.dp))
    Switch(
      checked = checked,
      onCheckedChange = onCheckedChange,
      colors = SwitchDefaults.colors(
        checkedThumbColor = Color.White,
        checkedTrackColor = PopopxBrand,
        uncheckedThumbColor = Color.White,
        uncheckedTrackColor = MaterialTheme.colors.onSurface.copy(alpha = 0.18f),
      )
    )
  }
}

@Composable
private fun MePrimaryButton(text: String, action: () -> Unit) {
  Surface(
    shape = RoundedCornerShape(12.dp),
    color = PopopxBrand,
    modifier = Modifier.heightIn(min = 44.dp).clickable(onClick = action)
  ) {
    Box(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), contentAlignment = Alignment.Center) {
      Text(text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = PopopxOnBrand)
    }
  }
}

@Composable
private fun MeSecondaryButton(text: String, action: () -> Unit) {
  Surface(
    shape = RoundedCornerShape(12.dp),
    color = sectionCardColor(),
    border = BorderStroke(1.dp, MaterialTheme.colors.onSurface.copy(alpha = 0.18f)),
    modifier = Modifier.heightIn(min = 44.dp).clickable(onClick = action)
  ) {
    Box(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), contentAlignment = Alignment.Center) {
      Text(text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = PopopxBrand)
    }
  }
}