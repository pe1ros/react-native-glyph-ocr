package com.margelo.nitro.glyphocr.paddle

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.withSign

/**
 * A text line found on the DB probability map, described as a sampler: a point (u, v) in the
 * line's own frame (u along the text, v across it, map px) maps to the source image.
 *
 * Straight lines are a rotated rectangle. Curved lines (labels on cans and bottles) keep a
 * smoothed centerline v = center(u), so the crop follows the curve instead of cutting
 * through neighbouring lines.
 */
class TextLine(
  private val cx: Float,
  private val cy: Float,
  private val cos: Float,
  private val sin: Float,
  val u0: Float,
  val u1: Float,
  private val binOrigin: Float,
  private val centers: FloatArray?,
  private val centerConst: Float,
  val halfHeight: Float,
  private val scaleX: Float,
  private val scaleY: Float,
  val vertical: Boolean,
) {
  fun centerAt(u: Float): Float {
    val c = centers ?: return centerConst
    val i = floor(u - binOrigin).toInt().coerceIn(0, c.size - 1)
    return c[i]
  }

  fun srcX(u: Float, v: Float): Float = (cx + u * cos - v * sin) * scaleX
  fun srcY(u: Float, v: Float): Float = (cy + u * sin + v * cos) * scaleY

  /**
   * A point on the text's top (`top`) or bottom edge at `share` (0..1) of its length, in source px.
   * "Top" is the top of the text as the recognizer reads it (see PaddleOcr.sampleLine).
   */
  fun edgePoint(share: Float, top: Boolean): Pair<Float, Float> {
    val u = u0 + share * (u1 - u0)
    val c = centerAt(u)
    val v = if (vertical == top) c + halfHeight else c - halfHeight
    return Pair(srcX(u, v), srcY(u, v))
  }

  /**
   * The same line read the other way: turned 180°, for upside-down text. A point (u, v) of the
   * turned line is (-u, -v) of this one, so the sampler and the corners follow the turned text.
   */
  fun flipped(): TextLine = TextLine(
    cx = cx, cy = cy, cos = -cos, sin = -sin,
    u0 = -u1, u1 = -u0,
    binOrigin = if (centers == null) binOrigin else -(binOrigin + centers.size),
    centers = centers?.let { c -> FloatArray(c.size) { -c[c.size - 1 - it] } },
    centerConst = -centerConst,
    halfHeight = halfHeight, scaleX = scaleX, scaleY = scaleY, vertical = vertical,
  )

  /** Length along the text and height across it, in source px. */
  val lengthSrc: Float get() = (u1 - u0) * scaleX
  val heightSrc: Float get() = 2 * halfHeight * scaleY
}

/** DB post-processing: probability map -> text lines. Mirrors PaddleOCR's DBPostProcess thresholds. */
object TextLineFinder {
  private const val MIN_SIZE = 3f
  private const val MAX_CANDIDATES = 1000

  fun find(
    prob: FloatArray,
    mapW: Int,
    mapH: Int,
    srcW: Int,
    srcH: Int,
    thresh: Float,
    boxThresh: Float,
    unclipRatio: Float,
  ): List<TextLine> {
    val n = mapW * mapH
    val visited = BooleanArray(n)
    val queue = IntArray(n)
    val scaleX = srcW.toFloat() / mapW
    val scaleY = srcH.toFloat() / mapH
    val lines = ArrayList<TextLine>()
    var candidates = 0

    for (seed in 0 until n) {
      if (visited[seed] || prob[seed] <= thresh) continue
      // 8-connected flood fill; the component's pixels end up in queue[0 until size].
      var head = 0
      var size = 0
      queue[size++] = seed
      visited[seed] = true
      while (head < size) {
        val p = queue[head++]
        val px = p % mapW
        val py = p / mapW
        for (dy in -1..1) {
          val y = py + dy
          if (y < 0 || y >= mapH) continue
          for (dx in -1..1) {
            val x = px + dx
            if (x < 0 || x >= mapW) continue
            val q = y * mapW + x
            if (!visited[q] && prob[q] > thresh) {
              visited[q] = true
              queue[size++] = q
            }
          }
        }
      }
      if (size < MIN_SIZE * MIN_SIZE) continue
      if (++candidates > MAX_CANDIDATES) break
      analyze(queue, size, prob, mapW, boxThresh, unclipRatio, scaleX, scaleY)?.let { lines.add(it) }
    }
    return lines
  }

