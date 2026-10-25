import Foundation

/**
 * A text line found on the DB probability map, described as a sampler: a point (u, v) in the
 * line's own frame (u along the text, v across it, map px) maps to the source image. The same
 * code as TextLines.kt on Android.
 *
 * Straight lines are a rotated rectangle. Curved lines (labels on cans and bottles) keep a
 * smoothed centerline v = center(u), so the crop follows the curve instead of cutting
 * through neighbouring lines.
 */
struct TextLine {
  let cx: Float
  let cy: Float
  let cos: Float
  let sin: Float
  let u0: Float
  let u1: Float
  let binOrigin: Float
  let centers: [Float]?
  let centerConst: Float
  let halfHeight: Float
  let scaleX: Float
  let scaleY: Float
  let vertical: Bool

  func centerAt(_ u: Float) -> Float {
    guard let c = centers else { return centerConst }
    let i = Swift.min(Swift.max(Int((u - binOrigin).rounded(.down)), 0), c.count - 1)
    return c[i]
  }

  func srcX(_ u: Float, _ v: Float) -> Float { (cx + u * cos - v * sin) * scaleX }
  func srcY(_ u: Float, _ v: Float) -> Float { (cy + u * sin + v * cos) * scaleY }

  /** A point on the text's top or bottom edge at `share` (0..1) of its length, in source px. */
  func edgePoint(_ share: Float, top: Bool) -> (Float, Float) {
    let u = u0 + share * (u1 - u0)
    let c = centerAt(u)
    let v = vertical == top ? c + halfHeight : c - halfHeight
    return (srcX(u, v), srcY(u, v))
  }

  /** The same line read the other way: turned 180°, for upside-down text. (u, v) here is (-u, -v) there. */
  func flipped() -> TextLine {
    TextLine(
      cx: cx, cy: cy, cos: -cos, sin: -sin, u0: -u1, u1: -u0,
      binOrigin: centers.map { -(binOrigin + Float($0.count)) } ?? binOrigin,
      centers: centers.map { c in (0..<c.count).map { -c[c.count - 1 - $0] } },
      centerConst: -centerConst, halfHeight: halfHeight, scaleX: scaleX, scaleY: scaleY, vertical: vertical)
  }

  /** The middle of the line, at most `heights` line heights long. */
  func middle(_ heights: Float) -> TextLine {
    let half = heights * halfHeight
    let uc = (u0 + u1) / 2
    if uc - half <= u0 { return self }
    return TextLine(
      cx: cx, cy: cy, cos: cos, sin: sin, u0: uc - half, u1: uc + half, binOrigin: binOrigin, centers: centers,
      centerConst: centerConst, halfHeight: halfHeight, scaleX: scaleX, scaleY: scaleY, vertical: vertical)
  }

  /** Length along the text and height across it, in source px. */
  var lengthSrc: Float { (u1 - u0) * scaleX }
  var heightSrc: Float { 2 * halfHeight * scaleY }
}

/** DB post-processing: probability map -> text lines. Mirrors PaddleOCR's DBPostProcess thresholds. */
enum TextLineFinder {
  private static let minSize: Float = 3
  private static let maxCandidates = 1000

  static func find(
    _ prob: [Float], _ mapW: Int, _ mapH: Int, _ srcW: Int, _ srcH: Int,
    thresh: Float, boxThresh: Float, unclipRatio: Float
  ) -> [TextLine] {
    let n = mapW * mapH
    var visited = [Bool](repeating: false, count: n)
    var queue = [Int](repeating: 0, count: n)
    let scaleX = Float(srcW) / Float(mapW)
    let scaleY = Float(srcH) / Float(mapH)
    var lines: [TextLine] = []
    var candidates = 0
    for seed in 0..<n {
      if visited[seed] || prob[seed] <= thresh { continue }
      // 8-connected flood fill; the component's pixels end up in queue[0..<size].
      var head = 0
      var size = 0
      queue[size] = seed
      size += 1
      visited[seed] = true
      while head < size {
        let p = queue[head]
        head += 1
        let px = p % mapW
        let py = p / mapW
        for dy in -1...1 {
          let y = py + dy
          if y < 0 || y >= mapH { continue }
          for dx in -1...1 {
            let x = px + dx
            if x < 0 || x >= mapW { continue }
            let q = y * mapW + x
            if !visited[q] && prob[q] > thresh {
              visited[q] = true
              queue[size] = q
              size += 1
            }
          }
        }
      }
      if Float(size) < minSize * minSize { continue }
      candidates += 1
      if candidates > maxCandidates { break }
      if let line = analyze(queue, size, prob, mapW, boxThresh, unclipRatio, scaleX, scaleY) {
        lines.append(line)
      }
    }
    return lines
  }

