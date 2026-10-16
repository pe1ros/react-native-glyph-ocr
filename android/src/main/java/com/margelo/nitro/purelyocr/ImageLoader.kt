package com.margelo.nitro.purelyocr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import androidx.exifinterface.media.ExifInterface
import java.io.FileInputStream
import java.io.InputStream
import kotlin.math.max

/** Decodes a photo into an upright ARGB_8888 bitmap whose longer side is at most `maxSide`. */
object ImageLoader {
  fun decode(context: Context, uri: String, maxSide: Int): Bitmap {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    open(context, uri).use { BitmapFactory.decodeStream(it, null, bounds) }
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw Error("Cannot read image size: $uri")

    val orientation = open(context, uri).use {
      ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
    }

    // Power-of-two subsampling in the decoder is much cheaper than decoding 12 MP and scaling down.
    var sample = 1
    while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
    val options = BitmapFactory.Options().apply {
      inSampleSize = sample
      inPreferredConfig = Bitmap.Config.ARGB_8888
    }
    val decoded = open(context, uri).use { BitmapFactory.decodeStream(it, null, options) }
      ?: throw Error("Cannot decode image: $uri")

    val matrix = Matrix()
    val longSide = max(decoded.width, decoded.height)
    if (longSide > maxSide) {
      val s = maxSide.toFloat() / longSide
      matrix.postScale(s, s)
    }
    when (orientation) {
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

  private fun open(context: Context, uri: String): InputStream = when {
    uri.startsWith("content://") -> context.contentResolver.openInputStream(Uri.parse(uri))
      ?: throw Error("Cannot open $uri")
    uri.startsWith("file://") -> FileInputStream(Uri.parse(uri).path ?: throw Error("Bad file URI: $uri"))
    else -> FileInputStream(uri)
  }
}
