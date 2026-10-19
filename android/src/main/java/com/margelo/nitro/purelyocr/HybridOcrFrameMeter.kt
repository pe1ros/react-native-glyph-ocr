package com.margelo.nitro.purelyocr

import android.os.Build
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Focus, motion and light of the ROI on a small luma grid. The same arithmetic is in
 * ios/HybridOcrFrameMeter.swift (FrameMetrics), so thresholds mean the same on both platforms.
 */
internal object FrameMetrics {
  /** Longer side of the luma grid, px. */
  const val GRID = 256

  fun gridSize(w: Double, h: Double): Pair<Int, Int> {
    val long = min(GRID.toDouble(), max(w, h))
    val gw = max(3, (w / max(w, h) * long).roundToInt())
    val gh = max(3, (h / max(w, h) * long).roundToInt())
    return Pair(gw, gh)
  }

  /** `luma` is gw x gh values 0..255; `previous` is the last grid of the same meter. */
  fun measure(luma: FloatArray, gw: Int, gh: Int, previous: FloatArray?): FrameQuality {
    var sum = 0.0
    for (v in luma) sum += v
    val brightness = sum / luma.size / 255.0
    // Variance of the 4-neighbour Laplacian over the inner cells.
    var n = 0
    var s1 = 0.0
    var s2 = 0.0
    for (y in 1 until gh - 1) {
      for (x in 1 until gw - 1) {
        val i = y * gw + x
        val lap = (4 * luma[i] - luma[i - 1] - luma[i + 1] - luma[i - gw] - luma[i + gw]).toDouble()
        s1 += lap
        s2 += lap * lap
        n++
      }
    }
    val mean = if (n > 0) s1 / n else 0.0
    val sharpness = if (n > 0) s2 / n - mean * mean else 0.0
    val motion = if (previous == null || previous.size != luma.size) {
      1.0
    } else {
      var d = 0.0
      for (i in luma.indices) d += abs(luma[i] - previous[i])
      d / luma.size / 255.0
    }
    return FrameQuality(sharpness, motion, brightness)
  }
}

class HybridOcrFrameMeter : HybridOcrFrameMeterSpec() {
  private var previous: FloatArray? = null

  @Synchronized
  override fun measure(nativeBufferPointer: ULong, orientation: FrameOrientation, roi: OcrRect?): FrameQuality {
    try {
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
        throw OcrException("frame-unsupported", "Camera frames need Android 10 (API 29)")
      }
      val pointer = nativeBufferPointer.toLong()
      if (pointer == 0L) throw OcrException("frame-unsupported", "Null buffer pointer")
      val desc = FrameBuffers.describe(pointer)
      if (desc.size < 3) throw OcrException("frame-unsupported", "AHardwareBuffer API is not available")
      val exif = Exif.of(orientation, false)
      val w = if (Exif.sideways(exif)) desc[1] else desc[0]
      val h = if (Exif.sideways(exif)) desc[0] else desc[1]
      val area = Regions.resolve(roi, w, h) ?: RectD(0.0, 0.0, w.toDouble(), h.toDouble())
      val (gw, gh) = FrameMetrics.gridSize(area.w, area.h)
      val grid = FloatArray(gw * gh)
      FrameBuffers.check(
        FrameBuffers.readLuma(pointer, exif, area.x.toFloat(), area.y.toFloat(), area.w.toFloat(), area.h.toFloat(), gw, gh, grid),
        desc[2],
      )
      val quality = FrameMetrics.measure(grid, gw, gh, previous)
      previous = grid
      return quality
    } catch (t: Throwable) {
      throw OcrException.wrap(t)
    }
  }

  @Synchronized
  override fun reset() {
    previous = null
  }
}
