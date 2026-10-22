package com.margelo.nitro.glyphocr

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

// The same geometry lives in ios/Geometry.swift: keep the two in step.

internal class Pt(val x: Double, val y: Double)

internal class RectD(val x: Double, val y: Double, val w: Double, val h: Double) {
  val right get() = x + w
  val bottom get() = y + h
}

/**
 * EXIF orientation 1..8 of stored pixels: how they must be turned to look upright.
 * VisionCamera's `Frame.orientation` says how the picture is rotated inside the buffer:
 * `'left'` (content turned 90° left; the back camera held upright) needs a 90° clockwise turn, EXIF 6.
 * `ImageOrientation` uses the same strings and meaning.
 */
internal object Exif {
  fun of(orientation: FrameOrientation, mirrored: Boolean): Int = when (orientation) {
    FrameOrientation.UP -> if (mirrored) 2 else 1
    FrameOrientation.DOWN -> if (mirrored) 4 else 3
    FrameOrientation.LEFT -> if (mirrored) 5 else 6
    FrameOrientation.RIGHT -> if (mirrored) 7 else 8
  }

  fun of(orientation: ImageOrientation): Int? = when (orientation) {
    ImageOrientation.AUTO -> null
    ImageOrientation.UP -> 1
    ImageOrientation.DOWN -> 3
    ImageOrientation.LEFT -> 6
    ImageOrientation.RIGHT -> 8
  }

  fun sideways(exif: Int) = exif in 5..8

  /** Upright point → stored point; `w`, `h` are the upright size. */
  fun toRaw(exif: Int, w: Double, h: Double, x: Double, y: Double): Pt = when (exif) {
    2 -> Pt(w - x, y)
    3 -> Pt(w - x, h - y)
    4 -> Pt(x, h - y)
    5 -> Pt(y, x)
    6 -> Pt(y, w - x)
    7 -> Pt(h - y, w - x)
    8 -> Pt(h - y, x)
    else -> Pt(x, y)
  }

  /** Bounds of an upright rect in stored pixels. */
  fun toRaw(exif: Int, w: Double, h: Double, r: RectD): RectD {
    val a = toRaw(exif, w, h, r.x, r.y)
    val b = toRaw(exif, w, h, r.right, r.bottom)
    return RectD(min(a.x, b.x), min(a.y, b.y), abs(a.x - b.x), abs(a.y - b.y))
  }
}

internal object Regions {
  /** `rect` normalized to a view that shows an image of `imageW` x `imageH` → normalized to the image. */
  fun viewToImage(x: Double, y: Double, w: Double, h: Double, view: RegionView, imageW: Double, imageH: Double): RectD {
    val scale = if (view.resizeMode == ViewResizeMode.COVER) {
      max(view.width / imageW, view.height / imageH)
    } else {
      min(view.width / imageW, view.height / imageH)
    }
    val shownW = imageW * scale
    val shownH = imageH * scale
    val offX = (view.width - shownW) / 2
    val offY = (view.height - shownH) / 2
    val x0 = ((x * view.width - offX) / shownW).coerceIn(0.0, 1.0)
    val y0 = ((y * view.height - offY) / shownH).coerceIn(0.0, 1.0)
    val x1 = (((x + w) * view.width - offX) / shownW).coerceIn(0.0, 1.0)
    val y1 = (((y + h) * view.height - offY) / shownH).coerceIn(0.0, 1.0)
    return RectD(x0, y0, x1 - x0, y1 - y0)
  }

  /**
   * The ROI in whole upright-image pixels, rounded outwards and clamped; null when it is the
   * whole image. Throws `invalid-argument` when it is empty or outside the image.
   */
  fun resolve(roi: OcrRegion?, imageW: Int, imageH: Int): RectD? {
    roi ?: return null
    return resolveNormalized(normalize(roi, imageW.toDouble(), imageH.toDouble()), imageW, imageH)
  }

  fun resolve(roi: OcrRect?, imageW: Int, imageH: Int): RectD? {
    roi ?: return null
    return resolveNormalized(RectD(roi.x, roi.y, roi.width, roi.height), imageW, imageH)
  }

