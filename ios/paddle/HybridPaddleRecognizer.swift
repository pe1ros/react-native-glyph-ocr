#if GLYPHOCR_PADDLE
import CoreImage
import CoreVideo
import Foundation
import NitroModules
import UIKit

/** Options of one Paddle call; detector defaults depend on the pack's family, as on Android. */
struct PaddleCallOptions {
  var level: RecognitionLevel
  var minConfidence: Double
  var readingOrder: ReadingOrder
  var output: OcrOutput
  var diagnostics: Bool
  var textlineOrientation: Bool
  var tuning: PaddleTuning?

  init(_ o: RecognizeOptions) {
    level = o.recognitionLevel ?? .accurate
    minConfidence = o.minConfidence ?? 0.5
    readingOrder = o.readingOrder ?? .blocks
    output = o.output ?? .elements
    diagnostics = o.diagnostics ?? false
    textlineOrientation = o.textlineOrientation ?? true
    tuning = o.paddle
  }

  init(_ o: FrameRecognizeOptions?) {
    level = o?.recognitionLevel ?? .accurate
    minConfidence = o?.minConfidence ?? 0.5
    readingOrder = o?.readingOrder ?? .blocks
    output = o?.output ?? .elements
    diagnostics = o?.diagnostics ?? false
    textlineOrientation = o?.textlineOrientation ?? true
    tuning = o?.paddle
  }

  func engine(v6: Bool) -> PaddleOcr.Options {
    let side = tuning?.detectorSide.map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
    return PaddleOcr.Options(
      detLimitSide: side ?? (level == .fast ? 736 : 960),
      detThresh: Float(tuning?.detectorThreshold ?? (v6 ? 0.2 : 0.3)),
      boxThresh: Float(tuning?.boxThreshold ?? (v6 ? 0.4 : 0.6)),
      unclipRatio: Float(tuning?.unclipRatio ?? (v6 ? 1.4 : 1.5)),
      dropScore: Float(minConfidence),
      textlineOrientation: textlineOrientation)
  }
}

/**
 * PaddleOCR with one model pack on iOS (the `GlyphOcr_paddleOnIos` build): for the languages Vision
 * does not read, or the same engine on both platforms. Requests run one at a time on the
 * recognizer's serial queue; `recognizeFrame` runs synchronously on that queue too.
 */
final class HybridPaddleRecognizer: HybridOcrRecognizerSpec {
  let engine: OcrEngine = .paddle
  let languages: [String]
  var packId: String? { pack.id }
  private let pack: ModelPack
  private let threads: Int
  private let v6: Bool

  private let queue = DispatchQueue(label: "GlyphOcr.paddle", qos: .userInitiated)
  private let lock = NSLock()
  private var paddle: PaddleOcr?
  private var warmedUp = false
  private var disposed = false
  private var cancelled = Set<Double>()

  init(pack: ModelPack, languages: [String], threads: Int) {
    self.pack = pack
    self.languages = languages
    self.threads = threads
    v6 = pack.family == "PP-OCRv6"
    super.init()
  }

  var isReady: Bool {
    let store = ModelStore.shared
    return (try? store.files(pack))?.allSatisfy { store.isAvailable($0) } ?? false
  }

  var isLoaded: Bool { lock.locked { paddle != nil } }

  func load(warmUp: Bool, onProgress: @escaping (_ progress: PrepareProgress) -> Void, requestId: Double) throws -> Promise<LoadResult> {
    return Promise.parallel(queue) { [self] in
      try begin(requestId)
      defer { end(requestId) }
      return try loadLocked(warmUp, onProgress, requestId)
    }
  }

