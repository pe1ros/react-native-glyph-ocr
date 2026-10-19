import Foundation

// The same geometry lives in android/.../Geometry.kt: keep the two in step.
// `Swift.` everywhere: with C++ interop on (Nitro), the C++ min/max/abs make bare calls ambiguous.

struct Pt {
  var x: Double
  var y: Double
}

struct RectD {
  var x: Double
  var y: Double
  var w: Double
  var h: Double
  var right: Double { x + w }
  var bottom: Double { y + h }
}

/**
 * EXIF orientation 1..8 of stored pixels: how they must be turned to look upright.
 * VisionCamera's `Frame.orientation` says how the picture is rotated inside the buffer:
 * `'left'` (content turned 90° left; the back camera held upright) needs a 90° clockwise turn, EXIF 6.
 * `ImageOrientation` uses the same strings and meaning.
 */
enum Exif {
  static func of(_ orientation: FrameOrientation, mirrored: Bool) -> Int {
    switch orientation {
    case .up: return mirrored ? 2 : 1
    case .down: return mirrored ? 4 : 3
    case .left: return mirrored ? 5 : 6
    case .right: return mirrored ? 7 : 8
    @unknown default: return 1
    }
  }

  static func of(_ orientation: ImageOrientation) -> Int? {
    switch orientation {
    case .auto: return nil
    case .up: return 1
    case .down: return 3
    case .left: return 6
    case .right: return 8
    @unknown default: return nil
    }
  }

  static func sideways(_ exif: Int) -> Bool { exif >= 5 && exif <= 8 }

  /** Upright point → stored point; `w`, `h` are the upright size. */
  static func toRaw(_ exif: Int, _ w: Double, _ h: Double, _ x: Double, _ y: Double) -> Pt {
    switch exif {
    case 2: return Pt(x: w - x, y: y)
    case 3: return Pt(x: w - x, y: h - y)
    case 4: return Pt(x: x, y: h - y)
    case 5: return Pt(x: y, y: x)
    case 6: return Pt(x: y, y: w - x)
    case 7: return Pt(x: h - y, y: w - x)
    case 8: return Pt(x: h - y, y: x)
    default: return Pt(x: x, y: y)
    }
  }
}