  private static func analyze(
    _ pixels: [Int], _ size: Int, _ prob: [Float], _ mapW: Int, _ boxThresh: Float, _ unclipRatio: Float,
    _ scaleX: Float, _ scaleY: Float
  ) -> TextLine? {
    // Score: mean probability over the component (PaddleOCR's "slow" score mode).
    var sumP = 0.0
    var sumX = 0.0
    var sumY = 0.0
    for k in 0..<size {
      let p = pixels[k]
      sumP += Double(prob[p])
      sumX += Double(p % mapW)
      sumY += Double(p / mapW)
    }
    if sumP / Double(size) < Double(boxThresh) { return nil }
    let cx = Float(sumX / Double(size))
    let cy = Float(sumY / Double(size))

    // Main axis from the covariance of pixel coordinates.
    var cxx = 0.0
    var cyy = 0.0
    var cxy = 0.0
    for k in 0..<size {
      let p = pixels[k]
      let dx = Double(Float(p % mapW) - cx)
      let dy = Double(Float(p / mapW) - cy)
      cxx += dx * dx
      cyy += dy * dy
      cxy += dx * dy
    }
    var theta = 0.5 * atan2(2 * cxy, cxx - cyy)
    var vertical = false
    if Swift.abs(theta) > Double.pi / 4 {
      let (l, t) = extents(pixels, size, mapW, cx, cy, theta)
      if l >= 1.5 * t {
        vertical = true
        // u must point down the image so that the crop reads like PaddleOCR's rot90 crop.
        if Foundation.sin(theta) < 0 { theta += Double.pi }
      } else {
        theta -= theta < 0 ? -Double.pi / 2 : Double.pi / 2
      }
    }
    let c = Float(Foundation.cos(theta))
    let s = Float(Foundation.sin(theta))

    var umin = Float.greatestFiniteMagnitude
    var umax = -Float.greatestFiniteMagnitude
    var vmin = Float.greatestFiniteMagnitude
    var vmax = -Float.greatestFiniteMagnitude
    for k in 0..<size {
      let p = pixels[k]
      let dx = Float(p % mapW) - cx
      let dy = Float(p / mapW) - cy
      let u = dx * c + dy * s
      let v = -dx * s + dy * c
      umin = Swift.min(umin, u)
      umax = Swift.max(umax, u)
      vmin = Swift.min(vmin, v)
      vmax = Swift.max(vmax, v)
    }
    let len = umax - umin + 1
    let thick = vmax - vmin + 1
    if Swift.min(len, thick) < minSize { return nil }

    // Per-column profile across the text: local thickness and centerline.
    let bins = Int((umax - umin).rounded(.down)) + 1
    var lo = [Float](repeating: Float.greatestFiniteMagnitude, count: bins)
    var hi = [Float](repeating: -Float.greatestFiniteMagnitude, count: bins)
    for k in 0..<size {
      let p = pixels[k]
      let dx = Float(p % mapW) - cx
      let dy = Float(p / mapW) - cy
      let u = dx * c + dy * s
      let v = -dx * s + dy * c
      let b = Swift.min(Swift.max(Int((u - umin).rounded(.down)), 0), bins - 1)
      if v < lo[b] { lo[b] = v }
      if v > hi[b] { hi[b] = v }
    }
    var filled = 0
    var sumT: Float = 0
    for b in 0..<bins where lo[b] <= hi[b] {
      filled += 1
      sumT += hi[b] - lo[b] + 1
    }
    let colThick = sumT / Float(Swift.max(1, filled))

    let curved = !vertical && thick > 1.3 * colThick && len > 4 * colThick
    let centers: [Float]?
    let d: Float
    let halfHeight: Float
    if curved {
      centers = smoothedCenterline(lo, hi, Swift.max(3, Int(colThick.rounded())))
      d = len * colThick * unclipRatio / (2 * (len + colThick))
      halfHeight = colThick / 2 + d
    } else {
      centers = nil
      // Unclip like PaddleOCR: grow the rectangle by area * ratio / perimeter on every side.
      d = len * thick * unclipRatio / (2 * (len + thick))
      halfHeight = thick / 2 + d
    }
    if 2 * halfHeight < minSize + 2 { return nil }
    return TextLine(
      cx: cx, cy: cy, cos: c, sin: s, u0: umin - d, u1: umax + d, binOrigin: umin, centers: centers,
      centerConst: (vmin + vmax) / 2, halfHeight: halfHeight, scaleX: scaleX, scaleY: scaleY, vertical: vertical)
  }

  private static func extents(_ pixels: [Int], _ size: Int, _ mapW: Int, _ cx: Float, _ cy: Float, _ theta: Double) -> (Float, Float) {
    let c = Float(Foundation.cos(theta))
    let s = Float(Foundation.sin(theta))
    var umin = Float.greatestFiniteMagnitude
    var umax = -Float.greatestFiniteMagnitude
    var vmin = Float.greatestFiniteMagnitude
    var vmax = -Float.greatestFiniteMagnitude
    for k in 0..<size {
      let p = pixels[k]
      let dx = Float(p % mapW) - cx
      let dy = Float(p / mapW) - cy
      let u = dx * c + dy * s
      let v = -dx * s + dy * c
      umin = Swift.min(umin, u)
      umax = Swift.max(umax, u)
      vmin = Swift.min(vmin, v)
      vmax = Swift.max(vmax, v)
    }
    return (umax - umin + 1, vmax - vmin + 1)
  }

  /** Column midpoints, gaps linearly interpolated, then a moving average of `window` columns. */
  private static func smoothedCenterline(_ lo: [Float], _ hi: [Float], _ window: Int) -> [Float] {
    let n = lo.count
    var mid = [Float](repeating: .nan, count: n)
    for b in 0..<n where lo[b] <= hi[b] { mid[b] = (lo[b] + hi[b]) / 2 }
    var prev = -1
    for b in 0..<n {
      if mid[b].isNaN { continue }
      if prev == -1 {
        for k in 0..<b { mid[k] = mid[b] }
      } else if b - prev > 1 {
        for k in (prev + 1)..<b { mid[k] = mid[prev] + (mid[b] - mid[prev]) * Float(k - prev) / Float(b - prev) }
      }
      prev = b
    }
    if prev >= 0 && prev + 1 < n { for k in (prev + 1)..<n { mid[k] = mid[prev] } }

    var out = [Float](repeating: 0, count: n)
    let left = window / 2
    let right = window - 1 - left
    for b in 0..<n {
      var acc: Float = 0
      for k in (b - left)...(b + right) { acc += mid[Swift.min(Swift.max(k, 0), n - 1)] }
      out[b] = acc / Float(window)
    }
    return out
  }
}
