import Foundation
import NitroModules

/** Entry object (autolinked): Apple Vision on iOS. Paddle on iOS (`GlyphOcr_paddleOnIos`) is not built yet. */
final class HybridGlyphOcrFactory: HybridGlyphOcrFactorySpec {
  var defaultEngine: OcrEngine { .vision }
  var availableEngines: [OcrEngine] { [.vision] }

  private lazy var store = HybridOcrModelStore()
  var models: (any HybridOcrModelStoreSpec) { store }

  static func requireVision(_ engine: OcrEngine) throws {
    switch engine {
    case .vision:
      guard #available(iOS 16.0, *) else {
        throw OcrError("engine-unavailable", "Vision text recognition revision 3 needs iOS 16", ["engine": "vision"])
      }
    case .paddle:
      throw OcrError(
        "engine-unavailable", "PaddleOCR is not in this iOS build (GlyphOcr_paddleOnIos is planned)", ["engine": "paddle"])
    case .mlkit:
      throw OcrError("engine-unavailable", "ML Kit is Android only, in react-native-glyph-ocr/dev", ["engine": "mlkit"])
    @unknown default:
      throw OcrError("engine-unavailable", "Unknown engine")
    }
  }

  func getSupportedLanguages(engine: OcrEngine?) throws -> [SupportedLanguage] {
    try Self.requireVision(engine ?? .vision)
    guard #available(iOS 16.0, *) else { return [] }
    return VisionLanguages.reported().map {
      SupportedLanguage(language: $0, engine: .vision, packId: nil, status: .ready, downloadBytes: 0)
    }
  }

  func resolveLanguages(engine: OcrEngine, languages: [String], packId: String?) throws -> LanguageResolution {
    try Self.requireVision(engine)
    guard #available(iOS 16.0, *) else { throw OcrError("engine-unavailable", "Needs iOS 16") }
    let r = try VisionLanguages.resolve(languages)
    return LanguageResolution(
      engine: .vision, languages: r.languages, engineLanguages: r.engineLanguages, packId: nil, unsupported: r.unsupported)
  }

  func createRecognizer(
    engine: OcrEngine, languages: [String], customWords: [String], packId: String?, threads: Double?
  ) throws -> (any HybridOcrRecognizerSpec) {
    try Self.create(engine, languages, customWords)
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