enum Regions {
  /** `rect` normalized to a view that shows an image of `imageW` x `imageH` → normalized to the image. */
  static func viewToImage(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ view: RegionView, _ imageW: Double, _ imageH: Double) -> RectD {
    let scale = view.resizeMode == .cover
      ? Swift.max(view.width / imageW, view.height / imageH)
      : Swift.min(view.width / imageW, view.height / imageH)
    let shownW = imageW * scale
    let shownH = imageH * scale
    let offX = (view.width - shownW) / 2
    let offY = (view.height - shownH) / 2
    let x0 = clamp01((x * view.width - offX) / shownW)
    let y0 = clamp01((y * view.height - offY) / shownH)
    let x1 = clamp01(((x + w) * view.width - offX) / shownW)
    let y1 = clamp01(((y + h) * view.height - offY) / shownH)
    return RectD(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
  }

  /**
   * The ROI in whole upright-image pixels, rounded outwards and clamped; nil when it is the
   * whole image. Throws `invalid-argument` when it is empty or outside the image.
   */
  static func resolve(_ roi: OcrRegion?, _ imageW: Int, _ imageH: Int) throws -> RectD? {
    guard let roi else { return nil }
    let w = Double(imageW)
    let h = Double(imageH)
    let r: RectD
    if let view = roi.view {
      guard view.width > 0, view.height > 0 else { throw OcrError("invalid-argument", "roi.view has no size") }
      let pixel = roi.unit == .pixel
      let sx = pixel ? 1 / view.width : 1
      let sy = pixel ? 1 / view.height : 1
      r = viewToImage(roi.x * sx, roi.y * sy, roi.width * sx, roi.height * sy, view, w, h)
    } else if roi.unit == .pixel {
      r = RectD(x: roi.x / w, y: roi.y / h, w: roi.width / w, h: roi.height / h)
    } else {
      r = RectD(x: roi.x, y: roi.y, w: roi.width, h: roi.height)
    }
    return try resolveNormalized(r, imageW, imageH)
  }

  static func resolve(_ roi: OcrRect?, _ imageW: Int, _ imageH: Int) throws -> RectD? {
    guard let roi else { return nil }
    return try resolveNormalized(RectD(x: roi.x, y: roi.y, w: roi.width, h: roi.height), imageW, imageH)
  }

  private static func resolveNormalized(_ r: RectD, _ imageW: Int, _ imageH: Int) throws -> RectD? {
    let values = [r.x, r.y, r.w, r.h]
    if values.contains(where: { !$0.isFinite }) || r.w <= 0 || r.h <= 0 {
      throw OcrError("invalid-argument", "roi is empty", ["roi": values.map { "\($0)" }.joined(separator: ",")])
    }
    let x0 = (clamp01(r.x) * Double(imageW)).rounded(.down)
    let y0 = (clamp01(r.y) * Double(imageH)).rounded(.down)
    let x1 = (clamp01(r.right) * Double(imageW)).rounded(.up)
    let y1 = (clamp01(r.bottom) * Double(imageH)).rounded(.up)
    if x1 - x0 < 1 || y1 - y0 < 1 {
      throw OcrError("invalid-argument", "roi is outside the image", ["roi": values.map { "\($0)" }.joined(separator: ",")])
    }
    if x0 == 0, y0 == 0, x1 == Double(imageW), y1 == Double(imageH) { return nil }
    return RectD(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
  }
}

@inline(__always) func clamp01(_ v: Double) -> Double { Swift.min(1, Swift.max(0, v)) }

/** A recognized word, in whole upright-image pixels. */
struct RawWord {
  let text: String
  let confidence: Double
  let corners: [Pt]
}

/**
 * A recognized line in whole upright-image pixels: the text's TL, TR, BR, BL corners and the
 * axis-aligned box the spike measured (the `rows` join uses it).
 */
struct RawLine {
  let text: String
  let confidence: Double
  let corners: [Pt]
  let left: Double
  let top: Double
  let right: Double
  let bottom: Double
  let words: [RawWord]

  var angle: Double { angleOf(corners) }
  var height: Double { (dist(corners[0], corners[3]) + dist(corners[1], corners[2])) / 2 }
}

private func dist(_ a: Pt, _ b: Pt) -> Double { hypot(a.x - b.x, a.y - b.y) }

/** Degrees of TL→TR against the horizontal, clockwise positive (y points down), in (-180, 180]. */
func angleOf(_ c: [Pt]) -> Double {
  let a = atan2(c[1].y - c[0].y, c[1].x - c[0].x) * 180 / .pi
  return a <= -180 ? a + 360 : a
}

private func angleDiff(_ a: Double, _ b: Double) -> Double {
  var d = (a - b).truncatingRemainder(dividingBy: 360)
  if d > 180 { d -= 360 }
  if d < -180 { d += 360 }
  return Swift.abs(d)
}

/** Builds the ML Kit-shaped result: lines grouped into blocks, text in the requested order. */
enum ResultBuilder {
  private struct Row {
    var u0: Double
    var u1: Double
    let v: Double
    let h: Double
  }

  private final class Block {
    let angle: Double
    let cos: Double
    let sin: Double
    var lines: [RawLine] = []
    var rows: [Int] = []
    var us: [Double] = []
    var row: Row
    var rowIndex = 0

    init(_ line: RawLine) {
      angle = line.angle
      cos = Foundation.cos(angle * .pi / 180)
      sin = Foundation.sin(angle * .pi / 180)
      row = Row(u0: 0, u1: 0, v: 0, h: 0)
      let lu = line.corners.map { u($0) }
      row = Row(u0: lu.min()!, u1: lu.max()!, v: line.corners.reduce(0) { $0 + v($1) } / 4, h: line.height)
      lines.append(line)
      rows.append(0)
      us.append(lu.min()!)
    }

    func u(_ p: Pt) -> Double { p.x * cos + p.y * sin }
    func v(_ p: Pt) -> Double { -p.x * sin + p.y * cos }
  }

  /**
   * Lines are tried in the given order (Vision's own order on iOS, top to bottom for Paddle).
   * A line joins a block whose last row it continues: a piece of the same row close to it, or the
   * next row (similar height, at most 2 line heights lower, overlapping or left-aligned).
   */
  static func group(_ lines: [RawLine]) -> [[RawLine]] {
    var blocks: [Block] = []
    for line in lines {
      var placed = false
      for b in blocks.reversed() {
        let row = b.row
        if angleDiff(line.angle, b.angle) > 12 { continue }
        let lu = line.corners.map { b.u($0) }
        let lu0 = lu.min()!
        let lu1 = lu.max()!
        let lv = line.corners.reduce(0) { $0 + b.v($1) } / 4
        let lh = line.height
        if Swift.max(lh, row.h) > 1.6 * Swift.min(lh, row.h) { continue }
        let h = (lh + row.h) / 2
        let dv = lv - row.v
        if Swift.abs(dv) < 0.5 * h {
          let gap = Swift.max(lu0 - row.u1, row.u0 - lu1)
          if gap > 2.0 * h { continue }
          b.row.u0 = Swift.min(row.u0, lu0)
          b.row.u1 = Swift.max(row.u1, lu1)
        } else if dv > 0 && dv < 2.0 * h {
          let overlap = Swift.min(lu1, row.u1) - Swift.max(lu0, row.u0)
          let aligned = Swift.abs(lu0 - row.u0) < 1.5 * h
          if overlap <= 0.3 * Swift.min(lu1 - lu0, row.u1 - row.u0) && !aligned { continue }
          b.row = Row(u0: lu0, u1: lu1, v: lv, h: lh)
          b.rowIndex += 1
        } else {
          continue
        }
        b.lines.append(line)
        b.rows.append(b.rowIndex)
        b.us.append(lu0)
        placed = true
        break
      }
      if !placed { blocks.append(Block(line)) }
    }
    // Inside a block: row by row, pieces of a row left to right along the text.
    return blocks.map { b in
      b.lines.indices.sorted { i, j in b.rows[i] != b.rows[j] ? b.rows[i] < b.rows[j] : b.us[i] < b.us[j] }.map { b.lines[$0] }
    }
  }

  /**
   * Pieces of one visual row that sit close together become one line, as ML Kit's `Line`: the
   * Paddle detector cuts big text into words, Vision cuts long lines at wide gaps. Rows use the
   * rule of `rowsText`; a row splits where the gap is wider than 1.5 line heights (columns), and
   * only near-horizontal pieces are joined. Lines come out in the order of their first piece.
   */
  static func visualLines(_ lines: [RawLine]) -> [RawLine] {
    final class R {
      let cy: Double
      let h: Double
      var items: [Int] = []
      init(cy: Double, h: Double) { self.cy = cy; self.h = h }
    }
    var rows: [R] = []
    var groups: [[Int]] = []
    for i in lines.indices.sorted(by: { lines[$0].top + lines[$0].bottom < lines[$1].top + lines[$1].bottom }) {
      let line = lines[i]
      if Swift.abs(line.angle) > 20 {
        groups.append([i])
        continue
      }
      let cy = (line.top + line.bottom) / 2
      let h = line.bottom - line.top
      if let row = rows.first(where: { Swift.abs($0.cy - cy) < 0.5 * Swift.min($0.h, h) }) {
        row.items.append(i)
      } else {
        let row = R(cy: cy, h: h)
        row.items.append(i)
        rows.append(row)
      }
    }
    for row in rows {
      let items = row.items.sorted { lines[$0].left < lines[$1].left }
      var current = [items[0]]
      for k in 1..<items.count {
        let prev = lines[current.last!]
        let next = lines[items[k]]
        if next.left - prev.right > 1.5 * Swift.max(prev.bottom - prev.top, next.bottom - next.top) {
          groups.append(current)
          current = [items[k]]
        } else {
          current.append(items[k])
        }
      }
      groups.append(current)
    }
    return groups.sorted { $0.min()! < $1.min()! }.map { g in g.count == 1 ? lines[g[0]] : merge(g.map { lines[$0] }) }
  }

  /** Pieces of a row, left to right, as one line. */
  private static func merge(_ pieces: [RawLine]) -> RawLine {
    let first = pieces.first!
    let last = pieces.last!
    let length = Double(pieces.reduce(0) { $0 + Swift.max(1, $1.text.count) })
    return RawLine(
      text: pieces.map(\.text).joined(separator: " "),
      confidence: pieces.reduce(0.0) { $0 + $1.confidence * Double(Swift.max(1, $1.text.count)) } / length,
      corners: [first.corners[0], last.corners[1], last.corners[2], first.corners[3]],
      left: pieces.map(\.left).min()!, top: pieces.map(\.top).min()!,
      right: pieces.map(\.right).max()!, bottom: pieces.map(\.bottom).max()!,
      words: pieces.flatMap(\.words))
  }

  /** The spike's join (ReadingOrder.kt / VisionText.join): visual rows top to bottom across the image. */
  static func rowsText(_ lines: [RawLine]) -> String {
    final class R {
      let cy: Double
      let h: Double
      var items: [RawLine] = []
      init(cy: Double, h: Double) { self.cy = cy; self.h = h }
    }
    var rows: [R] = []
    for line in lines.sorted(by: { $0.top + $0.bottom < $1.top + $1.bottom }) {
      let cy = (line.top + line.bottom) / 2
      let h = line.bottom - line.top
      if let row = rows.first(where: { Swift.abs($0.cy - cy) < 0.5 * Swift.min($0.h, h) }) {
        row.items.append(line)
      } else {
        let row = R(cy: cy, h: h)
        row.items.append(line)
        rows.append(row)
      }
    }
    return rows.sorted { $0.cy < $1.cy }
      .map { $0.items.sorted { $0.left < $1.left }.map(\.text).joined(separator: " ") }
      .joined(separator: "\n")
  }

  static func build(
    _ lines: [RawLine], _ imageW: Int, _ imageH: Int, _ output: OcrOutput, _ order: ReadingOrder
  ) -> (text: String, blocks: [OcrBlock]) {
    // `rows` text joins the engine's pieces as the spike did; `blocks` groups their visual lines.
    let groups = group(visualLines(lines))
    let text = order == .rows
      ? rowsText(lines)
      : groups.map { $0.map(\.text).joined(separator: "\n") }.joined(separator: "\n")
    if output == .text { return (text, []) }
    let w = Double(imageW)
    let h = Double(imageH)
    let blocks = groups.map { g -> OcrBlock in
      let lineObjects = g.map { line -> OcrLine in
        let elements: [OcrElement] = output == .elements
          ? line.words.map { word in
            let xs = word.corners.map(\.x)
            let ys = word.corners.map(\.y)
            return OcrElement(
              text: word.text,
              confidence: word.confidence,
              boundingBox: normalizedBox(xs.min()!, ys.min()!, xs.max()!, ys.max()!, w, h),
              pixelBoundingBox: pixelBox(xs.min()!, ys.min()!, xs.max()!, ys.max()!, w, h),
              cornerPoints: normalizedPoints(word.corners, w, h),
              angle: angleOf(word.corners))
          }
          : []
        return OcrLine(
          text: line.text,
          confidence: line.confidence,
          boundingBox: normalizedBox(line.left, line.top, line.right, line.bottom, w, h),
          pixelBoundingBox: pixelBox(line.left, line.top, line.right, line.bottom, w, h),
          cornerPoints: normalizedPoints(line.corners, w, h),
          angle: line.angle,
          elements: elements)
      }
      let angles = g.map(\.angle).sorted()
      let angle = angles[angles.count / 2]
      let length = Double(g.reduce(0) { $0 + Swift.max(1, $1.text.count) })
      let confidence = g.reduce(0.0) { $0 + $1.confidence * Double(Swift.max(1, $1.text.count)) } / length
      let l = g.map(\.left).min()!
      let t = g.map(\.top).min()!
      let r = g.map(\.right).max()!
      let b = g.map(\.bottom).max()!
      return OcrBlock(
        text: g.map(\.text).joined(separator: "\n"),
        confidence: confidence,
        boundingBox: normalizedBox(l, t, r, b, w, h),
        pixelBoundingBox: pixelBox(l, t, r, b, w, h),
        cornerPoints: normalizedPoints(blockCorners(g, angle), w, h),
        angle: angle,
        lines: lineObjects)
    }
    return (text, blocks)
  }

  /** The block's rectangle along its median angle. */
  private static func blockCorners(_ lines: [RawLine], _ angle: Double) -> [Pt] {
    let c = cos(angle * .pi / 180)
    let s = sin(angle * .pi / 180)
    let pts = lines.flatMap(\.corners)
    let us = pts.map { $0.x * c + $0.y * s }
    let vs = pts.map { -$0.x * s + $0.y * c }
    let u0 = us.min()!, u1 = us.max()!, v0 = vs.min()!, v1 = vs.max()!
    func xy(_ u: Double, _ v: Double) -> Pt { Pt(x: u * c - v * s, y: u * s + v * c) }
    return [xy(u0, v0), xy(u1, v0), xy(u1, v1), xy(u0, v1)]
  }

  /** Whole pixels, rounded outwards and clamped to the image, as ML Kit's `Rect`. */
  private static func pixelBox(_ l: Double, _ t: Double, _ r: Double, _ b: Double, _ w: Double, _ h: Double) -> OcrRect {
    let x0 = Swift.min(w, Swift.max(0, l)).rounded(.down)
    let y0 = Swift.min(h, Swift.max(0, t)).rounded(.down)
    let x1 = Swift.min(w, Swift.max(0, r)).rounded(.up)
    let y1 = Swift.min(h, Swift.max(0, b)).rounded(.up)
    return OcrRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }

  /** The same pixel box divided by the image size. */
  private static func normalizedBox(_ l: Double, _ t: Double, _ r: Double, _ b: Double, _ w: Double, _ h: Double) -> OcrRect {
    let p = pixelBox(l, t, r, b, w, h)
    return OcrRect(x: p.x / w, y: p.y / h, width: p.width / w, height: p.height / h)
  }

  private static func normalizedPoints(_ points: [Pt], _ w: Double, _ h: Double) -> [OcrPoint] {
    points.map { OcrPoint(x: clamp01($0.x / w), y: clamp01($0.y / h)) }
  }
}

/** Focus, motion and light of a luma grid; the same arithmetic as FrameMetrics in HybridOcrFrameMeter.kt. */
enum FrameMetrics {
  static let grid = 256

  static func gridSize(_ w: Double, _ h: Double) -> (Int, Int) {
    let long = Swift.min(Double(grid), Swift.max(w, h))
    let gw = Swift.max(3, Int((w / Swift.max(w, h) * long).rounded()))
    let gh = Swift.max(3, Int((h / Swift.max(w, h) * long).rounded()))
    return (gw, gh)
  }

  static func measure(_ luma: [Float], _ gw: Int, _ gh: Int, _ previous: [Float]?) -> FrameQuality {
    var sum = 0.0
    for v in luma { sum += Double(v) }
    let brightness = sum / Double(luma.count) / 255
    var n = 0
    var s1 = 0.0
    var s2 = 0.0
    if gh > 2 && gw > 2 {
      for y in 1..<(gh - 1) {
        for x in 1..<(gw - 1) {
          let i = y * gw + x
          let lap = Double(4 * luma[i] - luma[i - 1] - luma[i + 1] - luma[i - gw] - luma[i + gw])
          s1 += lap
          s2 += lap * lap
          n += 1
        }
      }
    }
    let mean = n > 0 ? s1 / Double(n) : 0
    let sharpness = n > 0 ? s2 / Double(n) - mean * mean : 0
    var motion = 1.0
    if let previous, previous.count == luma.count {
      var d = 0.0
      for i in 0..<luma.count { d += Double(Swift.abs(luma[i] - previous[i])) }
      motion = d / Double(luma.count) / 255
    }
    return FrameQuality(sharpness: sharpness, motion: motion, brightness: brightness)
  }
}
