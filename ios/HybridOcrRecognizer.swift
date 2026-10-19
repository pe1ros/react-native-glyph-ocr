import CoreVideo
import Foundation
import NitroModules
import UIKit
import Vision

/**
 * Apple Vision with one language set. Requests run one at a time on the recognizer's serial
 * queue; `recognizeFrame` runs synchronously on that queue too, so a frame waits for a photo.
 */
@available(iOS 16.0, *)
final class HybridOcrRecognizer: HybridOcrRecognizerSpec {
  let engine: OcrEngine = .vision
  let languages: [String]
  let packId: String? = nil
  /** `recognitionLanguages` of the request, e.g. `["ru-RU", "en-US"]`. */
  private let engineLanguages: [String]
  private let customWords: [String]

  private let queue = DispatchQueue(label: "GlyphOcr.vision", qos: .userInitiated)
  private let lock = NSLock()
  private var loaded = false
  private var warmedUp = false
  private var disposed = false
  private var cancelled = Set<Double>()
  private var running: (id: Double, request: VNRequest)?

  init(languages: [String], engineLanguages: [String], customWords: [String]) {
    self.languages = languages
    self.engineLanguages = engineLanguages
    self.customWords = customWords
    super.init()
  }

  /** Vision ships with iOS: nothing to download. */
  var isReady: Bool { true }
  var isLoaded: Bool { lock.locked { loaded } }

  func load(warmUp: Bool, onProgress: @escaping (_ progress: PrepareProgress) -> Void, requestId: Double) throws -> Promise<LoadResult> {
    return Promise.parallel(queue) { [self] in
      try begin(requestId)
      defer { end(requestId) }
      var warmMs = 0.0
      if warmUp && !lock.locked({ warmedUp }) {
        onProgress(PrepareProgress(phase: .warmingUp, receivedBytes: 0, totalBytes: 0, fraction: 0, fileId: ""))
        warmMs = try warm()
      }
      lock.locked { loaded = true }
      onProgress(PrepareProgress(phase: warmUp ? .warmingUp : .loading, receivedBytes: 0, totalBytes: 0, fraction: 1, fileId: ""))
      return LoadResult(downloadedBytes: 0, loadMs: 0, warmUpMs: warmMs)
    }
  }

