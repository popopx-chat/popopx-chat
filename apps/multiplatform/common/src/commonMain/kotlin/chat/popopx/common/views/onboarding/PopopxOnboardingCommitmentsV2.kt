package chat.popopx.common.views.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.ClickableText
import androidx.compose.material.Divider
import androidx.compose.material.Icon
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.popopx.common.AppLock
import chat.popopx.common.model.ChatController.appPrefs
import chat.popopx.common.model.ChatModel
import chat.popopx.common.platform.BackHandler
import chat.popopx.common.platform.ColumnWithScrollBar
import chat.popopx.common.platform.showToast
import chat.popopx.common.ui.theme.*
import chat.popopx.common.views.helpers.AlertManager
import chat.popopx.common.views.helpers.AppBarHeight
import chat.popopx.common.views.helpers.LAResult
import chat.popopx.common.views.helpers.LocalAppBarHandler
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.common.views.helpers.ModalView
import chat.popopx.common.views.helpers.authenticate
import chat.popopx.common.views.helpers.fontSizeSqrtMultiplier
import chat.popopx.common.views.helpers.generalGetString
import chat.popopx.common.views.helpers.isLocalAuthAvailable
import chat.popopx.common.views.helpers.rememberAppBarHandler
import chat.popopx.common.views.usersettings.LAMode
import chat.popopx.res.*
import dev.icerock.moko.resources.ImageResource
import dev.icerock.moko.resources.StringResource
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Onboarding screen 4 — security commitments, launch protection and the two offline legal documents, 1:1 with iOS `OnboardingConditionsView`. */
@Composable
fun PopopxOnboardingCommitments(chatModel: ChatModel) {
  CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler()) {
    val scope = rememberCoroutineScope()
    val serverOperators = remember { derivedStateOf { chatModel.conditions.value.serverOperators } }
    val selectedOperatorIds = remember { mutableStateOf(OnboardingSharedState.selectedOperatorIds) }
    val biometricAvailable = remember { isLocalAuthAvailable() }

    var relayCommitted by rememberSaveable { mutableStateOf(false) }
    var routingCommitted by rememberSaveable { mutableStateOf(false) }
    var wipeCommitted by rememberSaveable { mutableStateOf(false) }
    var agreed by rememberSaveable { mutableStateOf(false) }
    var biometricOn by rememberSaveable { mutableStateOf(false) }
    var accepting by remember { mutableStateOf(false) }

    val commitmentsMet = relayCommitted && routingCommitted && wipeCommitted
    val canEnter = commitmentsMet && agreed

    val finishAfterToasts: () -> Unit = {
      scope.launch {
        showToast(generalGetString(MR.strings.onboarding_v2_ready_toast))
        delay(2600)
        appPrefs.onboardingStage.set(OnboardingStage.OnboardingComplete)
      }
    }

    val openLegal: (PopopxLegalDocument) -> Unit = { doc ->
      ModalManager.fullscreen.showCustomModal { closeModal ->
        PopopxOnboardingLegalModal(doc, closeModal)
      }
    }

    ModalView({}, showClose = false, showAppBar = false) {
      BackHandler { appPrefs.onboardingStage.set(OnboardingStage.Step3_ChooseServerOperators) }
      BoxWithConstraints(Modifier.fillMaxSize().systemBarsPadding()) {
        val compact = maxHeight < 900.dp
        Column(Modifier.fillMaxSize()) {
          ColumnWithScrollBar(Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
            Column(
              Modifier
                .fillMaxWidth()
                .padding(horizontal = PopopxOnboardingGutter)
                .padding(top = PopopxOnboardingSpaceS)
                .padding(bottom = PopopxOnboardingSpaceM),
              verticalArrangement = Arrangement.spacedBy(if (compact) PopopxOnboardingSpaceS else PopopxOnboardingSpaceL)
            ) {
              PopopxOnboardingHeader(
                step = 3,
                steps = 3,
                stage = stringResource(MR.strings.onboarding_v2_stage_commitments),
                title = stringResource(MR.strings.onboarding_v2_commitments_title)
              )

              PopopxOnboardingSectionCard(title = stringResource(MR.strings.onboarding_v2_commitments_card)) {
                CommitmentRow(
                  title = stringResource(MR.strings.onboarding_v2_commitment_relay),
                  checked = relayCommitted,
                  compact = compact
                ) { relayCommitted = !relayCommitted }
                CommitmentRow(
                  title = stringResource(MR.strings.onboarding_v2_commitment_routing),
                  checked = routingCommitted,
                  compact = compact
                ) { routingCommitted = !routingCommitted }
                CommitmentRow(
                  title = stringResource(MR.strings.onboarding_v2_commitment_wipe),
                  checked = wipeCommitted,
                  compact = compact
                ) { wipeCommitted = !wipeCommitted }
              }

              PopopxOnboardingSectionCard(title = stringResource(MR.strings.onboarding_v2_launch_protection)) {
                PopopxOnboardingToggleRow(
                  title = stringResource(MR.strings.onboarding_v2_biometric_row),
                  note = stringResource(
                    if (biometricAvailable) MR.strings.onboarding_v2_biometric_note
                    else MR.strings.onboarding_v2_biometric_unavailable
                  ),
                  icon = MR.images.ic_lock,
                  checked = biometricOn,
                  enabled = biometricAvailable,
                  onCheckedChange = { biometricOn = it }
                )
              }

              PopopxOnboardingSectionCard(
                title = stringResource(MR.strings.onboarding_v2_legal_card),
                footnote = stringResource(MR.strings.onboarding_v2_legal_readable_offline)
              ) {
                Row(horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceXS)) {
                  LegalCapsule(
                    title = stringResource(MR.strings.onboarding_v2_privacy_policy),
                    icon = MR.images.ic_shield,
                    modifier = Modifier.weight(1f)
                  ) { openLegal(PopopxLegalDocument.PRIVACY) }
                  LegalCapsule(
                    title = stringResource(MR.strings.onboarding_v2_terms_of_use),
                    icon = MR.images.ic_article,
                    modifier = Modifier.weight(1f)
                  ) { openLegal(PopopxLegalDocument.TERMS) }
                }
                PopopxOnboardingHairline()
                AgreementRow(
                  agreed = agreed,
                  onToggle = { agreed = !agreed },
                  onOpenLegal = openLegal,
                  modifier = Modifier.padding(top = if (compact) PopopxOnboardingSpace2XS else PopopxOnboardingSpaceXS)
                )
              }
            }
          }
          Divider(color = PopopxSeparator, thickness = PopopxOnboardingHairlineWidth)
          PopopxOnboardingBottomBar {
            if (!commitmentsMet) {
              Text(
                stringResource(MR.strings.onboarding_v2_commitments_required),
                fontSize = 13.sp,
                color = popopxOnboardingSecondary(),
                lineHeight = 17.sp
              )
            } else if (!agreed) {
              Text(
                stringResource(MR.strings.onboarding_v2_legal_required),
                fontSize = 13.sp,
                color = popopxOnboardingSecondary(),
                lineHeight = 17.sp
              )
            }
            PopopxOnboardingPrimaryButton(
              text = stringResource(MR.strings.onboarding_v2_agree_and_enter),
              icon = MR.images.ic_shield,
              enabled = canEnter,
              loading = accepting,
            ) {
              if (accepting) return@PopopxOnboardingPrimaryButton
              accepting = true
              val ids = selectedOperatorIds.value.ifEmpty { serverOperators.value.map { it.operatorId }.toSet() }
              acceptConditions(
                ids,
                onComplete = {
                  scope.launch {
                    if (biometricOn) {
                      appPrefs.laMode.set(LAMode.SYSTEM)
                      authenticate(
                        generalGetString(MR.strings.auth_enable_popopx_lock),
                        generalGetString(MR.strings.auth_confirm_credential),
                        selfDestruct = false,
                        oneTime = true,
                        completed = { result ->
                          if (result is LAResult.Success) {
                            appPrefs.performLA.set(true)
                            AppLock.userAuthorized.value = true
                          } else {
                            appPrefs.performLA.set(false)
                          }
                          scope.launch { finishAfterToasts() }
                        }
                      )
                    } else {
                      finishAfterToasts()
                    }
                  }
                },
                onError = {
                  scope.launch {
                    accepting = false
                    AlertManager.shared.showAlertMsg(
                      title = generalGetString(MR.strings.onboarding_v2_error_accepting_conditions)
                    )
                  }
                }
              )
            }
          }
        }
      }
    }
  }
}

