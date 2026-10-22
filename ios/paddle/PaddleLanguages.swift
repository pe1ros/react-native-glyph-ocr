import Foundation

/** BCP-47 tags and how they map onto the manifest's Paddle packs; the same rules as Languages.kt. */
enum PaddleLanguages {
  private static func parse(_ tag: String) -> (language: String, script: String?) {
    let parts = tag.split(separator: "-").map(String.init)
    return (parts.first ?? "", parts.dropFirst().first { $0.count == 4 })
  }

  /** A pack language covers a request with the same language and, if both name one, the same script. */
  static func covers(_ offered: String, _ requested: String) -> Bool {
    let o = parse(offered)
    let r = parse(requested)
    return o.language == r.language && (r.script == nil || o.script == nil || r.script == o.script)
  }

  struct Resolution {
    let languages: [String]
    let pack: ModelPack?
    let unsupported: [String]
  }

  /** The first pack (manifest order) covering every language, or the given one. */
  static func resolve(_ manifest: ModelManifest, _ requested: [String], _ packId: String?) throws -> Resolution {
    var seen = Set<String>()
    let languages = requested.map(VisionLanguages.normalize).filter { !$0.isEmpty && seen.insert($0).inserted }
    if languages.isEmpty { throw OcrError("invalid-argument", "No languages given") }
    let packs = manifest.packs.filter { $0.engine == .paddle }
    func missing(_ p: ModelPack) -> [String] { languages.filter { r in !p.languages.contains { covers($0, r) } } }
    if let packId {
      guard let pack = packs.first(where: { $0.id == packId }) else {
        throw OcrError("invalid-argument", "No pack \(packId) in the manifest", ["packId": packId])
      }
      return Resolution(languages: languages, pack: pack, unsupported: missing(pack))
    }
    if let pack = packs.first(where: { missing($0).isEmpty }) {
      return Resolution(languages: languages, pack: pack, unsupported: [])
    }
    // None covers all: report what the best pack (most languages, first in order) leaves out.
    let best = packs.max { missing($0).count > missing($1).count }
    return Resolution(languages: languages, pack: nil, unsupported: best.map(missing) ?? languages)
  }
}
