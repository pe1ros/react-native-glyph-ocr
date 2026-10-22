import Foundation
import NitroModules

/**
 * Entry object (autolinked): Apple Vision on iOS, plus PaddleOCR in builds made with
 * `GlyphOcr_paddleOnIos=1` (ONNX Runtime and the PP-OCR packs, for languages Vision does not read).
 */
final class HybridGlyphOcrFactory: HybridGlyphOcrFactorySpec {
  #if GLYPHOCR_PADDLE
    static let paddleBuilt = true
  #else
    static let paddleBuilt = false
  #endif

  var defaultEngine: OcrEngine { .vision }
  var availableEngines: [OcrEngine] { Self.paddleBuilt ? [.vision, .paddle] : [.vision] }

  private lazy var store = HybridOcrModelStore()
  var models: (any HybridOcrModelStoreSpec) { store }

  static func requireEngine(_ engine: OcrEngine) throws {
    switch engine {
    case .vision:
      guard #available(iOS 16.0, *) else {
        throw OcrError("engine-unavailable", "Vision text recognition revision 3 needs iOS 16", ["engine": "vision"])
      }
    case .paddle:
      if !paddleBuilt {
        throw OcrError(
          "engine-unavailable", "PaddleOCR is not in this iOS build: install pods with GlyphOcr_paddleOnIos=1",
          ["engine": "paddle"])
      }
    case .mlkit:
      throw OcrError("engine-unavailable", "ML Kit is Android only, in react-native-glyph-ocr/dev", ["engine": "mlkit"])
    @unknown default:
      throw OcrError("engine-unavailable", "Unknown engine")
    }
  }

  static func requireVision(_ engine: OcrEngine) throws {
    try requireEngine(engine)
    if engine != .vision { throw OcrError("engine-unavailable", "Only Vision here", ["engine": engine.stringValue]) }
  }

  func getSupportedLanguages(engine: OcrEngine?) throws -> [SupportedLanguage] {
    if let engine { try Self.requireEngine(engine) }
    var out: [SupportedLanguage] = []
    if engine == nil || engine == .vision, #available(iOS 16.0, *) {
      out += VisionLanguages.reported().map {
        SupportedLanguage(language: $0, engine: .vision, packId: nil, status: .ready, downloadBytes: 0)
      }
    }
    if Self.paddleBuilt && (engine == nil || engine == .paddle) {
      let models = ModelStore.shared
      for pack in models.manifest.packs where pack.engine == .paddle {
        let packStatus = models.status(pack)
        let status: LanguageStatus =
          packStatus == .installed || packStatus == .embedded ? .ready
          : (try? models.files(pack))?.allSatisfy({ models.isAvailable($0) || models.urlFor($0) != nil }) == true
            ? .needsDownload : .unavailable
        let bytes = Double(models.missingBytes(pack))
        out += pack.languages.map {
          SupportedLanguage(language: $0, engine: .paddle, packId: pack.id, status: status, downloadBytes: bytes)
        }
      }
    }
    return out
  }

  func resolveLanguages(engine: OcrEngine, languages: [String], packId: String?) throws -> LanguageResolution {
    try Self.requireEngine(engine)
    if engine == .paddle {
      let r = try PaddleLanguages.resolve(ModelStore.shared.manifest, languages, packId)
      return LanguageResolution(
        engine: .paddle, languages: r.languages, engineLanguages: [], packId: r.pack?.id, unsupported: r.unsupported)
    }
    guard #available(iOS 16.0, *) else { throw OcrError("engine-unavailable", "Needs iOS 16") }
    let r = try VisionLanguages.resolve(languages)
    return LanguageResolution(
      engine: .vision, languages: r.languages, engineLanguages: r.engineLanguages, packId: nil, unsupported: r.unsupported)
  }

  func createRecognizer(
    engine: OcrEngine, languages: [String], customWords: [String], packId: String?, threads: Double?
  ) throws -> (any HybridOcrRecognizerSpec) {
    #if GLYPHOCR_PADDLE
      if engine == .paddle {
        let r = try PaddleLanguages.resolve(ModelStore.shared.manifest, languages, packId)
        guard let pack = r.pack, r.unsupported.isEmpty else {
          throw OcrError(
            "language-not-supported", "paddle cannot read \(r.unsupported.joined(separator: ", "))",
            ["engine": "paddle", "unsupported": r.unsupported])
        }
        return HybridPaddleRecognizer(pack: pack, languages: r.languages, threads: threads.map { Int($0) } ?? 4)
      }
    #endif
    return try Self.create(engine, languages, customWords)
  }

  static func create(_ engine: OcrEngine, _ languages: [String], _ customWords: [String] = []) throws -> (any HybridOcrRecognizerSpec) {
    try requireVision(engine)
    guard #available(iOS 16.0, *) else { throw OcrError("engine-unavailable", "Needs iOS 16") }
    let r = try VisionLanguages.resolve(languages)
    if !r.unsupported.isEmpty {
      throw OcrError(
        "language-not-supported", "vision cannot read \(r.unsupported.joined(separator: ", "))",
        ["engine": "vision", "unsupported": r.unsupported])
    }
    return HybridOcrRecognizer(languages: r.languages, engineLanguages: r.engineLanguages, customWords: customWords)
  }

  func createFrameMeter() throws -> (any HybridOcrFrameMeterSpec) {
    HybridOcrFrameMeter()
  }
}