/** The three promise rows: whole-row toggle, brand wash + stroke + filled square + white check when on. */
@Composable
private fun CommitmentRow(title: String, checked: Boolean, compact: Boolean, onToggle: () -> Unit) {
  Row(
    Modifier
      .fillMaxWidth()
      .padding(vertical = if (compact) PopopxOnboardingSpace2XS else PopopxOnboardingSpaceXS)
      .background(
        if (checked) PopopxBrand.copy(alpha = 0.08f) else androidx.compose.ui.graphics.Color.Transparent,
        RoundedCornerShape(PopopxOnboardingRadiusControl)
      )
      .border(
        if (checked) PopopxOnboardingDividerWidth else PopopxOnboardingHairlineWidth,
        if (checked) PopopxBrand else PopopxHairlineInner,
        RoundedCornerShape(PopopxOnboardingRadiusControl)
      )
      .clickable(onClick = onToggle)
      .padding(
        horizontal = PopopxOnboardingSpaceXS,
        vertical = if (compact) PopopxOnboardingSpace2XS else PopopxOnboardingSpaceS
      ),
    horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceS),
    verticalAlignment = Alignment.Top
  ) {
    Text(
      title,
      fontSize = 17.sp,
      fontWeight = FontWeight.SemiBold,
      color = if (checked) PopopxBrand else popopxOnboardingLabel(),
      modifier = Modifier.weight(1f)
    )
    Spacer(Modifier.width(PopopxOnboardingSpaceXS))
    PopopxOnboardingCheckSquare(checked)
  }
}

