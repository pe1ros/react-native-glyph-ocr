package com.margelo.nitro.purelyocr.paddle

import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * PP-OCRv5 text detection (DB) + recognition (CTC) on ONNX Runtime or ExecuTorch, see [PaddleRuntime].
 * Pre/post-processing follows PaddleOCR; see TextLines.kt for the line finder.
 */
class PaddleOcr(
  private val runtime: PaddleRuntime,
  dictionary: List<String>,
) : AutoCloseable {
  class Options(
    val detLimitSide: Int,
    val detThresh: Float,
    val boxThresh: Float,
    val unclipRatio: Float,
    val dropScore: Float,
  )

  /** A word: `start`..`end` is its share (0..1) of the line's length, from CTC character positions. */
  class Word(val text: String, val score: Float, val start: Float, val end: Float)

  /** Bounds in the input bitmap, px; `geometry` maps points along the line to the bitmap. */
  class Line(
    val text: String,
    val score: Float,
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
    val geometry: TextLine,
    val words: List<Word>,
  )

  class Output(
    val lines: List<Line>,
    val detMs: Double,
    val recMs: Double,
    val detWidth: Int,
    val detHeight: Int,
    val boxCount: Int,
  )

  /** `onnxruntime-1.30.0`, `executorch-1.4.0`. */
  val runtimeName: String get() = runtime.name

  /** CTC classes: 0 is blank, then the dictionary, then a space. */
  private val classes: Array<String> = arrayOf("") + dictionary.toTypedArray() + " "

  private var buffer: ByteBuffer = ByteBuffer.allocateDirect(0)

  // Diagnostics of the last run(), logged to logcat.
  private var sampleNs = 0L
  private var inferNs = 0L
  private var recColumns = 0

  /** `checkCancelled` runs between lines and throws to stop. */
  fun run(bitmap: Bitmap, options: Options, checkCancelled: () -> Unit = {}): Output {
    val t0 = SystemClock.elapsedRealtimeNanos()
    val srcW = bitmap.width
    val srcH = bitmap.height

    // --- Detection
    val ratio = min(1f, options.detLimitSide.toFloat() / max(srcW, srcH))
    val detW = max(32, (srcW * ratio / 32f).roundToInt() * 32)
    val detH = max(32, (srcH * ratio / 32f).roundToInt() * 32)
    val detPixels = scaledPixels(bitmap, detW, detH)
    val detTensor = floatBuffer(3 * detW * detH)
    val plane = detW * detH
    // PaddleOCR feeds BGR with ImageNet mean/std in RGB order; the ExecuTorch export takes plain RGB.
    val first = if (runtime.rgbInput) 16 else 0
    val third = 16 - first
    for (i in 0 until plane) {
      val p = detPixels[i]
      detTensor.put(i, (((p shr first) and 0xff) / 255f - 0.485f) / 0.229f)
      detTensor.put(plane + i, (((p shr 8) and 0xff) / 255f - 0.456f) / 0.224f)
      detTensor.put(2 * plane + i, (((p shr third) and 0xff) / 255f - 0.406f) / 0.225f)
    }
    val prob = runtime.detect(detTensor, detH, detW)
    val found = TextLineFinder.find(
      prob, detW, detH, srcW, srcH, options.detThresh, options.boxThresh, options.unclipRatio,
    )
    val t1 = SystemClock.elapsedRealtimeNanos()

    // --- Recognition, one line at a time (batch = 1 keeps memory flat on cheap phones)
    sampleNs = 0
    inferNs = 0
    recColumns = 0
    val src = IntArray(srcW * srcH)
    bitmap.getPixels(src, 0, srcW, 0, 0, srcW, srcH)
    val lines = ArrayList<Line>()
    for (line in found) {
      checkCancelled()
      val recognized = recognize(src, srcW, srcH, line) ?: continue
      if (recognized.score >= options.dropScore && recognized.text.isNotBlank()) {
        lines.add(bounds(line, recognized, srcW, srcH))
      }
    }
    val t2 = SystemClock.elapsedRealtimeNanos()
    Log.i(TAG, "det ${(t1 - t0) / 1_000_000} ms (${detW}x$detH), rec ${(t2 - t1) / 1_000_000} ms: " +
      "sampling ${sampleNs / 1_000_000} ms, inference ${inferNs / 1_000_000} ms, " +
      "${found.size} lines, $recColumns input columns")
    return Output(lines, (t1 - t0) / 1e6, (t2 - t1) / 1e6, detW, detH, found.size)
  }

  private class Decoded(val text: String, val score: Float, val words: List<Word>)

  private fun recognize(src: IntArray, srcW: Int, srcH: Int, line: TextLine): Decoded? {
    var length = line.lengthSrc
    var height = line.heightSrc
    if (line.vertical) length = height.also { height = length }
    if (length < 1f || height < 1f) return null
    val outW = min(REC_MAX_W, max(1, ceil(REC_H * length / height).toInt()))
    val step = runtime.recWidthStep
    val padW = (max(REC_MIN_W, outW) + step - 1) / step * step
    val tensor = floatBuffer(3 * REC_H * padW)
    val ts = SystemClock.elapsedRealtimeNanos()
    sampleLine(src, srcW, srcH, line, outW, padW, tensor)
    val ti = SystemClock.elapsedRealtimeNanos()
    sampleNs += ti - ts
    recColumns += padW

    val out = runtime.recognize(tensor, padW)
    inferNs += SystemClock.elapsedRealtimeNanos() - ti
    // One CTC step covers padW / steps input columns; the text fills the first outW of them.
    return ctcDecode(out.probs, out.steps, out.classes, padW.toFloat() / out.steps / outW)
  }

  /**
   * Greedy CTC: argmax per step, merge repeats, drop blanks; score = mean prob of kept chars.
   * Words are runs of non-space characters; `stepShare` is one step's share of the line length.
   */
  private fun ctcDecode(probs: FloatArray, steps: Int, numClasses: Int, stepShare: Float): Decoded {
    val sb = StringBuilder()
    var scoreSum = 0f
    var kept = 0
    var prev = -1
    val words = ArrayList<Word>()
    val word = StringBuilder()
    var wordScore = 0f
    var wordFirst = 0
    var wordLast = 0
    fun endWord() {
      if (word.isEmpty()) return
      words.add(Word(word.toString(), wordScore / word.length,
        (wordFirst * stepShare).coerceIn(0f, 1f), ((wordLast + 1) * stepShare).coerceIn(0f, 1f)))
      word.setLength(0)
      wordScore = 0f
    }
    for (t in 0 until steps) {
      val base = t * numClasses
      var best = 0
      var bestP = probs[base]
      for (k in 1 until numClasses) {
        val p = probs[base + k]
        if (p > bestP) {
          bestP = p
          best = k
        }
      }
      if (best != 0 && best != prev && best < classes.size) {
        val ch = classes[best]
        sb.append(ch)
        scoreSum += bestP
        kept++
        if (ch.isBlank()) {
          endWord()
        } else {
          if (word.isEmpty()) wordFirst = t
          word.append(ch)
          wordScore += bestP
          wordLast = t
        }
      } else if (best != 0 && best == prev && word.isNotEmpty()) {
        wordLast = t // a repeated step still belongs to the character
      }
      prev = best
    }
    endWord()
    return Decoded(sb.toString(), if (kept == 0) 0f else scoreSum / kept, words)
  }

  /**
   * Fills the recognizer input [3, REC_H, padW] (BGR or RGB, see [PaddleRuntime.rgbInput];
   * (x/255 - 0.5) / 0.5, zero right padding)
   * by sampling the line straight from the source pixels. Supersamples when shrinking, so that
   * big text is averaged instead of aliased.
   */
  private fun sampleLine(src: IntArray, srcW: Int, srcH: Int, line: TextLine, outW: Int, padW: Int, out: FloatBuffer) {
    var length = line.lengthSrc
    var height = line.heightSrc
    if (line.vertical) length = height.also { height = length }
    val scale = max(length / outW, height / REC_H)
    val ss = min(4, max(1, ceil(scale - 0.5f).toInt()))
    val inv = 1f / (ss * ss)
    val plane = REC_H * padW
    val du = line.u1 - line.u0
    val h2 = 2 * line.halfHeight
    // Output columns run along the text (u); rows run across it (v). For vertical lines the
    // text reads down the image with its top facing +x, as after PaddleOCR's rot90 crop.
    val cols = outW * ss
    val us = FloatArray(cols)
    val vTop = FloatArray(cols)
    for (k in 0 until cols) {
      val u = line.u0 + (k + 0.5f) / cols * du
      us[k] = u
      vTop[k] = if (line.vertical) line.centerAt(u) + line.halfHeight else line.centerAt(u) - line.halfHeight
    }
    val vStep = if (line.vertical) -h2 else h2
    val rgb = runtime.rgbInput
    for (j in 0 until REC_H) {
      for (i in 0 until outW) {
        var b = 0f
        var g = 0f
        var r = 0f
        for (a in 0 until ss) {
          val k = i * ss + a
          val u = us[k]
          for (c in 0 until ss) {
            val fj = (j + (c + 0.5f) / ss) / REC_H
            val v = vTop[k] + fj * vStep
            val rgb = bilinear(src, srcW, srcH, line.srcX(u, v), line.srcY(u, v))
            b += rgb[0]
            g += rgb[1]
            r += rgb[2]
          }
        }
        val idx = j * padW + i
        out.put(idx, ((if (rgb) r else b) * inv / 255f - 0.5f) / 0.5f)
        out.put(plane + idx, (g * inv / 255f - 0.5f) / 0.5f)
        out.put(2 * plane + idx, ((if (rgb) b else r) * inv / 255f - 0.5f) / 0.5f)
      }
      for (i in outW until padW) {
        val idx = j * padW + i
        out.put(idx, 0f)
        out.put(plane + idx, 0f)
        out.put(2 * plane + idx, 0f)
      }
    }
  }

  private val sampleRgb = FloatArray(3)

  /** Bilinear sample; returns [B, G, R] in a reused array. */
  private fun bilinear(src: IntArray, w: Int, h: Int, xIn: Float, yIn: Float): FloatArray {
    val x = xIn.coerceIn(0f, (w - 1).toFloat())
    val y = yIn.coerceIn(0f, (h - 1).toFloat())
    val x0 = floor(x).toInt()
    val y0 = floor(y).toInt()
    val x1 = min(x0 + 1, w - 1)
    val y1 = min(y0 + 1, h - 1)
    val fx = x - x0
    val fy = y - y0
    val p00 = src[y0 * w + x0]
    val p10 = src[y0 * w + x1]
    val p01 = src[y1 * w + x0]
    val p11 = src[y1 * w + x1]
    for (ch in 0 until 3) {
      val shift = ch * 8 // 0 = B, 8 = G, 16 = R
      val a = ((p00 shr shift) and 0xff) * (1 - fx) + ((p10 shr shift) and 0xff) * fx
      val b = ((p01 shr shift) and 0xff) * (1 - fx) + ((p11 shr shift) and 0xff) * fx
      sampleRgb[ch] = a * (1 - fy) + b * fy
    }
    return sampleRgb
  }

  private fun bounds(line: TextLine, recognized: Decoded, srcW: Int, srcH: Int): Line {
    var left = Float.MAX_VALUE
    var top = Float.MAX_VALUE
    var right = -Float.MAX_VALUE
    var bottom = -Float.MAX_VALUE
    val du = line.u1 - line.u0
    for (k in 0..4) {
      val u = line.u0 + du * k / 4
      val c = line.centerAt(u)
      for (v in floatArrayOf(c - line.halfHeight, c + line.halfHeight)) {
        val x = line.srcX(u, v)
        val y = line.srcY(u, v)
        left = min(left, x); right = max(right, x)
        top = min(top, y); bottom = max(bottom, y)
      }
    }
    return Line(
      recognized.text, recognized.score,
      left.coerceIn(0f, srcW.toFloat()), top.coerceIn(0f, srcH.toFloat()),
      right.coerceIn(0f, srcW.toFloat()), bottom.coerceIn(0f, srcH.toFloat()),
      line, recognized.words,
    )
  }

  /** Downscales in halving steps first, so that large reductions average pixels instead of skipping them. */
  private fun scaledPixels(bitmap: Bitmap, w: Int, h: Int): IntArray {
    var current = bitmap
    while (current.width >= 2 * w && current.height >= 2 * h) {
      val half = Bitmap.createScaledBitmap(current, current.width / 2, current.height / 2, true)
      if (current !== bitmap) current.recycle()
      current = half
    }
    val scaled = if (current.width == w && current.height == h) current else Bitmap.createScaledBitmap(current, w, h, true)
    if (current !== bitmap && current !== scaled) current.recycle()
    val pixels = IntArray(w * h)
    scaled.getPixels(pixels, 0, w, 0, 0, w, h)
    if (scaled !== bitmap) scaled.recycle()
    return pixels
  }

  private fun floatBuffer(count: Int): FloatBuffer {
    if (buffer.capacity() < count * 4) {
      buffer = ByteBuffer.allocateDirect(count * 4).order(ByteOrder.nativeOrder())
    }
    // A view of exactly `count` floats: ExecuTorch checks the capacity against the tensor shape.
    buffer.clear()
    buffer.limit(count * 4)
    return buffer.slice().order(ByteOrder.nativeOrder()).asFloatBuffer()
  }

  override fun close() {
    runtime.close()
  }

  companion object {
    private const val TAG = "PurelyOcr"
    private const val REC_MIN_W = 320
    private const val REC_MAX_W = 3200
  }
}
