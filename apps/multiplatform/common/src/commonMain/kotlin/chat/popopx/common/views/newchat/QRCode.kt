package chat.popopx.common.views.newchat

import androidx.compose.desktop.ui.tooling.preview.Preview
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.*
import androidx.compose.ui.platform.*
import androidx.compose.ui.unit.dp
import dev.icerock.moko.resources.compose.stringResource
import boofcv.alg.drawing.FiducialImageEngine
import boofcv.alg.fiducial.qrcode.*
import chat.popopx.common.invite.PopopxInviteShareForm
import chat.popopx.common.model.*
import chat.popopx.common.platform.*
import chat.popopx.common.ui.theme.*
import chat.popopx.common.views.helpers.*
import chat.popopx.res.*
import kotlinx.coroutines.launch

@Composable
fun POPOPXCreatedLinkQRCode(
  connLink: CreatedConnLink,
  short: Boolean,
  // When set, the code encodes this instead of the link's own URI: the sealed /i/v1/ form the screen
  // prints as text right above it. A QR that disagrees with the text beside it is worse than either one
  // alone.
  encodedURI: String? = null,
  modifier: Modifier = Modifier,
  padding: PaddingValues = PaddingValues(horizontal = DEFAULT_PADDING * 2f, vertical = DEFAULT_PADDING_HALF),
  tintColor: Color = Color(0xff062d56),
  withLogo: Boolean = true,
  onShare: (() -> Unit)? = null,
) {
  // A screen that passes no encodedURI still gets a share: this view is only ever handed connection
  // addresses, so the default is the sealed form of the selected link. `small` is decided by the
  // string actually encoded - the sealed code is longer than the address it hides, so the compact,
  // error-level-M rendering is wrong for it even when the user picked the short link.
  val uri = encodedURI ?: PopopxInviteShareForm.make(connLink, short).display
  QRCode(
    uri,
    small = uri.length < 200,
    modifier,
    padding,
    tintColor,
    withLogo,
    onShare,
  )
}

@Composable
fun POPOPXLinkQRCode(
  connReq: String,
  modifier: Modifier = Modifier,
  padding: PaddingValues = PaddingValues(horizontal = DEFAULT_PADDING * 2f, vertical = DEFAULT_PADDING_HALF),
  tintColor: Color = Color(0xff062d56),
  withLogo: Boolean = true,
  onShare: (() -> Unit)? = null,
) {
  QRCode(
    popopxChatLink(connReq),
    small = connReq.count() < 200,
    modifier,
    padding,
    tintColor,
    withLogo,
    onShare,
  )
}

val LocalFixedQRCode = staticCompositionLocalOf<ImageBitmap?> { null }

@Composable
fun QRCode(
  connReq: String,
  small: Boolean = false,
  modifier: Modifier = Modifier,
  padding: PaddingValues = PaddingValues(horizontal = DEFAULT_PADDING * 2f, vertical = DEFAULT_PADDING_HALF),
  tintColor: Color = Color(0xff062d56),
  withLogo: Boolean = true,
  onShare: (() -> Unit)? = null,
) {
  val scope = rememberCoroutineScope()
  val logoSize = if (small) 0.21f else 0.16f
  val errorLevel = if (small) QrCode.ErrorLevel.M else QrCode.ErrorLevel.L
  val fixedQRCode = LocalFixedQRCode.current
  val qr = remember(connReq, tintColor, withLogo) {
    (fixedQRCode ?: qrCodeBitmap(connReq, 1024, errorLevel)).replaceColor(Color.Black.toArgb(), tintColor.toArgb())
      .let { if (withLogo) it.addLogo(logoSize) else it }
  }
  Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
    Image(
      bitmap = qr,
      contentDescription = stringResource(MR.strings.image_descr_qr_code),
      Modifier
        .padding(padding)
        .widthIn(max = 400.dp)
        .fillMaxWidth(if (small) 0.63f else 1f)
        .aspectRatio(1f)
        .then(modifier)
        .clickable {
          scope.launch {
            val image = qrCodeBitmap(connReq, 1024, errorLevel).replaceColor(Color.Black.toArgb(), tintColor.toArgb())
              .let { if (withLogo) it.addLogo(logoSize) else it }
            val file = saveTempImageUncompressed(image, true)
            if (file != null) {
              shareFile("", CryptoFile.plain(file.absolutePath))
              onShare?.invoke()
            }
          }
        }
    )
  }
}

fun qrCodeBitmap(content: String, size: Int = 1024, errorLevel: QrCode.ErrorLevel): ImageBitmap {
  val qrCode = QrCodeEncoder().addAutomatic(content).setError(errorLevel).fixate()
  /** See [QrCodeGeneratorImage.initialize] and [FiducialImageEngine.configure] for size calculation */
  val numModules = QrCode.totalModules(qrCode.version)
  // Hide border on light themes to make it fit to the same place as camera in QRCodeScanner.
  // On dark themes better to show the border
  val borderModule = if (CurrentColors.value.colors.isLight) 0 else 1
  // val calculatedFinalWidth = (pixelsPerModule * numModules) + 2 * (borderModule * pixelsPerModule)
  // size = (x * numModules) + 2 * (borderModule * x)
  // size / x = numModules + 2 * borderModule
  // x = size / (numModules + 2 * borderModule)
  val pixelsPerModule = size / (numModules + 2 * borderModule)
  // + 1 to make it with better quality
  val renderer = QrCodeGeneratorImage(pixelsPerModule + 1)
  renderer.borderModule = borderModule
  renderer.render(qrCode)
  return renderer.gray.toImageBitmap().scale(size, size)
}

expect fun ImageBitmap.replaceColor(from: Int, to: Int): ImageBitmap

@Preview
@Composable
fun PreviewQRCode() {
  POPOPXTheme {
    QRCode(connReq = "https://smp6.simplex.im/a#lrdvu2d8A1GumSmoKb2krQmtKhWXq-tyGpHuM7aMwsw", small = true)
  }
}