/** One document capsule: 10% brand wash, 0.5dp brand-35% stroke, brand icon, caption title up to two lines. */
@Composable
private fun LegalCapsule(
  title: String,
  icon: ImageResource,
  modifier: Modifier = Modifier,
  onOpen: () -> Unit,
) {
  Row(
    modifier
      .heightIn(min = PopopxOnboardingMinHitTarget)
      .background(PopopxBrand.copy(alpha = 0.10f), CircleShape)
      .border(PopopxOnboardingHairlineWidth, PopopxBrand.copy(alpha = 0.35f), CircleShape)
      .clickable(onClick = onOpen)
      .padding(horizontal = PopopxOnboardingSpaceS, vertical = PopopxOnboardingSpaceXS),
    horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpace2XS),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Icon(painterResource(icon), null, Modifier.size(14.dp), tint = PopopxBrand)
    Text(title, fontSize = 13.sp, color = popopxOnboardingLabel(), lineHeight = 17.sp)
  }
}

/** Checkbox square + the agreement sentence whose two document titles are the only hit zones that open the reader. */
@Composable
private fun AgreementRow(
  agreed: Boolean,
  onToggle: () -> Unit,
  onOpenLegal: (PopopxLegalDocument) -> Unit,
  modifier: Modifier = Modifier,
) {
  val privacyTitle = stringResource(MR.strings.onboarding_v2_privacy_policy)
  val termsTitle = stringResource(MR.strings.onboarding_v2_terms_of_use)
  val sentence = stringResource(MR.strings.onboarding_v2_legal_agreement_links, privacyTitle, termsTitle)
  val brand = PopopxBrand
  val label = popopxOnboardingLabel()
  val annotated = remember(sentence, privacyTitle, termsTitle) {
    buildAnnotatedString {
      append(sentence)
      listOf(privacyTitle to "privacy", termsTitle to "terms").forEach { (title, tag) ->
        val start = sentence.indexOf(title)
        if (start >= 0) {
          addStyle(SpanStyle(color = brand), start, start + title.length)
          addStringAnnotation("doc", tag, start, start + title.length)
        }
      }
    }
  }
  Row(
    modifier
      .fillMaxWidth()
      .clickable(onClick = onToggle)
      .padding(vertical = PopopxOnboardingSpaceXS),
    horizontalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceS),
    verticalAlignment = Alignment.Top
  ) {
    Box(Modifier.padding(top = 2.dp)) {
      PopopxOnboardingCheckSquare(agreed)
    }
    ClickableText(
      text = annotated,
      style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = label, lineHeight = 22.sp),
      onClick = { offset ->
        val annotation = annotated.getStringAnnotations("doc", offset, offset).firstOrNull()
        when (annotation?.item) {
          "privacy" -> onOpenLegal(PopopxLegalDocument.PRIVACY)
          "terms" -> onOpenLegal(PopopxLegalDocument.TERMS)
          else -> onToggle()
        }
      }
    )
  }
}