  private fun normalize(roi: OcrRegion, imageW: Double, imageH: Double): RectD {
    val view = roi.view
    if (view != null) {
      if (view.width <= 0 || view.height <= 0) throw OcrException("invalid-argument", "roi.view has no size")
      val pixel = roi.unit == RegionUnit.PIXEL
      val sx = if (pixel) 1 / view.width else 1.0
      val sy = if (pixel) 1 / view.height else 1.0
      return viewToImage(roi.x * sx, roi.y * sy, roi.width * sx, roi.height * sy, view, imageW, imageH)
    }
    return if (roi.unit == RegionUnit.PIXEL) {
      RectD(roi.x / imageW, roi.y / imageH, roi.width / imageW, roi.height / imageH)
    } else {
      RectD(roi.x, roi.y, roi.width, roi.height)
    }
  }

  private fun resolveNormalized(r: RectD, imageW: Int, imageH: Int): RectD? {
    if (listOf(r.x, r.y, r.w, r.h).any { it.isNaN() || it.isInfinite() } || r.w <= 0 || r.h <= 0) {
      throw OcrException("invalid-argument", "roi is empty", mapOf("roi" to listOf(r.x, r.y, r.w, r.h).toString()))
    }
    val x0 = floor(r.x.coerceIn(0.0, 1.0) * imageW)
    val y0 = floor(r.y.coerceIn(0.0, 1.0) * imageH)
    val x1 = ceil(r.right.coerceIn(0.0, 1.0) * imageW)
    val y1 = ceil(r.bottom.coerceIn(0.0, 1.0) * imageH)
    if (x1 - x0 < 1 || y1 - y0 < 1) {
      throw OcrException("invalid-argument", "roi is outside the image", mapOf("roi" to listOf(r.x, r.y, r.w, r.h).toString()))
    }
    if (x0 == 0.0 && y0 == 0.0 && x1 == imageW.toDouble() && y1 == imageH.toDouble()) return null
    return RectD(x0, y0, x1 - x0, y1 - y0)
  }
}

/** A recognized word, in whole upright-image pixels. */
internal class RawWord(val text: String, val confidence: Double, val corners: List<Pt>)

/**
 * A recognized line in whole upright-image pixels: the text's TL, TR, BR, BL corners and the
 * axis-aligned box the spike measured (the `rows` join uses it).
 */
internal class RawLine(
  val text: String,
  val confidence: Double,
  val corners: List<Pt>,
  val left: Double,
  val top: Double,
  val right: Double,
  val bottom: Double,
  val words: List<RawWord>,
) {
  val angle: Double get() = angleOf(corners)
  val height: Double get() = (dist(corners[0], corners[3]) + dist(corners[1], corners[2])) / 2
}

private fun dist(a: Pt, b: Pt) = hypot(a.x - b.x, a.y - b.y)

/** Degrees of TL→TR against the horizontal, clockwise positive (y points down), in (-180, 180]. */
internal fun angleOf(c: List<Pt>): Double {
  val a = Math.toDegrees(atan2(c[1].y - c[0].y, c[1].x - c[0].x))
  return if (a <= -180.0) a + 360.0 else a
}

private fun angleDiff(a: Double, b: Double): Double {
  var d = (a - b) % 360.0
  if (d > 180) d -= 360
  if (d < -180) d += 360
  return abs(d)
}

/** Builds the ML Kit-shaped result: lines grouped into blocks, text in the requested order. */
internal object ResultBuilder {
  private class Row(var u0: Double, var u1: Double, val v: Double, val h: Double)

  private class Block(val angle: Double) {
    val lines = ArrayList<RawLine>()
    val rows = ArrayList<Int>()
    val us = ArrayList<Double>()
    var row: Row? = null
    var rowIndex = 0
    val cos = cos(Math.toRadians(angle))
    val sin = sin(Math.toRadians(angle))

    fun u(p: Pt) = p.x * cos + p.y * sin
    fun v(p: Pt) = -p.x * sin + p.y * cos
  }

