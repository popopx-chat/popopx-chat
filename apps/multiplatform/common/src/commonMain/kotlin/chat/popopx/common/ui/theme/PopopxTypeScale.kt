package chat.popopx.common.ui.theme

import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.sp

// The semantic ladder behind the 27-locale UI: display/title/headline/body/callout/caption.
// Line heights are deliberately generous so Arabic and Persian diacritics do not clip.
// `metric` and `code` are the machine-value isolation styles: tabular figures, forced LTR, so a
// user id or a link never reorders inside an RTL sentence.

object PopopxTypeScale {
  val display = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 34.sp, lineHeight = 40.sp, letterSpacing = (-0.4).sp)
  val title1 = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 28.sp, lineHeight = 34.sp, letterSpacing = (-0.3).sp)
  val title2 = TextStyle(fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, lineHeight = 29.sp, letterSpacing = (-0.2).sp)
  val headline = TextStyle(fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, lineHeight = 23.sp)
  val body = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Normal, fontSize = 16.sp, lineHeight = 23.sp)
  val callout = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Normal, fontSize = 15.sp, lineHeight = 21.sp)
  val calloutSmall = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 20.sp)
  val subheadline = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Normal, fontSize = 13.sp, lineHeight = 19.sp)
  val caption = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 17.sp)
  val overline = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 11.sp, lineHeight = 15.sp, letterSpacing = 0.6.sp)
  val micro = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 10.sp, lineHeight = 13.sp)

  val metric = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 13.sp, lineHeight = 17.sp, fontFeatureSettings = "tnum", textDirection = TextDirection.Ltr)
  val metricSmall = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 11.sp, lineHeight = 15.sp, fontFeatureSettings = "tnum", textDirection = TextDirection.Ltr)
  val code = TextStyle(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 17.sp, textDirection = TextDirection.Ltr)
  val codeSmall = TextStyle(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Normal, fontSize = 11.sp, lineHeight = 15.sp, textDirection = TextDirection.Ltr)
}