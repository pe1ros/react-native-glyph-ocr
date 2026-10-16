package com.margelo.nitro.purelyocr.paddle

import kotlin.math.abs
import kotlin.math.min

/**
 * Joins recognized lines into text: boxes whose vertical centers are close are one visual row
 * (joined with spaces, left to right); rows are separated by newlines, top to bottom.
 */
object ReadingOrder {
  fun join(lines: List<PaddleOcr.Line>): String {
    class Row(val cy: Float, val h: Float) {
      val items = ArrayList<PaddleOcr.Line>()
    }
    val rows = ArrayList<Row>()
    for (line in lines.sortedBy { (it.top + it.bottom) / 2 }) {
      val cy = (line.top + line.bottom) / 2
      val h = line.bottom - line.top
      val row = rows.firstOrNull { abs(it.cy - cy) < 0.5f * min(it.h, h) }
        ?: Row(cy, h).also { rows.add(it) }
      row.items.add(line)
    }
    return rows.sortedBy { it.cy }.joinToString("\n") { row ->
      row.items.sortedBy { it.left }.joinToString(" ") { it.text }
    }
  }
}