  /**
   * Lines are tried in the given order (Vision's own order on iOS, top to bottom for Paddle).
   * A line joins a block whose last row it continues: a piece of the same row close to it, or the
   * next row (similar height, at most 2 line heights lower, overlapping or left-aligned).
   */
  fun group(lines: List<RawLine>): List<List<RawLine>> {
    val blocks = ArrayList<Block>()
    for (line in lines) {
      var placed = false
      for (b in blocks.asReversed()) {
        val row = b.row ?: continue
        if (angleDiff(line.angle, b.angle) > 12) continue
        val lu = line.corners.map { b.u(it) }
        val lu0 = lu.min()
        val lu1 = lu.max()
        val lv = line.corners.sumOf { b.v(it) } / 4
        val lh = line.height
        if (max(lh, row.h) > 1.6 * min(lh, row.h)) continue
        val h = (lh + row.h) / 2
        val dv = lv - row.v
        if (abs(dv) < 0.5 * h) {
          val gap = max(lu0 - row.u1, row.u0 - lu1)
          if (gap > 2.0 * h) continue
          row.u0 = min(row.u0, lu0)
          row.u1 = max(row.u1, lu1)
        } else if (dv > 0 && dv < 2.0 * h) {
          val overlap = min(lu1, row.u1) - max(lu0, row.u0)
          val aligned = abs(lu0 - row.u0) < 1.5 * h
          if (overlap <= 0.3 * min(lu1 - lu0, row.u1 - row.u0) && !aligned) continue
          b.row = Row(lu0, lu1, lv, lh)
          b.rowIndex++
        } else {
          continue
        }
        b.lines.add(line)
        b.rows.add(b.rowIndex)
        b.us.add(lu0)
        placed = true
        break
      }
      if (!placed) {
        val b = Block(line.angle)
        val lu = line.corners.map { b.u(it) }
        b.row = Row(lu.min(), lu.max(), line.corners.sumOf { b.v(it) } / 4, line.height)
        b.lines.add(line)
        b.rows.add(0)
        b.us.add(lu.min())
        blocks.add(b)
      }
    }
    // Inside a block: row by row, pieces of a row left to right along the text.
    return blocks.map { b -> b.lines.indices.sortedWith(compareBy({ b.rows[it] }, { b.us[it] })).map { b.lines[it] } }
  }

  /**
   * Pieces of one visual row that sit close together become one line, as ML Kit's `Line`: the
   * Paddle detector cuts big text into words, Vision cuts long lines at wide gaps. Rows use the
   * rule of [rowsText]; a row splits where the gap is wider than 1.5 line heights (columns), and
   * only near-horizontal pieces are joined. Lines come out in the order of their first piece.
   */
  fun visualLines(lines: List<RawLine>): List<RawLine> {
    class R(val cy: Double, val h: Double) {
      val items = ArrayList<Int>()
    }
    val rows = ArrayList<R>()
    val single = ArrayList<List<Int>>()
    for (i in lines.indices.sortedBy { lines[it].top + lines[it].bottom }) {
      val line = lines[i]
      if (abs(line.angle) > 20) {
        single.add(listOf(i))
        continue
      }
      val cy = (line.top + line.bottom) / 2
      val h = line.bottom - line.top
      val row = rows.firstOrNull { abs(it.cy - cy) < 0.5 * min(it.h, h) } ?: R(cy, h).also { rows.add(it) }
      row.items.add(i)
    }
    val groups = ArrayList<List<Int>>(single)
    for (row in rows) {
      val items = row.items.sortedBy { lines[it].left }
      var current = arrayListOf(items[0])
      for (k in 1 until items.size) {
        val prev = lines[current.last()]
        val next = lines[items[k]]
        if (next.left - prev.right > 1.5 * max(prev.bottom - prev.top, next.bottom - next.top)) {
          groups.add(current)
          current = arrayListOf(items[k])
        } else {
          current.add(items[k])
        }
      }
      groups.add(current)
    }
    return groups.sortedBy { g -> g.min() }.map { g -> if (g.size == 1) lines[g[0]] else merge(g.map { lines[it] }) }
  }

