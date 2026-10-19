import CoreGraphics
import Foundation
import Vision

/** BCP-47 tags → the languages Vision reports for revision 3 (they change with the iOS version). */
@available(iOS 16.0, *)
enum VisionLanguages {
  static func supported(_ level: VNRequestTextRecognitionLevel) -> [String] {
    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLevel = level
    return (try? request.supportedRecognitionLanguages()) ?? []
  }

  /** `RU` → `ru`, `zh_hans` → `zh-Hans`, `pt-br` → `pt-BR`. */
  static func normalize(_ tag: String) -> String {
    let parts = tag.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
      .split(separator: "-").map(String.init)
    return parts.enumerated().map { i, p -> String in
      if i == 0 { return p.lowercased() }
      if p.count == 4, p.allSatisfy(\.isLetter) { return p.prefix(1).uppercased() + p.dropFirst().lowercased() }
      if p.count == 2, p.allSatisfy(\.isLetter) { return p.uppercased() }
      return p.lowercased()
    }.joined(separator: "-")
  }

  private static func parse(_ tag: String) -> (language: String, script: String?) {
    let parts = tag.split(separator: "-").map(String.init)
    return (parts.first?.lowercased() ?? "", parts.dropFirst().first { $0.count == 4 })
  }

  /**
   * The exact entry if Vision has it, else the first with the same language (and script, if the
   * tag names one): `ru` → `ru-RU`, `pt` → `pt-BR`, `vi` → `vi-VT`. `zh` alone is ambiguous.
   */
  static func map(_ tag: String, _ supported: [String]) throws -> String? {
    if let exact = supported.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return exact }
    let t = parse(tag)
    if t.language == "zh" && t.script == nil {
      throw OcrError("invalid-argument", "zh needs a script: zh-Hans or zh-Hant", ["language": tag, "suggestion": ["zh-Hans", "zh-Hant"]])
    }
    return supported.first { s in
      let p = parse(s)
      return p.language == t.language && (t.script == nil || p.script == t.script)
    }
  }

  struct Resolution {
    let languages: [String]
    let engineLanguages: [String]
    let unsupported: [String]
  }

  static func resolve(_ requested: [String]) throws -> Resolution {
    var languages: [String] = []
    for tag in requested.map(normalize) where !tag.isEmpty && !languages.contains(tag) { languages.append(tag) }
    if languages.isEmpty { throw OcrError("invalid-argument", "No languages given") }
    let supported = supported(.accurate)
    var engine: [String] = []
    var unsupported: [String] = []
    for tag in languages {
      if let e = try map(tag, supported) {
        if !engine.contains(e) { engine.append(e) }
      } else {
        unsupported.append(tag)
      }
    }
    return Resolution(languages: languages, engineLanguages: engine, unsupported: unsupported)
  }

  /** Vision's list as `getSupportedLanguages` reports it: without the region unless two entries need it. */
  static func reported() -> [String] {
    let supported = supported(.accurate)
    return supported.map { s -> String in
      let p = parse(s)
      let short = p.script.map { "\(p.language)-\($0)" } ?? p.language
      let clash = supported.filter { other in
        let q = parse(other)
        return q.language == p.language && q.script == p.script
      }.count > 1
      return clash ? s : short
    }
  }
}

/** Options shared by photos and frames. */
struct VisionOptions {
  var level: RecognitionLevel = .accurate
  var languageCorrection = true
  var minConfidence = 0.0
  var readingOrder: ReadingOrder = .blocks
  var output: OcrOutput = .elements
  var diagnostics = false

  init(_ o: RecognizeOptions) {
    level = o.recognitionLevel ?? .accurate
    languageCorrection = o.usesLanguageCorrection ?? true
    minConfidence = o.minConfidence ?? 0
    readingOrder = o.readingOrder ?? .blocks
    output = o.output ?? .elements
    diagnostics = o.diagnostics ?? false
  }

  init(_ o: FrameRecognizeOptions?) {
    level = o?.recognitionLevel ?? .accurate
    languageCorrection = o?.usesLanguageCorrection ?? true
    minConfidence = o?.minConfidence ?? 0
    readingOrder = o?.readingOrder ?? .blocks
    output = o?.output ?? .elements
    diagnostics = o?.diagnostics ?? false
  }
}

/** `VNRecognizeTextRequest`, revision 3, as measured in docs/spikes/apple-vision-ios.md. */
@available(iOS 16.0, *)
enum VisionEngine {
  static func makeRequest(_ o: VisionOptions, _ languages: [String], _ customWords: [String]) -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLevel = o.level == .fast ? .fast : .accurate
    request.recognitionLanguages = languages
    request.usesLanguageCorrection = o.languageCorrection
    request.customWords = customWords
    return request
  }

  /** `fast` knows fewer languages than `accurate` (none with Cyrillic in iOS 26). */
  static func checkLevel(_ o: VisionOptions, _ languages: [String]) throws {
    guard o.level == .fast else { return }
    let fast = VisionLanguages.supported(.fast)
    let missing = languages.filter { !fast.contains($0) }
    if !missing.isEmpty {
      throw OcrError(
        "language-not-supported", "Vision's fast level cannot read \(missing.joined(separator: ", "))",
        ["engine": "vision", "unsupported": missing, "suggestion": "recognitionLevel: 'accurate'"])
    }
  }

  /**
   * Lines of a finished request. `toImage` maps Vision's normalized points (origin at the bottom
   * left of the processed image) to whole upright-image pixels.
   */
  static func lines(_ request: VNRecognizeTextRequest, _ o: VisionOptions, _ toImage: (CGPoint) -> Pt) -> [RawLine] {
    (request.results ?? []).compactMap { obs -> RawLine? in
      guard let best = obs.topCandidates(1).first else { return nil }
      let confidence = Double(best.confidence)
      if confidence < o.minConfidence { return nil }
      let b = obs.boundingBox
      let tl = toImage(CGPoint(x: b.minX, y: b.maxY))
      let br = toImage(CGPoint(x: b.maxX, y: b.minY))
      var words: [RawWord] = []
      if o.output == .elements {
        let text = best.string
        var i = text.startIndex
        while i < text.endIndex {
          guard let start = text[i...].firstIndex(where: { !$0.isWhitespace }) else { break }
          let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
          if let box = try? best.boundingBox(for: start..<end) {
            words.append(RawWord(
              text: String(text[start..<end]), confidence: confidence,
              corners: [box.topLeft, box.topRight, box.bottomRight, box.bottomLeft].map(toImage)))
          }
          i = end
        }
      }
      return RawLine(
        text: best.string, confidence: confidence,
        corners: [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft].map(toImage),
        left: Swift.min(tl.x, br.x), top: Swift.min(tl.y, br.y), right: Swift.max(tl.x, br.x), bottom: Swift.max(tl.y, br.y),
        words: words)
    }
  }
}
