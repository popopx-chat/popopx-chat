package chat.popopx.common.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.media.ExifInterface
import java.io.File
import java.io.FileOutputStream

// The image half of the Android platform layer under `PopopxMediaEngineCore`.
//
// iOS uses ImageIO; the equivalent here is BitmapFactory plus a JPEG encode, and as on iOS the metadata is not
// deleted afterwards so much as never written: the output is a new stream of pixels. The orientation tag is
// therefore applied to the pixels before encoding, because nothing in the output carries it any more.
//
// HEIC decodes only from API 28. Below it the decode returns null, the engine declines, and the original file goes
// out as it does today — recorded as a deviation rather than papered over with a partial rewrite.

internal actual fun popopxEncodeImage(
  source: File,
  destination: File,
  maxDimensionInPixels: Int,
  qualityPercent: Int,
): PopopxMediaEngineError? {
  val path = source.absolutePath
  val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
  BitmapFactory.decodeFile(path, bounds)
  val width = bounds.outWidth
  val height = bounds.outHeight
  if (width <= 0 || height <= 0) return PopopxMediaEngineError.IMAGE_DECODE_FAILED

  val decoded = BitmapFactory.decodeFile(
    path,
    BitmapFactory.Options().apply {
      inSampleSize = popopxSampleSizeFor(maxOf(width, height), maxDimensionInPixels)
      inPreferredConfig = Bitmap.Config.ARGB_8888
    }
  ) ?: return PopopxMediaEngineError.IMAGE_DECODE_FAILED

  val matrix = Matrix()
  popopxApplyOrientation(matrix, popopxExifOrientation(path))
  val scale = minOf(1f, maxDimensionInPixels.toFloat() / maxOf(1, maxOf(decoded.width, decoded.height)))
  matrix.postScale(scale, scale)
  val target = RectF(0f, 0f, decoded.width.toFloat(), decoded.height.toFloat())
  matrix.mapRect(target)
  val outWidth = target.width().toInt().coerceAtLeast(1)
  val outHeight = target.height().toInt().coerceAtLeast(1)

  // iOS always writes a JPEG, so transparency is composited onto white instead of being kept or dropped silently.
  val canvasBitmap = Bitmap.createBitmap(outWidth, outHeight, Bitmap.Config.ARGB_8888)
  val canvas = Canvas(canvasBitmap)
  canvas.drawColor(Color.WHITE)
  canvas.drawBitmap(decoded, matrix, Paint(Paint.FILTER_BITMAP_FLAG))
  decoded.recycle()

  var written = false
  try {
    FileOutputStream(destination).use { stream ->
      written = canvasBitmap.compress(Bitmap.CompressFormat.JPEG, qualityPercent, stream)
      stream.flush()
    }
  } catch (e: Exception) {
    written = false
  } finally {
    canvasBitmap.recycle()
  }
  if (!written || destination.length() <= 0L) {
    destination.delete()
    return PopopxMediaEngineError.IMAGE_ENCODE_FAILED
  }
  // The insurance policy: if a device encoder ever starts writing a camera block, this removes it.
  PopopxJpegMetadata.stripFromFile(destination)
  return null
}

/** Powers of two, so the decoder never allocates more than twice the pixels the encoder will keep. */
internal fun popopxSampleSizeFor(longEdge: Int, maxDimensionInPixels: Int): Int {
  var size = 1
  while (longEdge / (size * 2) >= maxDimensionInPixels && size < 32) size *= 2
  return size
}

private fun popopxExifOrientation(path: String): Int = try {
  ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
} catch (e: Exception) {
  ExifInterface.ORIENTATION_NORMAL
}

/** Orientation 2..8 folded into the pixel transform. 1 and an unreadable value leave the matrix alone. */
private fun popopxApplyOrientation(matrix: Matrix, orientation: Int) {
  when (orientation) {
    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
    ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
    ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
      matrix.postScale(-1f, 1f)
      matrix.postRotate(180f)
    }
    ExifInterface.ORIENTATION_TRANSPOSE -> {
      matrix.postScale(-1f, 1f)
      matrix.postRotate(270f)
    }
    ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
    ExifInterface.ORIENTATION_TRANSVERSE -> {
      matrix.postScale(-1f, 1f)
      matrix.postRotate(90f)
    }
    ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
  }
}
