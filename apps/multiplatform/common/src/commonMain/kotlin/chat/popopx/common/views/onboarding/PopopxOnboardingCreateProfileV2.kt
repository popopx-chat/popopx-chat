package chat.popopx.common.views.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.unit.dp
import chat.popopx.common.model.ChatController.appPrefs
import chat.popopx.common.model.ChatModel
import chat.popopx.common.platform.*
import chat.popopx.common.ui.theme.*
import chat.popopx.common.views.MAX_BIO_LENGTH_BYTES
import chat.popopx.common.views.bioFitsLimit
import chat.popopx.common.views.createProfileOnboarding
import chat.popopx.common.views.helpers.*
import chat.popopx.common.views.migration.MigrateToDeviceView
import chat.popopx.common.views.migration.MigrationToState
import chat.popopx.common.views.mkValidName
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import java.net.URI
import kotlinx.coroutines.launch

/** Onboarding screen 2 — create the first anonymous identity, 1:1 with iOS `CreateFirstProfile`. */
@Composable
fun PopopxOnboardingCreateProfile(chatModel: ChatModel, close: () -> Unit) {
  CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler()) {
    val focusManager = LocalFocusManager.current
    val scope = rememberCoroutineScope()
    val sheetState = rememberModalBottomSheetState(initialValue = ModalBottomSheetValue.Hidden)
    val displayName = rememberSaveable { mutableStateOf("") }
    val note = rememberSaveable { mutableStateOf("") }
    val chosenImage = rememberSaveable { mutableStateOf<URI?>(null) }
    val profileImage = rememberSaveable { mutableStateOf<String?>(null) }
    var avatarTintIndex by rememberSaveable { mutableStateOf(0) }
    var creating by remember { mutableStateOf(false) }

    val trimmedName = displayName.value.trim()
    val suggestedName = mkValidName(trimmedName)
    val nameIsUsable = trimmedName.isNotEmpty() && trimmedName == suggestedName
    val noteFitsLimit = bioFitsLimit(note.value)

    val back = {
      focusManager.clearFocus()
      if (chatModel.users.none { !it.user.hidden }) {
        appPrefs.onboardingStage.set(OnboardingStage.Step1_POPOPXInfo)
      } else {
        close()
      }
    }

    ModalBottomSheetLayout(
      scrimColor = Color.Black.copy(alpha = 0.12F),
      modifier = Modifier.imePadding(),
      sheetContent = {
        GetImageBottomSheet(
          chosenImage,
          onImageChange = { bitmap ->
            profileImage.value = resizeImageToStrSize(cropToSquare(bitmap), maxDataSize = 12500)
          },
          hideBottomSheet = { scope.launch { sheetState.hide() } })
      },
      sheetState = sheetState,
      sheetShape = RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp)
    ) {
      ModalView(
        close = back,
        endButtons = {
          TextButton(
            onClick = {
              focusManager.clearFocus()
              if (chatModel.migrationState.value == null) {
                chatModel.migrationState.value = MigrationToState.PasteOrScanLink
              }
              ModalManager.fullscreen.showCustomModal(animated = false, forceAnimated = appPlatform.isDesktop) { closeModal ->
                MigrateToDeviceView { closeModal() }
              }
            },
            modifier = Modifier.padding(end = PopopxSpace.xs)
          ) {
            Icon(painterResource(MR.images.ic_download), null, Modifier.size(22.dp), tint = MaterialTheme.colors.primary)
          }
        }
      ) {
        LaunchedEffect(Unit) { setLastVersionDefault(chatModel) }
        ColumnWithScrollBar(
          Modifier
            .fillMaxSize()
            .padding(top = AppBarHeight * fontSizeSqrtMultiplier)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
              focusManager.clearFocus()
            },
          horizontalAlignment = Alignment.Start
        ) {
          Column(
            Modifier.fillMaxWidth().padding(horizontal = PopopxSpace.m).padding(top = PopopxSpace.m).padding(bottom = PopopxSpace.xxl),
            verticalArrangement = Arrangement.spacedBy(PopopxSpace.l)
          ) {
            PopopxOnboardingHeader(
              step = 1,
              steps = 3,
              stage = stringResource(MR.strings.onboarding_v2_stage_identity),
              title = stringResource(MR.strings.onboarding_v2_identity_title),
              note = stringResource(MR.strings.onboarding_v2_identity_note)
            )

            ProfileAvatarRow(
              profileImage = profileImage.value,
              tint = popopxAvatarTints()[avatarTintIndex % popopxAvatarTints().size],
              onChoosePhoto = { scope.launch { sheetState.show() } },
              onNewAvatar = { avatarTintIndex += 1 }
            )

            PopopxOnboardingSectionCard {
              PopopxOnboardingTextField(
                stringResource(MR.strings.onboarding_v2_anonymous_name_prompt),
                displayName,
                MR.images.ic_person_add_500
              )
              if (trimmedName.isNotEmpty() && trimmedName != suggestedName) {
                Row(
                  Modifier.fillMaxWidth().padding(top = PopopxSpace.xs),
                  horizontalArrangement = Arrangement.spacedBy(PopopxSpace.s),
                  verticalAlignment = Alignment.CenterVertically
                ) {
                  PopopxOnboardingIconBadge(MR.images.ic_error_filled, PopopxOnboardingTint.DANGER)
                  Text(
                    stringResource(MR.strings.onboarding_v2_name_invalid_hint),
                    style = PopopxTypeScale.subheadline,
                    color = PopopxDangerFill
                  )
                  Spacer(Modifier.weight(1f))
                }
              } else if (trimmedName.isEmpty()) {
                Text(
                  stringResource(MR.strings.onboarding_v2_name_required),
                  style = PopopxTypeScale.subheadline,
                  color = popopxOnboardingSecondary(),
                  modifier = Modifier.padding(top = PopopxSpace.xs)
                )
              }

              PopopxOnboardingHairline()

              PopopxOnboardingTextField(
                stringResource(MR.strings.onboarding_v2_note_for_friends_prompt),
                note,
                MR.images.ic_edit_note
              )
              if (note.value.isNotEmpty()) {
                Row(
                  Modifier.fillMaxWidth().padding(top = PopopxSpace.xs),
                  horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs),
                  verticalAlignment = Alignment.CenterVertically
                ) {
                  Spacer(Modifier.weight(1f))
                  Text(
                    "${chatJsonLength(note.value)} / $MAX_BIO_LENGTH_BYTES",
                    style = PopopxTypeScale.metricSmall,
                    color = if (noteFitsLimit) popopxOnboardingLabelHint() else PopopxDangerFill
                  )
                }
              }
            }

            PopopxOnboardingSectionCard(title = stringResource(MR.strings.onboarding_v2_privacy_boost)) {
              val incognito = appPrefs.incognito.state
              PopopxOnboardingToggleRow(
                stringResource(MR.strings.onboarding_v2_incognito_row),
                stringResource(MR.strings.onboarding_v2_incognito_note),
                MR.images.ic_person_off,
                checked = incognito.value,
                onCheckedChange = { appPrefs.incognito.set(it) }
              )
            }

            PopopxOnboardingPrimaryButton(
              stringResource(MR.strings.onboarding_v2_next),
              MR.images.ic_arrow_forward,
              enabled = nameIsUsable && noteFitsLimit && !creating,
              loading = creating,
              mirrorIcon = true
            ) {
              focusManager.clearFocus()
              if (!creating) {
                creating = true
                val job = createProfileOnboarding(
                  chatModel,
                  trimmedName,
                  close,
                  shortDescr = note.value.ifEmpty { null },
                  image = profileImage.value
                )
                job.invokeOnCompletion { creating = false }
              }
            }
          }
        }
      }
    }
  }
}