  /** Pieces of a row, left to right, as one line. */
  private fun merge(pieces: List<RawLine>): RawLine {
    val first = pieces.first()
    val last = pieces.last()
    val length = pieces.sumOf { max(1, it.text.length) }.toDouble()
    return RawLine(
      text = pieces.joinToString(" ") { it.text },
      confidence = pieces.sumOf { it.confidence * max(1, it.text.length) } / length,
      corners = listOf(first.corners[0], last.corners[1], last.corners[2], first.corners[3]),
      left = pieces.minOf { it.left },
      top = pieces.minOf { it.top },
      right = pieces.maxOf { it.right },
      bottom = pieces.maxOf { it.bottom },
      words = pieces.flatMap { it.words },
    )
  }

  /** The spike's join (ReadingOrder.kt / VisionText.join): visual rows top to bottom across the image. */
  fun rowsText(lines: List<RawLine>): String {
    class R(val cy: Double, val h: Double) {
      val items = ArrayList<RawLine>()
    }
    val rows = ArrayList<R>()
    for (line in lines.sortedBy { it.top + it.bottom }) {
      val cy = (line.top + line.bottom) / 2
      val h = line.bottom - line.top
      val row = rows.firstOrNull { abs(it.cy - cy) < 0.5 * min(it.h, h) } ?: R(cy, h).also { rows.add(it) }
      row.items.add(line)
    }
    return rows.sortedBy { it.cy }.joinToString("\n") { r -> r.items.sortedBy { it.left }.joinToString(" ") { it.text } }
  }

  class Built(val text: String, val blocks: Array<OcrBlock>)

  /**
   * `lines` are the engine's pieces; `rows` text joins them as the spike did, `blocks` groups their
   * visual lines. `groups`: blocks the engine made itself (ML Kit).
   */
  fun build(
    lines: List<RawLine>, imageW: Int, imageH: Int, output: OcrOutput, order: ReadingOrder,
    groups: List<List<RawLine>> = group(visualLines(lines)),
  ): Built {
    val text = if (order == ReadingOrder.ROWS) {
      rowsText(lines)
    } else {
      groups.joinToString("\n") { g -> g.joinToString("\n") { it.text } }
    }
    if (output == OcrOutput.TEXT) return Built(text, emptyArray())
    val w = imageW.toDouble()
    val h = imageH.toDouble()
    val blocks = groups.map { g ->
      val lineObjects = g.map { line ->
        OcrLine(
          text = line.text,
          confidence = line.confidence,
          boundingBox = normalizedBox(line.left, line.top, line.right, line.bottom, w, h),
          pixelBoundingBox = pixelBox(line.left, line.top, line.right, line.bottom, w, h),
          cornerPoints = normalizedPoints(line.corners, w, h),
          angle = line.angle,
          elements = if (output == OcrOutput.ELEMENTS) {
            line.words.map { word ->
              val xs = word.corners.map { it.x }
              val ys = word.corners.map { it.y }
              OcrElement(
                text = word.text,
                confidence = word.confidence,
                boundingBox = normalizedBox(xs.min(), ys.min(), xs.max(), ys.max(), w, h),
                pixelBoundingBox = pixelBox(xs.min(), ys.min(), xs.max(), ys.max(), w, h),
                cornerPoints = normalizedPoints(word.corners, w, h),
                angle = angleOf(word.corners),
              )
            }.toTypedArray()
          } else {
            emptyArray()
          },
        )
      }
      val angles = g.map { it.angle }.sorted()
      val angle = angles[angles.size / 2]
      val length = g.sumOf { max(1, it.text.length) }.toDouble()
      OcrBlock(
        text = g.joinToString("\n") { it.text },
        confidence = g.sumOf { it.confidence * max(1, it.text.length) } / length,
        boundingBox = normalizedBox(g.minOf { it.left }, g.minOf { it.top }, g.maxOf { it.right }, g.maxOf { it.bottom }, w, h),
        pixelBoundingBox = pixelBox(g.minOf { it.left }, g.minOf { it.top }, g.maxOf { it.right }, g.maxOf { it.bottom }, w, h),
        cornerPoints = normalizedPoints(blockCorners(g, angle), w, h),
        angle = angle,
        lines = lineObjects.toTypedArray(),
      )
    }
    return Built(text, blocks.toTypedArray())
  }