  /** The first Vision call loads its models (0.5 s on iPhone 13 Pro Max): pay it on a drawn label. */
  private func warm() throws -> Double {
    let size = CGSize(width: 960, height: 320)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
      UIColor.white.setFill()
      ctx.fill(CGRect(origin: .zero, size: size))
      let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 44), .foregroundColor: UIColor.black]
      for (i, s) in ["Состав: вода, сахар, соль,", "лимонная кислота E330.", "Ingredients: water, sugar"].enumerated() {
        (s as NSString).draw(at: CGPoint(x: 40, y: 30 + CGFloat(i) * 90), withAttributes: attrs)
      }
    }
    guard let cg = image.cgImage else { return 0 }
    let t0 = DispatchTime.now().uptimeNanoseconds
    let request = VisionEngine.makeRequest(VisionOptions(nil as FrameRecognizeOptions?), engineLanguages, customWords)
    try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([request])
    lock.locked { warmedUp = true }
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
  }

  func recognizeUri(uri: String, options: RecognizeOptions, requestId: Double) throws -> Promise<OcrResult> {
    return queued(requestId, VisionOptions(options)) { try ImageSource.fromUri(uri, options) }
  }

  func recognizeBase64(base64: String, options: RecognizeOptions, requestId: Double) throws -> Promise<OcrResult> {
    return queued(requestId, VisionOptions(options)) { try ImageSource.fromBase64(base64, options) }
  }

  func recognizePixels(
    pixels: ArrayBuffer, width: Double, height: Double, bytesPerRow: Double, format: RawPixelFormat,
    options: RecognizeOptions, requestId: Double
  ) throws -> Promise<OcrResult> {
    // Copied now: the ArrayBuffer belongs to JS and may be gone once this returns.
    let stored = try ImageSource.copyPixels(pixels, Int(width), Int(height), Int(bytesPerRow), format)
    return queued(requestId, VisionOptions(options)) { try ImageSource.fromImage(stored, options) }
  }

  private func queued(_ requestId: Double, _ o: VisionOptions, _ decode: @escaping () throws -> EngineInput) -> Promise<OcrResult> {
    return Promise.parallel(queue) { [self] in
      // Vision and ImageIO autorelease a lot; drain after every photo, or a long batch run grows.
      try autoreleasepool {
        try begin(requestId)
        defer { end(requestId) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let input = try decode()
        try throwIfCancelled(requestId)
        let request = VisionEngine.makeRequest(o, engineLanguages, customWords)
        try VisionEngine.checkLevel(o, engineLanguages)
        let iw = Double(input.image.width)
        let ih = Double(input.image.height)
        let handler = VNImageRequestHandler(cgImage: input.image, orientation: .up)
        let tr = DispatchTime.now().uptimeNanoseconds
        try perform(handler, request, requestId)
        let recognizeMs = Double(DispatchTime.now().uptimeNanoseconds - tr) / 1e6
        let lines = VisionEngine.lines(request, o) { p in input.toImage(Double(p.x) * iw, (1.0 - Double(p.y)) * ih) }
        return result(
          lines, input.imageWidth, input.imageHeight, o, input.decodeMs, recognizeMs, t0,
          inputWidth: input.image.width, inputHeight: input.image.height, candidates: request.results?.count ?? 0)
      }
    }
  }

  func recognizeFrame(nativeBufferPointer: UInt64, orientation: FrameOrientation, options: FrameRecognizeOptions?) throws -> OcrResult {
    guard let raw = UnsafeRawPointer(bitPattern: UInt(nativeBufferPointer)) else {
      throw OcrError("frame-unsupported", "Null buffer pointer")
    }
    let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(raw).takeUnretainedValue()
    return try queue.sync {
      try autoreleasepool {
        if lock.locked({ disposed }) { throw OcrError("disposed", "The recognizer was disposed") }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let o = VisionOptions(options)
        let exif = Exif.of(orientation, mirrored: options?.mirrored ?? false)
        let rawW = CVPixelBufferGetWidth(buffer)
        let rawH = CVPixelBufferGetHeight(buffer)
        let w = Exif.sideways(exif) ? rawH : rawW
        let h = Exif.sideways(exif) ? rawW : rawH
        let area = try Regions.resolve(options?.roi, w, h) ?? RectD(x: 0, y: 0, w: Double(w), h: Double(h))
        let request = VisionEngine.makeRequest(o, engineLanguages, customWords)
        try VisionEngine.checkLevel(o, engineLanguages)
        // Vision's region is normalized to the upright image, origin at the bottom left; results
        // are normalized to the region.
        let roi = CGRect(
          x: area.x / Double(w), y: 1 - area.bottom / Double(h), width: area.w / Double(w), height: area.h / Double(h))
        request.regionOfInterest = roi
        let handler = VNImageRequestHandler(
          cvPixelBuffer: buffer, orientation: CGImagePropertyOrientation(rawValue: UInt32(exif)) ?? .up, options: [:])
        let tr = DispatchTime.now().uptimeNanoseconds
        try perform(handler, request, 0)
        let recognizeMs = Double(DispatchTime.now().uptimeNanoseconds - tr) / 1e6
        let rx = Double(roi.minX), ry = Double(roi.minY), rw = Double(roi.width), rh = Double(roi.height)
        let lines = VisionEngine.lines(request, o) { p in
          let x: Double = rx + Double(p.x) * rw
          let y: Double = ry + Double(p.y) * rh
          return Pt(x: x * Double(w), y: (1.0 - y) * Double(h))
        }
        lock.locked { loaded = true }
        return result(
          lines, w, h, o, 0, recognizeMs, t0, inputWidth: Int(area.w), inputHeight: Int(area.h),
          candidates: request.results?.count ?? 0)
      }
    }
  }

  private func perform(_ handler: VNImageRequestHandler, _ request: VNRecognizeTextRequest, _ requestId: Double) throws {
    lock.locked { running = (requestId, request) }
    defer { lock.locked { running = nil } }
    do {
      try handler.perform([request])
    } catch {
      if requestId > 0, lock.locked({ cancelled.contains(requestId) }) {
        throw OcrError("cancelled", "Cancelled")
      }
      throw OcrError("internal", "Vision: \(error.localizedDescription)")
    }
    try throwIfCancelled(requestId)
    lock.locked { loaded = true }
  }

  private func result(
    _ lines: [RawLine], _ w: Int, _ h: Int, _ o: VisionOptions, _ decodeMs: Double, _ recognizeMs: Double, _ t0: UInt64,
    inputWidth: Int, inputHeight: Int, candidates: Int
  ) -> OcrResult {
    let built = ResultBuilder.build(lines, w, h, o.output, o.readingOrder)
    return OcrResult(
      text: built.text,
      blocks: built.blocks,
      image: OcrImageSize(width: Double(w), height: Double(h)),
      engine: .vision,
      languages: languages,
      timings: OcrTimings(
        decodeMs: decodeMs, recognizeMs: recognizeMs, totalMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6),
      diagnostics: o.diagnostics
        ? OcrDiagnostics(
          runtime: "vision-rev3", inputWidth: Double(inputWidth), inputHeight: Double(inputHeight), detectorMs: 0,
          recognizerMs: recognizeMs, detectorInputWidth: 0, detectorInputHeight: 0, candidateLines: Double(candidates))
        : nil)
  }

  func cancel(requestId: Double) throws {
    lock.locked {
      cancelled.insert(requestId)
      if let running, running.id == requestId { running.request.cancel() }
    }
  }

  private func begin(_ requestId: Double) throws {
    try lock.locked {
      if disposed { throw OcrError("disposed", "The recognizer was disposed") }
      if cancelled.remove(requestId) != nil { throw OcrError("cancelled", "Cancelled before start") }
    }
  }

  private func end(_ requestId: Double) {
    _ = lock.locked { cancelled.remove(requestId) }
  }

  private func throwIfCancelled(_ requestId: Double) throws {
    if requestId > 0, lock.locked({ cancelled.contains(requestId) }) { throw OcrError("cancelled", "Cancelled") }
  }

  func dispose() {
    lock.locked { disposed = true }
  }
}
