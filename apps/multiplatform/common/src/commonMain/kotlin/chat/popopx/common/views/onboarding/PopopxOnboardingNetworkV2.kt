package chat.popopx.common.views.onboarding

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Divider
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import chat.popopx.common.mesh.PopopxMeshKillSwitch
import chat.popopx.common.model.ChatController.appPrefs
import chat.popopx.common.model.ChatModel
import chat.popopx.common.model.NotificationsMode
import chat.popopx.common.model.ServerOperator
import chat.popopx.common.platform.BackHandler
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.ui.theme.*
import chat.popopx.common.views.helpers.AutoMirroredIcon
import chat.popopx.common.views.helpers.LocalAppBarHandler
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.common.views.helpers.ModalView
import chat.popopx.common.views.helpers.rememberAppBarHandler
import chat.popopx.common.views.usersettings.changeNotificationsMode
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.launch

/** Onboarding screen 3 — routing and notifications, 1:1 with iOS `YourNetworkView`. */
@Composable
fun PopopxOnboardingNetwork(chatModel: ChatModel) {
  LaunchedEffect(Unit) { prepareChatBeforeFinishingOnboarding() }

  CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler()) {
    val scope = rememberCoroutineScope()
    val fuse = remember { PopopxMeshKillSwitch.shared }
    val fuseOn by remember { fuse.isEnabled }.collectAsState()

    val serverOperators = remember { derivedStateOf { chatModel.conditions.value.serverOperators } }
    val selectedOperatorIds = remember {
      mutableStateOf(serverOperators.value.filter { it.enabled }.map { it.operatorId }.toSet())
    }
    LaunchedEffect(selectedOperatorIds.value) {
      OnboardingSharedState.selectedOperatorIds = selectedOperatorIds.value
    }
    val notificationMode = rememberSaveable { mutableStateOf(NotificationsMode.default) }

    val openOperators = {
      ModalManager.fullscreen.showCustomModal { closeModal ->
        ChooseServerOperators(serverOperators, selectedOperatorIds, closeModal)
      }
    }

    ModalView({}, showClose = false, showAppBar = false) {
      BackHandler { appPrefs.onboardingStage.set(OnboardingStage.Step2_CreateProfile) }
      BoxWithConstraints(Modifier.fillMaxSize().systemBarsPadding()) {
        val compact = maxHeight < 900.dp
        Column(Modifier.fillMaxSize()) {
          ColumnWithScrollBar(Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
            Column(
              Modifier
                .fillMaxWidth()
                .padding(horizontal = PopopxSpace.m)
                .padding(top = PopopxSpace.s)
                .padding(bottom = PopopxSpace.m),
              verticalArrangement = Arrangement.spacedBy(if (compact) PopopxSpace.s else PopopxSpace.l)
            ) {
              PopopxOnboardingHeader(
                step = 2,
                steps = 3,
                stage = stringResource(MR.strings.onboarding_v2_stage_routing),
                title = stringResource(MR.strings.onboarding_v2_modes_title)
              )

              PopopxOnboardingSectionCard(
                title = stringResource(MR.strings.onboarding_v2_online_channel),
                footnote = stringResource(MR.strings.onboarding_v2_push_footnote)
              ) {
                PopopxOnboardingModeRow(
                  title = stringResource(MR.strings.onboarding_v2_mode_instant),
                  note = stringResource(MR.strings.onboarding_v2_instant_note),
                  selected = notificationMode.value == NotificationsMode.SERVICE,
                  chipText = stringResource(MR.strings.onboarding_v2_mode_selected),
                  compact = compact
                ) { notificationMode.value = NotificationsMode.SERVICE }
                PopopxOnboardingModeRow(
                  title = stringResource(MR.strings.onboarding_v2_mode_periodic),
                  note = stringResource(MR.strings.onboarding_v2_periodic_note),
                  selected = notificationMode.value == NotificationsMode.PERIODIC,
                  chipText = stringResource(MR.strings.onboarding_v2_mode_selected),
                  compact = compact
                ) { notificationMode.value = NotificationsMode.PERIODIC }
                PopopxOnboardingModeRow(
                  title = stringResource(MR.strings.onboarding_v2_mode_no_push),
                  note = stringResource(MR.strings.onboarding_v2_no_push_note),
                  selected = notificationMode.value == NotificationsMode.OFF,
                  chipText = stringResource(MR.strings.onboarding_v2_mode_selected),
                  compact = compact
                ) { notificationMode.value = NotificationsMode.OFF }
              }

              PopopxOnboardingSectionCard(
                footnote = stringResource(MR.strings.onboarding_v2_bluetooth_permission_note)
              ) {
                PopopxOnboardingToggleRow(
                  title = stringResource(MR.strings.onboarding_v2_offline_mesh),
                  note = stringResource(MR.strings.onboarding_v2_offline_mesh_note),
                  icon = MR.images.ic_wifi_tethering,
                  tint = PopopxOnboardingTint.MESH,
                  checked = fuseOn,
                  onCheckedChange = { enabled -> scope.launch { fuse.setEnabled(enabled) } }
                )
              }

              PopopxOnboardingSectionCard(
                footnote = if (serverOperators.value.size > 1) null else stringResource(MR.strings.onboarding_v2_operators_note)
              ) {
                if (serverOperators.value.size > 1) {
                  RelayPickerRow(
                    selected = selectedOperatorIds.value.size,
                    total = serverOperators.value.size,
                    onOpen = openOperators
                  )
                  PopopxOnboardingHairline()
                  RelayLogos(
                    operators = serverOperators.value.asReversed(),
                    selectedIds = selectedOperatorIds.value
                  )
                } else {
                  RelayReadyRow(
                    host = serverOperators.value.firstOrNull()?.serverDomains?.firstOrNull(),
                    compact = compact,
                    onOpen = openOperators
                  )
                }
              }
            }
          }
          Divider(color = PopopxSeparator, thickness = PopopxSize.hairline)
          PopopxOnboardingBottomBar {
            PopopxOnboardingPrimaryButton(
              text = stringResource(MR.strings.onboarding_v2_continue),
              icon = MR.images.ic_arrow_forward,
              mirrorIcon = true,
            ) {
              changeNotificationsMode(notificationMode.value, chatModel)
              appPrefs.onboardingStage.set(OnboardingStage.Step4_NetworkCommitments)
            }
            PopopxOnboardingGhostButton(
              text = stringResource(MR.strings.onboarding_v2_back),
              icon = MR.images.ic_arrow_back_ios_new,
              mirrorIcon = true,
            ) {
              appPrefs.onboardingStage.set(OnboardingStage.Step2_CreateProfile)
            }
          }
        }
      }
    }
  }
}

