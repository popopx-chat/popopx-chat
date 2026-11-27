package chat.popopx.common.views.onboarding

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.Divider
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.model.ChatModel
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.platform.appPlatform
import chat.popopx.common.ui.theme.*
import chat.popopx.common.views.helpers.LocalAppBarHandler
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.common.views.helpers.ModalView
import chat.popopx.common.views.helpers.rememberAppBarHandler
import chat.popopx.common.views.migration.MigrateToDeviceView
import chat.popopx.common.views.migration.MigrationToState
import chat.popopx.res.*
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import androidx.compose.runtime.CompositionLocalProvider

/** Onboarding screen 1 — the brand manifesto page, 1:1 with iOS `POPOPXInfo(onboarding: true)`. */
@Composable
fun PopopxOnboardingWelcome(chatModel: ChatModel) {
  CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler()) {
    ModalView({}, showClose = false, showAppBar = false) {
      BoxWithConstraints(Modifier.fillMaxSize().systemBarsPadding()) {
        val compact = maxHeight < 800.dp
        Column(Modifier.fillMaxSize()) {
          ColumnWithScrollBar(
            Modifier.weight(1f),
            horizontalAlignment = Alignment.CenterHorizontally
          ) {
            val sectionSpacing = if (compact) PopopxSpace.m else PopopxSpace.l
            Column(
              Modifier.fillMaxWidth().padding(bottom = PopopxSpace.m),
              horizontalAlignment = Alignment.CenterHorizontally,
              verticalArrangement = Arrangement.spacedBy(sectionSpacing)
            ) {
              WelcomeHero(compact)
              WelcomeHeadlines()
              WelcomePills()
              Text(
                stringResource(MR.strings.brand_mission),
                style = PopopxTypeScale.callout,
                color = popopxOnboardingSecondary(),
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = PopopxSpace.m)
              )
              WelcomeFeatureCard()
            }
          }
          WelcomeActions(chatModel)
        }
      }
    }
  }
  LaunchedEffect(Unit) {
    if (chatModel.migrationState.value != null && !ModalManager.fullscreen.hasModalsOpen()) {
      ModalManager.fullscreen.showCustomModal(animated = false) { close -> MigrateToDeviceView(close) }
    }
  }
}

@Composable
private fun WelcomeHero(compact: Boolean) {
  val transition = rememberInfiniteTransition()
  val scale by transition.animateFloat(
    initialValue = 0.94f,
    targetValue = 1.06f,
    animationSpec = infiniteRepeatable(tween(2600), RepeatMode.Reverse)
  )
  Box(
    Modifier
      .fillMaxWidth()
      .padding(top = if (compact) PopopxSpace.l else PopopxSpace.xl)
      .padding(horizontal = PopopxSpace.m),
    contentAlignment = Alignment.Center
  ) {
    Box(
      Modifier
        .size(268.dp, 152.dp)
        .graphicsLayer {
          scaleX = scale
          scaleY = scale
        }
        .blur(if (compact) 28.dp else 38.dp)
        .background(PopopxBrand.copy(alpha = 0.20f), CircleShape)
    )
    Image(
      painterResource(if (isInDarkTheme()) MR.images.logo_light else MR.images.logo),
      contentDescription = "POPOPX",
      contentScale = ContentScale.Fit,
      modifier = Modifier.widthIn(max = if (compact) 200.dp else 236.dp)
    )
  }
}

