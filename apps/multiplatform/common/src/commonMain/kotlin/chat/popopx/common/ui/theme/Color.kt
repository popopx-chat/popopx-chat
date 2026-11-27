package chat.popopx.common.ui.theme

import androidx.compose.material.LocalContentColor
import androidx.compose.material.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.colorspace.ColorSpaces
import kotlin.math.cos
import kotlin.math.sin

fun oklch(L: Float, C: Float, H: Float, alpha: Float = 1f): Color {
  val hRad = H * (Math.PI.toFloat() / 180f)
  return Color(L, C * cos(hRad), C * sin(hRad), alpha, ColorSpaces.Oklab)
}

val Indigo = Color(0xFF9966FF)
val PopopxBlue = Color(0, 136, 255, 255)  // If this value changes also need to update #0088ff in string resource files
val PopopxGreen = Color(77, 218, 103, 255)
val SecretColor = Color(0x40808080)
val LightGray = Color(241, 242, 246, 255)
val DarkGray = Color(43, 44, 46, 255)
val HighOrLowlight = Color(139, 135, 134, 255)
val MessagePreviewDark = Color(179, 175, 174, 255)
val MessagePreviewLight = Color(49, 45, 44, 255)
val ToolbarLight = Color(220, 220, 220, 12)
val ToolbarDark = Color(80, 80, 80, 12)
val SettingsSecondaryLight = Color(200, 196, 195, 90)
val GroupDark = Color(80, 80, 80, 60)
val IncomingCallLight = Color(239, 237, 236, 255)
val WarningOrange = Color(255, 127, 0, 255)
val WarningYellow = Color(255, 192, 0, 255)
val FileLight = Color(191, 194, 199, 255)
val FileDark = Color(94, 94, 98, 255)

val MenuTextColor: Color @Composable get () = if (isInDarkTheme()) LocalContentColor.current.copy(alpha = 0.8f) else Color.Black
val NoteFolderIconColor: Color @Composable get() = MaterialTheme.appColors.primaryVariant2

// Semantic colours the iOS surface spec defines and Material 1's ColorPalette does not carry, ported
// from PopopxPalette (apps/ios/Shared/Theme/PopopxTheme.swift:76-129): the row separator, the hairline
// hint an outlined control strokes itself with, and the mesh / success inks a card's state line uses.
// A card reads these instead of inventing a per-surface alpha.
val PopopxSeparator: Color @Composable get() = MaterialTheme.colors.onSurface.copy(alpha = 0.12f)
val PopopxLabelHint: Color @Composable get() = MaterialTheme.colors.onSurface.copy(alpha = 0.40f)
val PopopxMesh: Color @Composable get() = if (isInDarkTheme()) Color(0xFF00D2B8) else Color(0xFF00A896)
val PopopxOnMesh: Color @Composable get() = if (isInDarkTheme()) Color(0xFF00211C) else Color(0xFF00251F)
val PopopxMeshInk: Color @Composable get() = if (isInDarkTheme()) Color(0xFF00D2B8) else Color(0xFF00705F)
val PopopxSuccessInk: Color @Composable get() = if (isInDarkTheme()) Color(0xFF30D158) else Color(0xFF1E7A34)

// The brand fill and the two inks a filled badge needs. The navy is the one the tab bar and the QR
// codes already carry (views/tabs/PopopxMainTabView.kt, views/newchat/QRCode.kt), lifted on dark so
// the same hue stays legible on an OLED surface.
val PopopxBrand: Color @Composable get() = if (isInDarkTheme()) Color(0xFF7FB0E8) else Color(0xFF062D56)
val PopopxOnBrand: Color @Composable get() = if (isInDarkTheme()) Color(0xFF0A0A1F) else Color(0xFFFFFFFF)
val PopopxDangerFill: Color @Composable get() = if (isInDarkTheme()) Color(0xFFFF453A) else Color(0xFFD70015)
val PopopxOnDanger: Color @Composable get() = Color(0xFFFFFFFF)
val PopopxSuccess: Color @Composable get() = if (isInDarkTheme()) Color(0xFF30D158) else Color(0xFF34C759)
val PopopxOnSuccess: Color @Composable get() = Color(0xFFFFFFFF)
val PopopxHairlineInner: Color @Composable get() = MaterialTheme.colors.onSurface.copy(alpha = 0.10f)