  private fun analyze(
    pixels: IntArray,
    size: Int,
    prob: FloatArray,
    mapW: Int,
    boxThresh: Float,
    unclipRatio: Float,
    scaleX: Float,
    scaleY: Float,
  ): TextLine? {
    // Score: mean probability over the component (PaddleOCR's "slow" score mode). The "fast"
    // mode averages over the bounding rectangle and drops curved lines.
    var sumP = 0.0
    var sumX = 0.0
    var sumY = 0.0
    for (k in 0 until size) {
      val p = pixels[k]
      sumP += prob[p]
      sumX += p % mapW
      sumY += p / mapW
    }
    if (sumP / size < boxThresh) return null
    val cx = (sumX / size).toFloat()
    val cy = (sumY / size).toFloat()

    // Main axis from the covariance of pixel coordinates.
    var cxx = 0.0
    var cyy = 0.0
    var cxy = 0.0
    for (k in 0 until size) {
      val p = pixels[k]
      val dx = p % mapW - cx
      val dy = p / mapW - cy
      cxx += dx * dx
      cyy += dy * dy
      cxy += dx * dy
    }
    var theta = 0.5 * atan2(2 * cxy, cxx - cyy)
    var vertical = false
    if (abs(theta) > PI / 4) {
      val (l, t) = extents(pixels, size, mapW, cx, cy, theta)
      if (l >= 1.5f * t) {
        vertical = true
        // u must point down the image so that the crop reads like PaddleOCR's rot90 crop.
        if (sin(theta) < 0) theta += PI
      } else {
        theta -= (PI / 2).withSign(theta)
      }
    }
    val c = cos(theta).toFloat()
    val s = sin(theta).toFloat()

    var umin = Float.MAX_VALUE
    var umax = -Float.MAX_VALUE
    var vmin = Float.MAX_VALUE
    var vmax = -Float.MAX_VALUE
    for (k in 0 until size) {
      val p = pixels[k]
      val dx = p % mapW - cx
      val dy = p / mapW - cy
      val u = dx * c + dy * s
      val v = -dx * s + dy * c
      if (u < umin) umin = u
      if (u > umax) umax = u
      if (v < vmin) vmin = v
      if (v > vmax) vmax = v
    }
    val len = umax - umin + 1
    val thick = vmax - vmin + 1
    if (min(len, thick) < MIN_SIZE) return null

    // Per-column profile across the text: local thickness and centerline.
    val bins = floor(umax - umin).toInt() + 1
    val lo = FloatArray(bins) { Float.MAX_VALUE }
    val hi = FloatArray(bins) { -Float.MAX_VALUE }
    for (k in 0 until size) {
      val p = pixels[k]
      val dx = p % mapW - cx
      val dy = p / mapW - cy
      val u = dx * c + dy * s
      val v = -dx * s + dy * c
      val b = floor(u - umin).toInt().coerceIn(0, bins - 1)
      if (v < lo[b]) lo[b] = v
      if (v > hi[b]) hi[b] = v
    }
    var filled = 0
    var sumT = 0f
    for (b in 0 until bins) {
      if (lo[b] <= hi[b]) {
        filled++
        sumT += hi[b] - lo[b] + 1
      }
    }
    val colThick = sumT / max(1, filled)

    val curved = !vertical && thick > 1.3f * colThick && len > 4 * colThick
    val centers: FloatArray?
    val d: Float
    val halfHeight: Float
    if (curved) {
      centers = smoothedCenterline(lo, hi, max(3, colThick.roundToInt()))
      d = len * colThick * unclipRatio / (2 * (len + colThick))
      halfHeight = colThick / 2 + d
    } else {
      centers = null
      // Unclip like PaddleOCR: grow the rectangle by area * ratio / perimeter on every side.
      d = len * thick * unclipRatio / (2 * (len + thick))
      halfHeight = thick / 2 + d
    }
    if (2 * halfHeight < MIN_SIZE + 2) return null

    return TextLine(
      cx = cx, cy = cy, cos = c, sin = s,
      u0 = umin - d, u1 = umax + d,
      binOrigin = umin, centers = centers, centerConst = (vmin + vmax) / 2,
      halfHeight = halfHeight, scaleX = scaleX, scaleY = scaleY, vertical = vertical,
    )
  }

  private fun extents(pixels: IntArray, size: Int, mapW: Int, cx: Float, cy: Float, theta: Double): Pair<Float, Float> {
    val c = cos(theta).toFloat()
    val s = sin(theta).toFloat()
    var umin = Float.MAX_VALUE
    var umax = -Float.MAX_VALUE
    var vmin = Float.MAX_VALUE
    var vmax = -Float.MAX_VALUE
    for (k in 0 until size) {
      val p = pixels[k]
      val dx = p % mapW - cx
      val dy = p / mapW - cy
      val u = dx * c + dy * s
      val v = -dx * s + dy * c
      umin = min(umin, u); umax = max(umax, u)
      vmin = min(vmin, v); vmax = max(vmax, v)
    }
    return Pair(umax - umin + 1, vmax - vmin + 1)
  }

  /** Column midpoints, gaps linearly interpolated, then a moving average of `window` columns. */
  private fun smoothedCenterline(lo: FloatArray, hi: FloatArray, window: Int): FloatArray {
    val n = lo.size
    val mid = FloatArray(n) { Float.NaN }
    for (b in 0 until n) if (lo[b] <= hi[b]) mid[b] = (lo[b] + hi[b]) / 2
    var prev = -1
    for (b in 0 until n) {
      if (mid[b].isNaN()) continue
      if (prev == -1) {
        for (k in 0 until b) mid[k] = mid[b]
      } else if (b - prev > 1) {
        for (k in prev + 1 until b) mid[k] = mid[prev] + (mid[b] - mid[prev]) * (k - prev) / (b - prev)
      }
      prev = b
    }
    if (prev >= 0) for (k in prev + 1 until n) mid[k] = mid[prev]

    val out = FloatArray(n)
    val left = window / 2
    val right = window - 1 - left
    for (b in 0 until n) {
      var acc = 0f
      for (k in b - left..b + right) acc += mid[k.coerceIn(0, n - 1)]
      out[b] = acc / window
    }
    return out
  }
}