/** The picker line of the relay card: icon badge, title, "n / N" value and a disclosure chevron. */
@Composable
private fun RelayPickerRow(selected: Int, total: Int, onOpen: () -> Unit) {
  Row(
    Modifier
      .fillMaxWidth()
      .clickable(onClick = onOpen)
      .padding(vertical = PopopxSpace.xs),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.s),
    verticalAlignment = Alignment.CenterVertically
  ) {
    PopopxOnboardingIconBadge(MR.images.ic_dns, PopopxOnboardingTint.NEUTRAL)
    Text(
      stringResource(MR.strings.onboarding_v2_relay_nodes),
      style = PopopxTypeScale.headline,
      color = popopxOnboardingLabel(),
      modifier = Modifier.weight(1f)
    )
    Text("$selected / $total", style = PopopxTypeScale.callout, color = popopxOnboardingSecondary())
    AutoMirroredIcon(
      painterResource(MR.images.ic_chevron_right),
      null,
      Modifier.size(PopopxSize.iconL),
      tint = popopxOnboardingLabelHint()
    )
  }
}

/** The single-operator state: a status line rather than a "1 / 1" picker, still leading to the same sheet. */
@Composable
private fun RelayReadyRow(host: String?, compact: Boolean, onOpen: () -> Unit) {
  Row(
    Modifier
      .fillMaxWidth()
      .clickable(onClick = onOpen)
      .padding(vertical = if (compact) PopopxSpace.xs else PopopxSpace.s),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.s),
    verticalAlignment = Alignment.CenterVertically
  ) {
    PopopxOnboardingIconBadge(MR.images.ic_dns, PopopxOnboardingTint.BRAND)
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(PopopxSpace.xxs)) {
      Text(
        stringResource(MR.strings.onboarding_v2_relay_ready_title),
        style = PopopxTypeScale.headline,
        color = popopxOnboardingLabel()
      )
      if (host != null) {
        Text(host, style = PopopxTypeScale.subheadline, color = popopxOnboardingSecondary(), maxLines = 1, overflow = TextOverflow.Ellipsis)
      }
    }
    Spacer(Modifier.width(PopopxSpace.xs))
    PopopxOnboardingChip(stringResource(MR.strings.onboarding_v2_relay_auto_routing))
  }
}

/** The operator logo strip: unselected operators are drawn in grayscale, exactly like the iOS `.grayscale(1.0)`. */
@Composable
private fun RelayLogos(operators: List<ServerOperator>, selectedIds: Set<Long>) {
  Row(
    Modifier.fillMaxWidth().padding(vertical = PopopxSpace.xxs),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs),
    verticalAlignment = Alignment.CenterVertically
  ) {
    operators.forEach { op ->
      Image(
        painterResource(op.logo),
        null,
        Modifier
          .size(PopopxSpace.l)
          .clip(RoundedCornerShape(PopopxRadiusChip)),
        contentScale = ContentScale.Fit,
        colorFilter = if (selectedIds.contains(op.operatorId)) null else ColorFilter.colorMatrix(
          ColorMatrix().apply { setToSaturation(0f) }
        )
      )
    }
    Spacer(Modifier.weight(1f))
  }
}