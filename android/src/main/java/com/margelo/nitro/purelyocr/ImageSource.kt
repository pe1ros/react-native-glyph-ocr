package com.margelo.nitro.purelyocr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Matrix
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.util.Base64
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayInputStream
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.InputStream
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * What the engine reads: the upright ROI of the source, downscaled to `maxImageSide`, plus where
 * it sits in the whole upright image so that results can be mapped back.
 */
internal class EngineInput(
  val bitmap: Bitmap,
  /** The whole upright source. */
  val imageWidth: Int,
  val imageHeight: Int,
  /** The cropped area in whole-image pixels. */
  val crop: RectD,
  val decodeMs: Double,
) {
  private val sx = bitmap.width / crop.w
  private val sy = bitmap.height / crop.h

  fun toImage(x: Double, y: Double) = Pt(crop.x + x / sx, crop.y + y / sy)
}

/** Decodes every source kind into an [EngineInput]. EXIF is applied unless `orientation` overrides it. */
internal object ImageSource {
  const val DEFAULT_MAX_SIDE = 2000

  private fun maxSide(value: Double?): Int = value?.toInt()?.takeIf { it >= 0 } ?: DEFAULT_MAX_SIDE

  /** A path, `file://` or `content://`. */
  fun fromUri(context: Context, uri: String, options: RecognizeOptions): EngineInput {
    when {
      uri.startsWith("ph://") -> throw OcrException("unsupported-source", "ph:// is iOS only", mapOf("uri" to uri))
      uri.startsWith("http://") || uri.startsWith("https://") ->
        throw OcrException("unsupported-source", "Download the image to a file first", mapOf("uri" to uri))
      uri.startsWith("data:") -> throw OcrException("unsupported-source", "Pass data URIs as base64")
    }
    val open = {
      try {
        when {
          uri.startsWith("content://") -> context.contentResolver.openInputStream(Uri.parse(uri))
            ?: throw OcrException("source-not-found", "Cannot open $uri")
          uri.startsWith("file://") -> FileInputStream(Uri.parse(uri).path ?: throw OcrException("unsupported-source", "Bad file URI $uri"))
          uri.startsWith("/") -> FileInputStream(uri)
          else -> throw OcrException("unsupported-source", "Unsupported URI $uri", mapOf("uri" to uri))
        }
      } catch (e: FileNotFoundException) {
        throw OcrException("source-not-found", e.message ?: uri, mapOf("uri" to uri), e)
      } catch (e: SecurityException) {
        throw OcrException("source-permission-denied", e.message ?: uri, mapOf("uri" to uri), e)
      }
    }
    return decodeEncoded(open, null, options)
  }

  fun fromBase64(base64: String, options: RecognizeOptions): EngineInput {
    val bytes = try {
      Base64.decode(base64, Base64.DEFAULT)
    } catch (e: IllegalArgumentException) {
      throw OcrException("decode-failed", "Not base64", cause = e)
    }
    return decodeEncoded({ ByteArrayInputStream(bytes) }, bytes, options)
  }

  private fun decodeEncoded(open: () -> InputStream, bytes: ByteArray?, options: RecognizeOptions): EngineInput {
    val t0 = SystemClock.elapsedRealtimeNanos()
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    open().use { BitmapFactory.decodeStream(it, null, bounds) }
    val rawW = bounds.outWidth
    val rawH = bounds.outHeight
    if (rawW <= 0 || rawH <= 0) throw OcrException("decode-failed", "Not an image, or a corrupt one")
    val exif = options.orientation?.let { Exif.of(it) } ?: open().use {
      try {
        ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
      } catch (e: Exception) {
        ExifInterface.ORIENTATION_NORMAL
      }
    }.coerceIn(1, 8)
    val w = if (Exif.sideways(exif)) rawH else rawW
    val h = if (Exif.sideways(exif)) rawW else rawH
    val crop = Regions.resolve(options.roi, w, h)
    val maxSide = maxSide(options.maxImageSide)
    val bitmap = if (crop == null) {
      decodeWhole(open, rawW, rawH, exif, maxSide)
    } else {
      decodeRegion(open, bytes, rawW, rawH, w, h, exif, crop, maxSide)
        ?: cropOfWhole(open, rawW, rawH, w, h, exif, crop, maxSide)
    }
    return EngineInput(bitmap, w, h, crop ?: RectD(0.0, 0.0, w.toDouble(), h.toDouble()), (SystemClock.elapsedRealtimeNanos() - t0) / 1e6)
  }

