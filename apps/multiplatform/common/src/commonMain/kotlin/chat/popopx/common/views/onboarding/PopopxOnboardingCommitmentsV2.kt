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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
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
                .padding(horizontal = PopopxSpace.m)
                .padding(top = PopopxSpace.s)
                .padding(bottom = PopopxSpace.m),
              verticalArrangement = Arrangement.spacedBy(if (compact) PopopxSpace.s else PopopxSpace.l)
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
                Row(horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xs)) {
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
                  modifier = Modifier.padding(top = if (compact) PopopxSpace.xxs else PopopxSpace.xs)
                )
              }
            }
          }
          Divider(color = PopopxSeparator, thickness = PopopxSize.hairline)
          PopopxOnboardingBottomBar {
            if (!commitmentsMet) {
              Text(
                stringResource(MR.strings.onboarding_v2_commitments_required),
                style = PopopxTypeScale.subheadline,
                color = popopxOnboardingSecondary()
              )
            } else if (!agreed) {
              Text(
                stringResource(MR.strings.onboarding_v2_legal_required),
                style = PopopxTypeScale.subheadline,
                color = popopxOnboardingSecondary()
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
      .padding(vertical = if (compact) PopopxSpace.xxs else PopopxSpace.xs)
      .background(
        if (checked) PopopxBrand.copy(alpha = 0.08f) else Color.Transparent,
        RoundedCornerShape(PopopxRadiusControl)
      )
      .border(
        if (checked) PopopxSize.stroke else PopopxSize.hairline,
        if (checked) PopopxBrand else PopopxHairlineInner,
        RoundedCornerShape(PopopxRadiusControl)
      )
      .clickable(onClick = onToggle)
      .padding(
        horizontal = PopopxSpace.xs,
        vertical = if (compact) PopopxSpace.xxs else PopopxSpace.s
      ),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.s),
    verticalAlignment = Alignment.Top
  ) {
    Text(
      title,
      style = PopopxTypeScale.headline,
      color = if (checked) PopopxBrand else popopxOnboardingLabel(),
      modifier = Modifier.weight(1f)
    )
    Spacer(Modifier.width(PopopxSpace.xs))
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
      .heightIn(min = PopopxSize.control)
      .background(PopopxBrand.copy(alpha = 0.10f), CircleShape)
      .border(PopopxSize.hairline, PopopxBrand.copy(alpha = PopopxAlpha.hint), CircleShape)
      .clickable(onClick = onOpen)
      .padding(horizontal = PopopxSpace.s, vertical = PopopxSpace.xs),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.xxs),
    verticalAlignment = Alignment.CenterVertically
  ) {
    Icon(painterResource(icon), null, Modifier.size(PopopxSize.iconS), tint = PopopxBrand)
    Text(title, style = PopopxTypeScale.subheadline, color = popopxOnboardingLabel())
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
      .padding(vertical = PopopxSpace.xs),
    horizontalArrangement = Arrangement.spacedBy(PopopxSpace.s),
    verticalAlignment = Alignment.Top
  ) {
    Box(Modifier.padding(top = 2.dp)) {
      PopopxOnboardingCheckSquare(agreed)
    }
    ClickableText(
      text = annotated,
      style = PopopxTypeScale.headline.copy(color = label),
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
            .padding(horizontal = PopopxSpace.m)
            .padding(top = PopopxSpace.m, bottom = PopopxSpace.m),
          verticalArrangement = Arrangement.spacedBy(PopopxSpace.m)
        ) {
          Column(verticalArrangement = Arrangement.spacedBy(PopopxSpace.xs)) {
            Text(title, style = PopopxTypeScale.title2, color = popopxOnboardingLabel())
            Text(
              stringResource(MR.strings.onboarding_v2_legal_effective),
              style = PopopxTypeScale.callout,
              color = popopxOnboardingSecondary()
            )
          }
          sections.forEach { (sectionTitle, sectionBody) ->
            Column(verticalArrangement = Arrangement.spacedBy(PopopxSpace.xxs)) {
              Text(stringResource(sectionTitle), style = PopopxTypeScale.headline, color = popopxOnboardingLabel())
              Text(
                stringResource(sectionBody),
                style = PopopxTypeScale.headline.copy(fontWeight = FontWeight.Normal),
                color = popopxOnboardingSecondary()
              )
            }
          }
          PopopxOnboardingHairline()
          Text(
            stringResource(MR.strings.onboarding_v2_legal_published),
            style = PopopxTypeScale.subheadline,
            color = popopxOnboardingSecondary()
          )
        }
      }
      Divider(color = PopopxSeparator, thickness = PopopxSize.hairline)
      Column(Modifier.padding(horizontal = PopopxSpace.m).padding(vertical = PopopxSpace.m)) {
        PopopxOnboardingSecondaryButton(
          text = stringResource(MR.strings.onboarding_v2_read_and_close),
          icon = MR.images.ic_check,
          action = close
        )
      }
    }
  }
}