  private func loadLocked(_ warmUp: Bool, _ onProgress: @escaping (PrepareProgress) -> Void, _ requestId: Double) throws -> LoadResult {
    if lock.locked({ paddle }) != nil {
      let warmMs = warmUp && !lock.locked({ warmedUp }) ? try warm() : 0
      onProgress(PrepareProgress(phase: .loading, receivedBytes: 0, totalBytes: 0, fraction: 1, fileId: ""))
      return LoadResult(downloadedBytes: 0, loadMs: 0, warmUpMs: warmMs)
    }
    let store = ModelStore.shared
    let files = try store.files(pack)
    var downloaded = 0.0
    if !files.allSatisfy({ store.isAvailable($0) }) {
      let download = try store.download([pack.id], { p in
        onProgress(PrepareProgress(
          phase: p.phase, receivedBytes: p.receivedBytes, totalBytes: p.totalBytes, fraction: p.fraction * 0.85,
          fileId: p.fileId))
      }, requestId)
      downloaded = try Self.wait(download).downloadedBytes
    }
    try throwIfCancelled(requestId)
    let t0 = DispatchTime.now().uptimeNanoseconds
    func url(_ role: ModelRole) throws -> URL? {
      guard let f = files.first(where: { $0.role == role }) else { return nil }
      guard let url = store.localURL(f) else {
        throw OcrError("models-not-ready", "\(f.id) is not on the device", ["fileId": f.id])
      }
      return url
    }
    onProgress(PrepareProgress(phase: .loading, receivedBytes: 0, totalBytes: 0, fraction: 0.85, fileId: pack.id))
    guard let det = try url(.detector), let rec = try url(.recognizer), let dictURL = try url(.dictionary) else {
      throw OcrError("models-not-ready", "Pack \(pack.id) is incomplete", ["packId": pack.id])
    }
    let dictionary = try String(contentsOf: dictURL, encoding: .utf8).split(separator: "\n").map(String.init)
    let engine: PaddleOcr
    do {
      engine = try PaddleOcr(detector: det, recognizer: rec, dictionary: dictionary, threads: threads)
    } catch let e as OcrError {
      throw e
    } catch {
      throw OcrError("model-load-failed", "ONNX Runtime: \(error.localizedDescription)")
    }
    lock.locked { paddle = engine }
    let loadMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    var warmMs = 0.0
    if warmUp {
      onProgress(PrepareProgress(phase: .warmingUp, receivedBytes: 0, totalBytes: 0, fraction: 0.95, fileId: pack.id))
      warmMs = try warm()
    }
    onProgress(PrepareProgress(phase: warmUp ? .warmingUp : .loading, receivedBytes: 0, totalBytes: 0, fraction: 1, fileId: pack.id))
    return LoadResult(downloadedBytes: downloaded, loadMs: loadMs, warmUpMs: warmMs)
  }

  /** Waits on a Nitro promise from a background queue (downloads run in their own Task). */
  private static func wait<T>(_ promise: Promise<T>) throws -> T {
    let done = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    promise.then { result = .success($0); done.signal() }.catch { result = .failure($0); done.signal() }
    done.wait()
    return try result!.get()
  }

  /** One recognition of a small drawn label, so that the first real one does not pay for setup. */
  private func warm() throws -> Double {
    guard let engine = lock.locked({ paddle }) else { return 0 }
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
    _ = try engine.run(cg, PaddleCallOptions(nil as FrameRecognizeOptions?).engine(v6: v6)) {}
    lock.locked { warmedUp = true }
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
  }

  func recognizeUri(uri: String, options: RecognizeOptions, requestId: Double) throws -> Promise<OcrResult> {
    return queued(requestId, PaddleCallOptions(options)) { try ImageSource.fromUri(uri, options) }
  }

  func recognizeBase64(base64: String, options: RecognizeOptions, requestId: Double) throws -> Promise<OcrResult> {
    return queued(requestId, PaddleCallOptions(options)) { try ImageSource.fromBase64(base64, options) }
  }

  func recognizePixels(
    pixels: ArrayBuffer, width: Double, height: Double, bytesPerRow: Double, format: RawPixelFormat,
    options: RecognizeOptions, requestId: Double
  ) throws -> Promise<OcrResult> {
    // Copied now: the ArrayBuffer belongs to JS and may be gone once this returns.
    let stored = try ImageSource.copyPixels(pixels, Int(width), Int(height), Int(bytesPerRow), format)
    return queued(requestId, PaddleCallOptions(options)) { try ImageSource.fromImage(stored, options) }
  }