enum class PopopxLegalDocument { PRIVACY, TERMS }

/** The offline legal reader: header, effective date, every section, the published address and a secondary close button. */
@Composable
fun PopopxOnboardingLegalModal(document: PopopxLegalDocument, close: () -> Unit) {
  val title = stringResource(
    if (document == PopopxLegalDocument.PRIVACY) MR.strings.onboarding_v2_privacy_policy
    else MR.strings.onboarding_v2_terms_of_use
  )
  val sections: List<Pair<StringResource, StringResource>> =
    if (document == PopopxLegalDocument.PRIVACY) listOf(
      MR.strings.onboarding_v2_legal_privacy_1_title to MR.strings.onboarding_v2_legal_privacy_1_body,
      MR.strings.onboarding_v2_legal_privacy_2_title to MR.strings.onboarding_v2_legal_privacy_2_body,
      MR.strings.onboarding_v2_legal_privacy_3_title to MR.strings.onboarding_v2_legal_privacy_3_body,
      MR.strings.onboarding_v2_legal_privacy_4_title to MR.strings.onboarding_v2_legal_privacy_4_body,
      MR.strings.onboarding_v2_legal_privacy_5_title to MR.strings.onboarding_v2_legal_privacy_5_body,
      MR.strings.onboarding_v2_legal_privacy_6_title to MR.strings.onboarding_v2_legal_privacy_6_body,
      MR.strings.onboarding_v2_legal_privacy_7_title to MR.strings.onboarding_v2_legal_privacy_7_body,
      MR.strings.onboarding_v2_legal_privacy_8_title to MR.strings.onboarding_v2_legal_privacy_8_body,
    ) else listOf(
      MR.strings.onboarding_v2_legal_terms_1_title to MR.strings.onboarding_v2_legal_terms_1_body,
      MR.strings.onboarding_v2_legal_terms_2_title to MR.strings.onboarding_v2_legal_terms_2_body,
      MR.strings.onboarding_v2_legal_terms_3_title to MR.strings.onboarding_v2_legal_terms_3_body,
      MR.strings.onboarding_v2_legal_terms_4_title to MR.strings.onboarding_v2_legal_terms_4_body,
      MR.strings.onboarding_v2_legal_terms_5_title to MR.strings.onboarding_v2_legal_terms_5_body,
      MR.strings.onboarding_v2_legal_terms_6_title to MR.strings.onboarding_v2_legal_terms_6_body,
    )

  ModalView(close = close) {
    Column(Modifier.fillMaxSize().padding(top = AppBarHeight * fontSizeSqrtMultiplier)) {
      ColumnWithScrollBar(Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
        Column(
          Modifier
            .fillMaxWidth()
            .padding(horizontal = PopopxOnboardingGutter)
            .padding(top = PopopxOnboardingSpaceM, bottom = PopopxOnboardingSpaceM),
          verticalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceM)
        ) {
          Column(verticalArrangement = Arrangement.spacedBy(PopopxOnboardingSpaceXS)) {
            Text(title, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = popopxOnboardingLabel(), lineHeight = 28.sp)
            Text(
              stringResource(MR.strings.onboarding_v2_legal_effective),
              fontSize = 15.sp,
              color = popopxOnboardingSecondary(),
              lineHeight = 20.sp
            )
          }
          sections.forEach { (sectionTitle, sectionBody) ->
            Column(verticalArrangement = Arrangement.spacedBy(PopopxOnboardingSpace2XS)) {
              Text(stringResource(sectionTitle), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = popopxOnboardingLabel())
              Text(
                stringResource(sectionBody),
                fontSize = 17.sp,
                color = popopxOnboardingSecondary(),
                lineHeight = 22.sp
              )
            }
          }
          PopopxOnboardingHairline()
          Text(
            stringResource(MR.strings.onboarding_v2_legal_published),
            fontSize = 13.sp,
            color = popopxOnboardingSecondary(),
            lineHeight = 17.sp
          )
        }
      }
      Divider(color = PopopxSeparator, thickness = PopopxOnboardingHairlineWidth)
      Column(Modifier.padding(horizontal = PopopxOnboardingGutter).padding(vertical = PopopxOnboardingSpaceM)) {
        PopopxOnboardingSecondaryButton(
          text = stringResource(MR.strings.onboarding_v2_read_and_close),
          icon = MR.images.ic_check,
          action = close
        )
      }
    }
  }
}