  /** The spike's decode: power-of-two subsampling in the decoder, then one scale + EXIF turn. */
  private fun decodeWhole(open: () -> InputStream, rawW: Int, rawH: Int, exif: Int, maxSide: Int): Bitmap {
    val limit = if (maxSide > 0) maxSide else Int.MAX_VALUE
    var sample = 1
    while (max(rawW, rawH) / (sample * 2) >= limit) sample *= 2
    val decoded = open().use {
      BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply {
        inSampleSize = sample
        inPreferredConfig = Bitmap.Config.ARGB_8888
      })
    } ?: throw OcrException("decode-failed", "Cannot decode the image")
    val scale = if (max(decoded.width, decoded.height) > limit) limit.toFloat() / max(decoded.width, decoded.height) else 1f
    return transform(decoded, scale, exif)
  }

  /** Only the ROI, straight from the file. Null when the format has no region decoder. */
  private fun decodeRegion(
    open: () -> InputStream, bytes: ByteArray?, rawW: Int, rawH: Int, w: Int, h: Int, exif: Int, crop: RectD, maxSide: Int,
  ): Bitmap? {
    val raw = Exif.toRaw(exif, w.toDouble(), h.toDouble(), crop)
    val rect = Rect(raw.x.toInt(), raw.y.toInt(), raw.right.roundToInt().coerceAtMost(rawW), raw.bottom.roundToInt().coerceAtMost(rawH))
    val longSide = max(rect.width(), rect.height())
    val target = if (maxSide > 0) min(maxSide, longSide) else longSide
    var sample = 1
    while (longSide / (sample * 2) >= target) sample *= 2
    @Suppress("DEPRECATION")
    val decoder = try {
      if (bytes != null) {
        BitmapRegionDecoder.newInstance(bytes, 0, bytes.size, false)
      } else {
        open().use { BitmapRegionDecoder.newInstance(it, false) }
      }
    } catch (e: Exception) {
      null
    } ?: return null
    val region = try {
      decoder.decodeRegion(rect, BitmapFactory.Options().apply {
        inSampleSize = sample
        inPreferredConfig = Bitmap.Config.ARGB_8888
      })
    } catch (e: Exception) {
      null
    } finally {
      decoder.recycle()
    } ?: return null
    val regionLong = max(region.width, region.height)
    return transform(region, if (regionLong > target) target.toFloat() / regionLong else 1f, exif)
  }

  /** Fallback for formats without a region decoder: decode the whole image at the needed scale, then crop. */
  private fun cropOfWhole(
    open: () -> InputStream, rawW: Int, rawH: Int, w: Int, h: Int, exif: Int, crop: RectD, maxSide: Int,
  ): Bitmap {
    val longCrop = max(crop.w, crop.h)
    val scale = if (maxSide > 0) min(1.0, maxSide / longCrop) else 1.0
    val whole = decodeWhole(open, rawW, rawH, exif, (max(w, h) * scale).roundToInt().coerceAtLeast(1))
    val sx = whole.width.toDouble() / w
    val sy = whole.height.toDouble() / h
    val x = (crop.x * sx).toInt().coerceIn(0, whole.width - 1)
    val y = (crop.y * sy).toInt().coerceIn(0, whole.height - 1)
    val cw = (crop.w * sx).roundToInt().coerceIn(1, whole.width - x)
    val ch = (crop.h * sy).roundToInt().coerceIn(1, whole.height - y)
    val out = Bitmap.createBitmap(whole, x, y, cw, ch)
    if (out !== whole) whole.recycle()
    return out
  }

  /** Scales, then turns the stored pixels upright. */
  private fun transform(decoded: Bitmap, scale: Float, exif: Int): Bitmap {
    val matrix = Matrix()
    if (scale != 1f) matrix.postScale(scale, scale)
    when (exif) {
      ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
      ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
      ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
      ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
      ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
      ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.postRotate(90f); matrix.postScale(-1f, 1f) }
      ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.postRotate(270f); matrix.postScale(-1f, 1f) }
    }
    if (matrix.isIdentity) return decoded
    val result = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
    if (result !== decoded) decoded.recycle()
    return result
  }

  /**
   * Raw pixels, copied into ARGB before the call returns. `orientation` (not EXIF: there is none)
   * says how they are stored; `auto` = upright.
   */
  fun pixelsToArgb(buffer: java.nio.ByteBuffer, width: Int, height: Int, bytesPerRow: Int, format: RawPixelFormat): IntArray {
    val bpp = if (format == RawPixelFormat.RGB || format == RawPixelFormat.BGR) 3 else 4
    if (width <= 0 || height <= 0 || bytesPerRow < width * bpp || buffer.capacity() < bytesPerRow * (height - 1) + width * bpp) {
      throw OcrException("invalid-argument", "Pixel buffer is smaller than ${width}x$height ($format, $bytesPerRow bytes per row)")
    }
    val out = IntArray(width * height)
    for (y in 0 until height) {
      var p = y * bytesPerRow
      for (x in 0 until width) {
        val b0 = buffer.get(p).toInt() and 0xff
        val b1 = buffer.get(p + 1).toInt() and 0xff
        val b2 = buffer.get(p + 2).toInt() and 0xff
        val b3 = if (bpp == 4) buffer.get(p + 3).toInt() and 0xff else 0
        val (r, g, b) = when (format) {
          RawPixelFormat.RGBA, RawPixelFormat.RGB -> Triple(b0, b1, b2)
          RawPixelFormat.BGRA, RawPixelFormat.BGR -> Triple(b2, b1, b0)
          RawPixelFormat.ARGB -> Triple(b1, b2, b3)
          RawPixelFormat.ABGR -> Triple(b3, b2, b1)
        }
        out[y * width + x] = (0xff shl 24) or (r shl 16) or (g shl 8) or b
        p += bpp
      }
    }
    return out
  }

  fun fromArgb(argb: IntArray, width: Int, height: Int, options: RecognizeOptions): EngineInput {
    val t0 = SystemClock.elapsedRealtimeNanos()
    val exif = options.orientation?.let { Exif.of(it) } ?: 1
    val stored = Bitmap.createBitmap(argb, width, height, Bitmap.Config.ARGB_8888)
    val upright = transform(stored, 1f, exif)
    val w = upright.width
    val h = upright.height
    val crop = Regions.resolve(options.roi, w, h)
    val area = crop ?: RectD(0.0, 0.0, w.toDouble(), h.toDouble())
    val maxSide = maxSide(options.maxImageSide)
    val longSide = max(area.w, area.h)
    val scale = if (maxSide in 1 until longSide.toInt()) maxSide / longSide else 1.0
    val matrix = Matrix().apply { if (scale != 1.0) postScale(scale.toFloat(), scale.toFloat()) }
    val bitmap = Bitmap.createBitmap(upright, area.x.toInt(), area.y.toInt(), area.w.toInt(), area.h.toInt(), matrix, true)
    if (bitmap !== upright) upright.recycle()
    return EngineInput(bitmap, w, h, area, (SystemClock.elapsedRealtimeNanos() - t0) / 1e6)
  }

  /** A VisionCamera frame: an `AHardwareBuffer*` read on the CPU (API 29+). */
  fun fromFrame(pointer: Long, orientation: FrameOrientation, mirrored: Boolean, roi: OcrRect?, maxImageSide: Double?): EngineInput {
    val t0 = SystemClock.elapsedRealtimeNanos()
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
      throw OcrException("frame-unsupported", "Camera frames need Android 10 (API 29)")
    }
    if (pointer == 0L) throw OcrException("frame-unsupported", "Null buffer pointer")
    val desc = FrameBuffers.describe(pointer)
    if (desc.size < 3) throw OcrException("frame-unsupported", "AHardwareBuffer API is not available")
    val exif = Exif.of(orientation, mirrored)
    val w = if (Exif.sideways(exif)) desc[1] else desc[0]
    val h = if (Exif.sideways(exif)) desc[0] else desc[1]
    val area = Regions.resolve(roi, w, h) ?: RectD(0.0, 0.0, w.toDouble(), h.toDouble())
    val maxSide = maxSide(maxImageSide)
    val longSide = max(area.w, area.h)
    val scale = if (maxSide in 1 until longSide.toInt()) maxSide / longSide else 1.0
    val outW = (area.w * scale).roundToInt().coerceAtLeast(1)
    val outH = (area.h * scale).roundToInt().coerceAtLeast(1)
    val argb = IntArray(outW * outH)
    val status = FrameBuffers.readArgb(
      pointer, exif, area.x.toFloat(), area.y.toFloat(), area.w.toFloat(), area.h.toFloat(), outW, outH, argb,
    )
    FrameBuffers.check(status, desc[2])
    val bitmap = Bitmap.createBitmap(argb, outW, outH, Bitmap.Config.ARGB_8888)
    return EngineInput(bitmap, w, h, area, (SystemClock.elapsedRealtimeNanos() - t0) / 1e6)
  }
}
