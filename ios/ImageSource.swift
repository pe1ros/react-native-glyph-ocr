import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import NitroModules
import Photos

/**
 * What the engine reads: the upright ROI of the source, downscaled to `maxImageSide`, plus where
 * it sits in the whole upright image so that results can be mapped back.
 */
struct EngineInput {
  let image: CGImage
  /** The whole upright source. */
  let imageWidth: Int
  let imageHeight: Int
  /** Origin of `image` in the downscaled whole image, and the scale of that image. */
  let originX: Double
  let originY: Double
  let scaleX: Double
  let scaleY: Double
  let decodeMs: Double

  func toImage(_ x: Double, _ y: Double) -> Pt {
    Pt(x: (originX + x) / scaleX, y: (originY + y) / scaleY)
  }
}

/** Decodes every source kind into an EngineInput. EXIF is applied unless `orientation` overrides it. */
enum ImageSource {
  static let defaultMaxSide = 2000

  static func maxSide(_ value: Double?) -> Int {
    guard let value, value >= 0 else { return defaultMaxSide }
    return Int(value)
  }

  /** A path, `file://` or `ph://<localIdentifier>`. */
  static func fromUri(_ uri: String, _ options: RecognizeOptions) throws -> EngineInput {
    if uri.hasPrefix("ph://") {
      return try decode(photosAsset(String(uri.dropFirst(5))), options)
    }
    if uri.hasPrefix("content://") {
      throw OcrError("unsupported-source", "content:// is Android only", ["uri": uri])
    }
    if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
      throw OcrError("unsupported-source", "Download the image to a file first", ["uri": uri])
    }
    if uri.hasPrefix("data:") {
      throw OcrError("unsupported-source", "Pass data URIs as base64")
    }
    let url: URL
    if uri.hasPrefix("file://"), let u = URL(string: uri), u.isFileURL {
      url = u
    } else if uri.hasPrefix("/") {
      url = URL(fileURLWithPath: uri)
    } else {
      throw OcrError("unsupported-source", "Unsupported URI \(uri)", ["uri": uri])
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw OcrError("source-not-found", "No file at \(url.path)", ["uri": uri])
    }
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      throw OcrError("source-permission-denied", "Cannot read \(url.path)", ["uri": uri])
    }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw OcrError("decode-failed", "Not an image: \(url.path)")
    }
    return try decode(src, options)
  }

  static func fromBase64(_ base64: String, _ options: RecognizeOptions) throws -> EngineInput {
    guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
      throw OcrError("decode-failed", "Not base64")
    }
    return try decode(data, options)
  }

  static func decode(_ data: Data, _ options: RecognizeOptions) throws -> EngineInput {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw OcrError("decode-failed", "Not an image")
    }
    return try decode(src, options)
  }

  /** Image data of a Photos asset, without the network: an iCloud-only photo is `source-not-found`. */
  private static func photosAsset(_ id: String) throws -> Data {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status == .authorized || status == .limited else {
      throw OcrError("source-permission-denied", "No access to Photos (\(status.rawValue))")
    }
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
      throw OcrError("source-not-found", "No Photos asset \(id)", ["uri": "ph://\(id)"])
    }
    let options = PHImageRequestOptions()
    options.isNetworkAccessAllowed = false
    options.isSynchronous = true
    options.deliveryMode = .highQualityFormat
    options.version = .current
    var result: Data?
    var inCloud = false
    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
      result = data
      inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
    }
    guard let data = result else {
      throw OcrError(
        "source-not-found", inCloud ? "The photo is only in iCloud" : "Cannot read the Photos asset", ["uri": "ph://\(id)"])
    }
    return data
  }

  /**
   * The thumbnail API applies EXIF and scales in one pass (the spike's decode), so the whole image
   * is decoded at the scale the ROI needs and then cropped.
   */
  private static func decode(_ src: CGImageSource, _ options: RecognizeOptions) throws -> EngineInput {
    let t0 = DispatchTime.now().uptimeNanoseconds
    guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
      let rawW = props[kCGImagePropertyPixelWidth] as? Int,
      let rawH = props[kCGImagePropertyPixelHeight] as? Int, rawW > 0, rawH > 0
    else { throw OcrError("decode-failed", "Not an image, or a corrupt one") }
    let fileExif = (props[kCGImagePropertyOrientation] as? Int) ?? 1
    let override = options.orientation.flatMap { Exif.of($0) }
    let exif = override ?? fileExif
    let w = Exif.sideways(exif) ? rawH : rawW
    let h = Exif.sideways(exif) ? rawW : rawH
    let crop = try Regions.resolve(options.roi, w, h)
    let area = crop ?? RectD(x: 0, y: 0, w: Double(w), h: Double(h))
    let maxSide = maxSide(options.maxImageSide)
    let longArea = Swift.max(area.w, area.h)
    let scale = maxSide > 0 ? Swift.min(1, Double(maxSide) / longArea) : 1
    // `Swift.` everywhere: with C++ interop on (Nitro), the C++ min/max/abs make bare calls ambiguous.
    let side = Swift.max(1, Int((Double(Swift.max(w, h)) * scale).rounded()))
    guard var image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: override == nil,
      kCGImageSourceThumbnailMaxPixelSize: side,
      kCGImageSourceShouldCacheImmediately: true,
    ] as CFDictionary)
    else { throw OcrError("decode-failed", "Cannot decode the image") }
    if let override, override != 1 {
      image = try upright(image, override)
    }
    let sx = Double(image.width) / Double(w)
    let sy = Double(image.height) / Double(h)
    var originX = 0.0
    var originY = 0.0
    if let crop {
      let rect = CGRect(
        x: (crop.x * sx).rounded(.down), y: (crop.y * sy).rounded(.down),
        width: Swift.max(1, (crop.w * sx).rounded()), height: Swift.max(1, (crop.h * sy).rounded())
      ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
      guard let cropped = image.cropping(to: rect) else { throw OcrError("internal", "Cannot crop the image") }
      image = cropped
      originX = rect.minX
      originY = rect.minY
    }
    return EngineInput(
      image: image, imageWidth: w, imageHeight: h, originX: originX, originY: originY, scaleX: sx, scaleY: sy,
      decodeMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
  }

  /** Raw pixels, copied into RGBX before the call returns. `orientation` says how they are stored. */
  static func copyPixels(_ pixels: ArrayBuffer, _ width: Int, _ height: Int, _ bytesPerRow: Int, _ format: RawPixelFormat) throws -> CGImage {
    let bpp = format == .rgb || format == .bgr ? 3 : 4
    guard width > 0, height > 0, bytesPerRow >= width * bpp, pixels.size >= bytesPerRow * (height - 1) + width * bpp else {
      throw OcrError("invalid-argument", "Pixel buffer is smaller than \(width)x\(height) (\(format.stringValue), \(bytesPerRow) bytes per row)")
    }
    var out = [UInt8](repeating: 255, count: width * height * 4)
    let src = pixels.data
    for y in 0..<height {
      var p = y * bytesPerRow
      var o = y * width * 4
      for _ in 0..<width {
        let b0 = src[p], b1 = src[p + 1], b2 = src[p + 2]
        let b3: UInt8 = bpp == 4 ? src[p + 3] : 0
        let rgb: (UInt8, UInt8, UInt8)
        switch format {
        case .rgba, .rgb: rgb = (b0, b1, b2)
        case .bgra, .bgr: rgb = (b2, b1, b0)
        case .argb: rgb = (b1, b2, b3)
        case .abgr: rgb = (b3, b2, b1)
        @unknown default: rgb = (b0, b1, b2)
        }
        out[o] = rgb.0
        out[o + 1] = rgb.1
        out[o + 2] = rgb.2
        p += bpp
        o += 4
      }
    }
    guard let provider = CGDataProvider(data: Data(out) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw OcrError("internal", "Cannot wrap the pixels") }
    return image
  }

  static func fromImage(_ stored: CGImage, _ options: RecognizeOptions) throws -> EngineInput {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let exif = options.orientation.flatMap { Exif.of($0) } ?? 1
    var image = exif == 1 ? stored : try upright(stored, exif)
    let w = image.width
    let h = image.height
    let crop = try Regions.resolve(options.roi, w, h)
    let area = crop ?? RectD(x: 0, y: 0, w: Double(w), h: Double(h))
    if crop != nil {
      guard let cropped = image.cropping(to: CGRect(x: area.x, y: area.y, width: area.w, height: area.h)) else {
        throw OcrError("internal", "Cannot crop the image")
      }
      image = cropped
    }
    let maxSide = maxSide(options.maxImageSide)
    let long = Swift.max(area.w, area.h)
    var scale = 1.0
    if maxSide > 0, Double(maxSide) < long {
      scale = Double(maxSide) / long
      image = try resized(image, Int((area.w * scale).rounded()), Int((area.h * scale).rounded()))
    }
    let sx = Double(image.width) / area.w
    let sy = Double(image.height) / area.h
    return EngineInput(
      image: image, imageWidth: w, imageHeight: h, originX: area.x * sx, originY: area.y * sy, scaleX: sx, scaleY: sy,
      decodeMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
  }

  private static let ciContext = CIContext(options: [.cacheIntermediates: false])

  /** Stored pixels turned upright, as Core Image reads an EXIF orientation. */
  static func upright(_ image: CGImage, _ exif: Int) throws -> CGImage {
    guard exif != 1, let o = CGImagePropertyOrientation(rawValue: UInt32(exif)) else { return image }
    let turned = CIImage(cgImage: image).oriented(o)
    guard let out = ciContext.createCGImage(turned, from: turned.extent) else {
      throw OcrError("out-of-memory", "Cannot turn a \(image.width)x\(image.height) image")
    }
    return out
  }

  static func resized(_ image: CGImage, _ w: Int, _ h: Int) throws -> CGImage {
    guard let ctx = context(Swift.max(1, w), Swift.max(1, h)) else { throw OcrError("out-of-memory", "Cannot allocate \(w)x\(h)") }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: Swift.max(1, w), height: Swift.max(1, h)))
    guard let out = ctx.makeImage() else { throw OcrError("internal", "Cannot resize the image") }
    return out
  }

  static func context(_ w: Int, _ h: Int) -> CGContext? {
    CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  }
}