@Composable
private fun popopxAvatarTints(): List<Color> = listOf(
  PopopxBrand,
  PopopxMesh,
  PopopxSuccess,
  PopopxDangerFill,
  MaterialTheme.colors.onBackground.copy(alpha = PopopxAlpha.secondary)
)

@Composable
private fun ProfileAvatarRow(
  profileImage: String?,
  tint: Color,
  onChoosePhoto: () -> Unit,
  onNewAvatar: () -> Unit,
) {
  Row(
    Modifier.fillMaxWidth(),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.m),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Box(
      Modifier
        .size(112.dp)
        .clickable(onClick = onChoosePhoto),
      contentAlignment = Alignment.Center
    ) {
      if (profileImage != null) {
        Box(Modifier.size(112.dp).clip(CircleShape)) {
          ProfileImage(112.dp, image = profileImage)
        }
      } else {
        Box(
          Modifier.size(112.dp).background(tint.copy(alpha = 0.16f), CircleShape),
          contentAlignment = Alignment.Center
        ) {
          Icon(painterResource(MR.images.ic_person_filled), null, Modifier.size(52.dp), tint = tint)
        }
      }
      Box(
        Modifier
          .align(Alignment.BottomEnd)
          .size(32.dp)
          .background(PopopxBrand, CircleShape)
          .border(PopopxSize.stroke, PopopxCanvas, CircleShape),
        contentAlignment = Alignment.Center
      ) {
        Icon(painterResource(MR.images.ic_photo_camera), null, Modifier.size(PopopxSize.iconL), tint = PopopxOnBrand)
      }
    }
    Column(
      Modifier.weight(1f),
      verticalArrangement = Arrangement.spacedBy(PopopxSpace.xs)
    ) {
      Text(
        stringResource(MR.strings.onboarding_v2_profile_photo),
        style = PopopxTypeScale.headline,
        color = popopxOnboardingLabel()
      )
      Text(
        stringResource(MR.strings.onboarding_v2_tap_to_choose_photo),
        style = PopopxTypeScale.subheadline,
        color = popopxOnboardingSecondary()
      )
      Row(
        Modifier
          .heightIn(min = PopopxSize.control)
          .background(sectionCardColor(), RoundedCornerShape(PopopxRadiusControl))
          .border(PopopxSize.stroke, popopxOnboardingLabelHint(), RoundedCornerShape(PopopxRadiusControl))
          .clickable(onClick = onNewAvatar)
          .padding(horizontal = PopopxSpace.m, vertical = PopopxSpace.s),
        horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs),
        verticalAlignment = Alignment.CenterVertically
      ) {
        Icon(painterResource(MR.images.ic_palette), null, Modifier.size(PopopxSize.iconL), tint = popopxOnboardingLabel())
        Text(
          stringResource(MR.strings.onboarding_v2_new_avatar),
          style = PopopxTypeScale.headline,
          color = popopxOnboardingLabel()
        )
      }
    }
  }
}