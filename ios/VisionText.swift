import CoreGraphics
import Foundation
import ImageIO
import Vision

/**
 * Apple Vision text recognition: VNRecognizeTextRequest revision 3, accurate level. Plain Swift
 * without Nitro, so the same code also builds on macOS to measure quality.
 */
@available(iOS 16.0, *)
enum VisionText {
  struct Settings: Sendable {
    let usesLanguageCorrection: Bool
    /** In priority order, e.g. ["ru-RU", "en-US"]. */
    let languages: [String]
  }

  struct Line {
    let text: String
    let confidence: Float
    /** Bounds in the decoded image, px, origin at the top left. */
    let left: Double
    let top: Double
    let right: Double
    let bottom: Double
  }

  /** Reads the photo turned upright by its EXIF orientation, longer side at most `maxSide` (0 = full size). */
  static func decode(_ url: URL, maxSide: Int) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { throw VisionTextError("Cannot read image: \(url.path)") }
    // `Swift.` everywhere: with C++ interop on (Nitro), the C++ min/max/abs make bare calls ambiguous.
    let side = maxSide > 0 ? Swift.min(maxSide, Swift.max(w, h)) : Swift.max(w, h)
    // The thumbnail API applies the EXIF orientation and scales in one pass; it never upscales.
    guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: side,
      kCGImageSourceShouldCacheImmediately: true,
    ] as CFDictionary)
    else { throw VisionTextError("Cannot decode image: \(url.path)") }
    return image
  }

  static func makeRequest(_ settings: Settings) -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLevel = .accurate
    request.recognitionLanguages = settings.languages
    request.usesLanguageCorrection = settings.usesLanguageCorrection
    return request
  }

  static func recognize(_ image: CGImage, _ settings: Settings) throws -> [Line] {
    let request = makeRequest(settings)
    try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
    let w = Double(image.width)
    let h = Double(image.height)
    return (request.results ?? []).compactMap { obs in
      guard let best = obs.topCandidates(1).first else { return nil }
      let b = obs.boundingBox // normalized, origin at the bottom left
      return Line(
        text: best.string, confidence: best.confidence,
        left: b.minX * w, top: (1 - b.maxY) * h, right: b.maxX * w, bottom: (1 - b.minY) * h
      )
    }
  }

  /**
   * Boxes whose vertical centers are close are one visual row (joined with spaces, left to right);
   * rows are separated by newlines, top to bottom. The same rule as the Android spike's ReadingOrder.kt.
   */
  static func join(_ lines: [Line]) -> String {
    final class Row {
      let cy: Double
      let h: Double
      var items: [Line] = []
      init(cy: Double, h: Double) { self.cy = cy; self.h = h }
    }
    var rows: [Row] = []
    for line in lines.sorted(by: { $0.top + $0.bottom < $1.top + $1.bottom }) {
      let cy = (line.top + line.bottom) / 2
      let h = line.bottom - line.top
      if let row = rows.first(where: { (r: Row) -> Bool in Swift.abs(r.cy - cy) < 0.5 * Swift.min(r.h, h) }) {
        row.items.append(line)
      } else {
        let row = Row(cy: cy, h: h)
        row.items.append(line)
        rows.append(row)
      }
    }
    let texts: [String] = rows.sorted { $0.cy < $1.cy }.map { (row: Row) -> String in
      row.items.sorted { $0.left < $1.left }.map(\.text).joined(separator: " ")
    }
    return texts.joined(separator: "\n")
  }
}

struct VisionTextError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}