@Composable
private fun WelcomeHeadlines() {
  Column(
    Modifier.padding(horizontal = PopopxSpace.m),
    horizontalAlignment = Alignment.CenterHorizontally,
    verticalArrangement = Arrangement.spacedBy(PopopxSpace.xs)
  ) {
    Text(
      PopopxBrandCopy.CLAIM,
      style = PopopxTypeScale.caption.copy(fontWeight = FontWeight.SemiBold),
      color = PopopxBrand,
      textAlign = TextAlign.Center
    )
    Text(
      stringResource(MR.strings.onboarding_v2_hero_title),
      fontSize = 33.5.sp,
      fontWeight = FontWeight.Bold,
      lineHeight = 40.sp,
      color = popopxOnboardingLabel(),
      textAlign = TextAlign.Center
    )
    Text(
      stringResource(MR.strings.brand_positioning),
      style = PopopxTypeScale.callout,
      color = popopxOnboardingSecondary(),
      textAlign = TextAlign.Center
    )
    Text(
      stringResource(MR.strings.onboarding_v2_hero_note),
      style = PopopxTypeScale.callout,
      color = popopxOnboardingSecondary(),
      textAlign = TextAlign.Center
    )
    Text(
      stringResource(MR.strings.brand_slogan),
      style = PopopxTypeScale.subheadline,
      color = PopopxBrand,
      textAlign = TextAlign.Center
    )
  }
}

@Composable
private fun WelcomePills() {
  Row(
    Modifier.fillMaxWidth().padding(horizontal = PopopxSpace.m),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs),
    verticalAlignment = Alignment.Top
  ) {
    Box(Modifier.weight(1f)) {
      PopopxOnboardingModePill(
        MR.images.ic_shield,
        PopopxOnboardingTint.BRAND,
        stringResource(MR.strings.onboarding_v2_pill_smp)
      )
    }
    Box(Modifier.weight(1f)) {
      PopopxOnboardingModePill(
        MR.images.ic_wifi_tethering,
        PopopxOnboardingTint.MESH,
        stringResource(MR.strings.onboarding_v2_pill_mesh)
      )
    }
  }
}

@Composable
private fun WelcomeFeatureCard() {
  PopopxOnboardingSectionCard(
    title = stringResource(MR.strings.onboarding_v2_gives_you),
    footnote = stringResource(MR.strings.onboarding_v2_trial_badge_note)
  ) {
    PopopxOnboardingFeatureRow(
      MR.images.ic_person_off,
      PopopxOnboardingTint.BRAND,
      stringResource(MR.strings.onboarding_v2_no_user_ids_title),
      stringResource(MR.strings.onboarding_v2_no_user_ids_note)
    )
    PopopxOnboardingHairline()
    PopopxOnboardingFeatureRow(
      MR.images.ic_dns,
      PopopxOnboardingTint.MESH,
      stringResource(MR.strings.onboarding_v2_relays_title),
      stringResource(MR.strings.onboarding_v2_relays_note)
    )
    PopopxOnboardingHairline()
    PopopxOnboardingFeatureRow(
      MR.images.ic_visibility_off_filled,
      PopopxOnboardingTint.DANGER,
      stringResource(MR.strings.onboarding_v2_shield_title),
      stringResource(MR.strings.onboarding_v2_shield_note)
    )
  }
}

@Composable
private fun WelcomeActions(chatModel: ChatModel) {
  Column(Modifier.fillMaxWidth().background(PopopxCanvas)) {
    Divider(color = PopopxSeparator, thickness = PopopxSize.hairline)
    PopopxOnboardingBottomBar {
      PopopxOnboardingPrimaryButton(
        stringResource(MR.strings.onboarding_v2_create_identity),
        MR.images.ic_person_add_500
      ) {
        chatModel.controller.appPrefs.onboardingStage.set(OnboardingStage.Step2_CreateProfile)
      }
      PopopxOnboardingGhostButton(
        stringResource(MR.strings.onboarding_v2_restore_backup),
        MR.images.ic_settings_backup_restore
      ) {
        if (chatModel.migrationState.value == null) {
          chatModel.migrationState.value = MigrationToState.PasteOrScanLink
        }
        ModalManager.fullscreen.showCustomModal(animated = false, forceAnimated = appPlatform.isDesktop) { close ->
          MigrateToDeviceView {
            close()
            chatModel.migrationState.value = null
          }
        }
      }
    }
  }
}