  private func queued(_ requestId: Double, _ o: PaddleCallOptions, _ decode: @escaping () throws -> EngineInput) -> Promise<OcrResult> {
    return Promise.parallel(queue) { [self] in
      try autoreleasepool {
        try begin(requestId)
        defer { end(requestId) }
        if lock.locked({ paddle }) == nil { _ = try loadLocked(false, { _ in }, requestId) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let input = try decode()
        try throwIfCancelled(requestId)
        return try recognize(input, o, t0, requestId)
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
        if lock.locked({ paddle }) == nil { throw OcrError("models-not-ready", "Prepare the recognizer before recognizeFrame") }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let input = try Self.frameInput(buffer, orientation, options)
        return try recognize(input, PaddleCallOptions(options), t0, 0)
      }
    }
  }

  /** The upright ROI of a camera buffer, downscaled to `maxImageSide`, as an EngineInput. */
  private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  private static func frameInput(_ buffer: CVPixelBuffer, _ orientation: FrameOrientation, _ options: FrameRecognizeOptions?) throws -> EngineInput {
    let exif = Exif.of(orientation, mirrored: options?.mirrored ?? false)
    let upright = CIImage(cvPixelBuffer: buffer).oriented(CGImagePropertyOrientation(rawValue: UInt32(exif)) ?? .up)
    let w = Int(upright.extent.width)
    let h = Int(upright.extent.height)
    let area = try Regions.resolve(options?.roi, w, h) ?? RectD(x: 0, y: 0, w: Double(w), h: Double(h))
    let maxSide = ImageSource.maxSide(options?.maxImageSide)
    let scale = maxSide > 0 ? Swift.min(1, Double(maxSide) / Swift.max(area.w, area.h)) : 1
    // Core Image puts the origin at the bottom left.
    let cropped = upright
      .transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
      .cropped(to: CGRect(x: area.x, y: Double(h) - area.bottom, width: area.w, height: area.h))
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let image = ciContext.createCGImage(cropped, from: cropped.extent) else {
      throw OcrError("frame-unsupported", "Cannot read the camera buffer")
    }
    return EngineInput(
      image: image, imageWidth: w, imageHeight: h, originX: area.x * scale, originY: area.y * scale, scaleX: scale,
      scaleY: scale, decodeMs: 0)
  }

  private func recognize(_ input: EngineInput, _ o: PaddleCallOptions, _ t0: UInt64, _ requestId: Double) throws -> OcrResult {
    guard let engine = lock.locked({ paddle }) else { throw OcrError("disposed", "The recognizer was disposed") }
    let tr = DispatchTime.now().uptimeNanoseconds
    let out = try engine.run(input.image, o.engine(v6: v6)) { try throwIfCancelled(requestId) }
    let recognizeMs = Double(DispatchTime.now().uptimeNanoseconds - tr) / 1e6
    // The detector finds lines in raster order; sort explicitly so the grouping is deterministic.
    let lines = out.lines.sorted { ($0.top, $0.left) < ($1.top, $1.left) }.map { line -> RawLine in
      let g = line.geometry
      func at(_ share: Float, _ top: Bool) -> Pt {
        let (x, y) = g.edgePoint(share, top: top)
        return input.toImage(Double(x), Double(y))
      }
      let tl = input.toImage(Double(line.left), Double(line.top))
      let br = input.toImage(Double(line.right), Double(line.bottom))
      return RawLine(
        text: line.text, confidence: Double(line.score), corners: [at(0, true), at(1, true), at(1, false), at(0, false)],
        left: tl.x, top: tl.y, right: br.x, bottom: br.y,
        words: o.output == .elements
          ? line.words.map {
            RawWord(
              text: $0.text, confidence: Double($0.score),
              corners: [at($0.start, true), at($0.end, true), at($0.end, false), at($0.start, false)])
          } : [])
    }
    let built = ResultBuilder.buildOriented(lines, input.imageWidth, input.imageHeight, o.output, o.readingOrder)
    return OcrResult(
      text: built.text,
      blocks: built.blocks,
      image: OcrImageSize(width: Double(input.imageWidth), height: Double(input.imageHeight)),
      engine: .paddle,
      languages: languages,
      timings: OcrTimings(
        decodeMs: input.decodeMs, recognizeMs: recognizeMs,
        totalMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6),
      diagnostics: o.diagnostics
        ? OcrDiagnostics(
          runtime: PaddleOcr.runtimeName, inputWidth: Double(input.image.width), inputHeight: Double(input.image.height),
          detectorMs: out.detMs, recognizerMs: out.recMs, detectorInputWidth: Double(out.detWidth),
          detectorInputHeight: Double(out.detHeight), candidateLines: Double(out.boxCount))
        : nil)
  }

  func cancel(requestId: Double) throws {
    _ = lock.locked { cancelled.insert(requestId) }
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
    lock.locked {
      disposed = true
      paddle = nil
    }
  }
}
#endif
