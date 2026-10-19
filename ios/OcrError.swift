import Foundation

/**
 * Every error the module throws. Nitro passes only `String(describing:)` to JS, so the code and
 * details travel in it as `[ocr:<code>] <message> {json details}`; `toOcrError` in JS restores them.
 * Codes are the 17 of `OcrErrorCode` (src/errors.ts).
 */
struct OcrError: Error, CustomStringConvertible, LocalizedError {
  let code: String
  let message: String
  let details: [String: Any]?

  init(_ code: String, _ message: String, _ details: [String: Any]? = nil) {
    self.code = code
    // `{` would end the message early in toOcrError's pattern.
    self.message = message.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
    self.details = details
  }

  var description: String {
    var json = ""
    if let details, !details.isEmpty, JSONSerialization.isValidJSONObject(details),
      let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    {
      json = " " + text
    }
    return "[ocr:\(code)] \(message)\(json)"
  }

  var errorDescription: String? { description }

  /** Anything thrown inside the module, as an OcrError. */
  static func wrap(_ error: Error) -> OcrError {
    if let e = error as? OcrError { return e }
    return OcrError("internal", String(describing: error))
  }
}

extension NSLock {
  /** `withLock` needs iOS 16; the module builds for older targets too. */
  @inline(__always) func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