  /**
   * [build] for text that may be upside down: when most lines read at about 180°, the order is
   * worked out on the image turned 180° and the coordinates are turned back, so blocks and rows
   * follow the text while every box stays on the image as given.
   */
  fun buildOriented(lines: List<RawLine>, imageW: Int, imageH: Int, output: OcrOutput, order: ReadingOrder): Built {
    if (lines.count { abs(it.angle) > 135 } * 2 <= lines.size) return build(lines, imageW, imageH, output, order)
    val w = imageW.toDouble()
    val h = imageH.toDouble()
    fun turn(p: Pt) = Pt(w - p.x, h - p.y)
    val turned = lines.map { l ->
      RawLine(
        l.text, l.confidence, l.corners.map(::turn), w - l.right, h - l.bottom, w - l.left, h - l.top,
        l.words.map { RawWord(it.text, it.confidence, it.corners.map(::turn)) },
      )
    }.sortedWith(compareBy({ it.top }, { it.left })) // the order [build] expects, in the turned image
    val built = build(turned, imageW, imageH, output, order)
    fun box(r: OcrRect, sw: Double, sh: Double) = OcrRect(sw - r.x - r.width, sh - r.y - r.height, r.width, r.height)
    fun points(ps: Array<OcrPoint>) = ps.map { OcrPoint(1 - it.x, 1 - it.y) }.toTypedArray()
    fun angle(a: Double) = if (a + 180 > 180) a - 180 else a + 180
    return Built(
      built.text,
      built.blocks.map { b ->
        OcrBlock(
          text = b.text, confidence = b.confidence,
          boundingBox = box(b.boundingBox, 1.0, 1.0), pixelBoundingBox = box(b.pixelBoundingBox, w, h),
          cornerPoints = points(b.cornerPoints), angle = angle(b.angle),
          lines = b.lines.map { l ->
            OcrLine(
              text = l.text, confidence = l.confidence,
              boundingBox = box(l.boundingBox, 1.0, 1.0), pixelBoundingBox = box(l.pixelBoundingBox, w, h),
              cornerPoints = points(l.cornerPoints), angle = angle(l.angle),
              elements = l.elements.map { e ->
                OcrElement(
                  text = e.text, confidence = e.confidence,
                  boundingBox = box(e.boundingBox, 1.0, 1.0), pixelBoundingBox = box(e.pixelBoundingBox, w, h),
                  cornerPoints = points(e.cornerPoints), angle = angle(e.angle),
                )
              }.toTypedArray(),
            )
          }.toTypedArray(),
        )
      }.toTypedArray(),
    )
  }

  /** The block's rectangle along its median angle. */
  private fun blockCorners(lines: List<RawLine>, angle: Double): List<Pt> {
    val c = cos(Math.toRadians(angle))
    val s = sin(Math.toRadians(angle))
    val pts = lines.flatMap { it.corners }
    val us = pts.map { it.x * c + it.y * s }
    val vs = pts.map { -it.x * s + it.y * c }
    val u0 = us.min()
    val u1 = us.max()
    val v0 = vs.min()
    val v1 = vs.max()
    fun xy(u: Double, v: Double) = Pt(u * c - v * s, u * s + v * c)
    return listOf(xy(u0, v0), xy(u1, v0), xy(u1, v1), xy(u0, v1))
  }

  /** Whole pixels, rounded outwards and clamped to the image, as ML Kit's `Rect`. */
  private fun pixelBox(l: Double, t: Double, r: Double, b: Double, w: Double, h: Double): OcrRect {
    val x0 = floor(l.coerceIn(0.0, w))
    val y0 = floor(t.coerceIn(0.0, h))
    val x1 = ceil(r.coerceIn(0.0, w))
    val y1 = ceil(b.coerceIn(0.0, h))
    return OcrRect(x0, y0, x1 - x0, y1 - y0)
  }

  /** The same pixel box divided by the image size. */
  private fun normalizedBox(l: Double, t: Double, r: Double, b: Double, w: Double, h: Double): OcrRect {
    val p = pixelBox(l, t, r, b, w, h)
    return OcrRect(p.x / w, p.y / h, p.width / w, p.height / h)
  }

  private fun normalizedPoints(points: List<Pt>, w: Double, h: Double): Array<OcrPoint> =
    points.map { OcrPoint((it.x / w).coerceIn(0.0, 1.0), (it.y / h).coerceIn(0.0, 1.0)) }.toTypedArray()
}
