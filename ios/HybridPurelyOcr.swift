import Foundation
import NitroModules

/**
 * iOS side of the OCR spike: Apple Vision text recognition (see VisionText.swift).
 * PaddleOCR and ML Kit are Android only and throw here.
 */
class HybridPurelyOcr: HybridPurelyOcrSpec {
  // One serial queue: recognitions never overlap, so their timings do not disturb each other.
  private let queue = DispatchQueue(label: "PurelyOcr", qos: .userInitiated)

  var isPaddleLoaded: Bool { false }

  var benchDir: String {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ocr-bench")
    for sub in ["in", "out"] {
      try? FileManager.default.createDirectory(
        at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    return dir.path
  }

  func loadPaddle(config: PaddleModelConfig) throws -> Promise<ModelLoadInfo> {
    throw RuntimeError.error(withMessage: "PaddleOCR is Android only")
  }

  func recognizePaddle(imageUri: String, options: PaddleOptions) throws -> Promise<OcrResult> {
    throw RuntimeError.error(withMessage: "PaddleOCR is Android only")
  }

  func recognizeMlKit(imageUri: String, maxImageSide: Double) throws -> Promise<OcrResult> {
    throw RuntimeError.error(withMessage: "ML Kit is Android only")
  }

  func recognizeVision(imageUri: String, options: VisionOptions) throws -> Promise<OcrResult> {
    guard #available(iOS 16.0, *) else {
      throw RuntimeError.error(withMessage: "Vision text recognition revision 3 needs iOS 16")
    }
    let url = try fileURL(imageUri)
    let maxSide = Int(options.maxImageSide)
    let settings = VisionText.Settings(
      usesLanguageCorrection: options.usesLanguageCorrection,
      languages: options.recognitionLanguages
    )
    return Promise.parallel(queue) {
      // Vision and ImageIO autorelease a lot; drain after every photo, or a long batch run grows.
      try autoreleasepool {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let image = try VisionText.decode(url, maxSide: maxSide)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let lines = try VisionText.recognize(image, settings)
        let t2 = DispatchTime.now().uptimeNanoseconds
        return OcrResult(
          engine: .vision,
          text: VisionText.join(lines),
          lines: lines.map {
            OcrLine(text: $0.text, score: Double($0.confidence), x: $0.left, y: $0.top,
                    width: $0.right - $0.left, height: $0.bottom - $0.top)
          },
          imageWidth: Double(image.width),
          imageHeight: Double(image.height),
          decodeMs: Double(t1 - t0) / 1e6,
          detMs: 0,
          recMs: 0,
          totalMs: Double(t2 - t1) / 1e6,
          detInputWidth: 0,
          detInputHeight: 0,
          boxCount: Double(lines.count)
        )
      }
    }
  }

  func listImages(dir: String) throws -> [String] {
    let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return files
      .filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
      .sorted()
      .map { (dir as NSString).appendingPathComponent($0) }
  }

  func writeText(path: String, content: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
  }

  func getDeviceSummary() throws -> DeviceSummary {
    let info = ProcessInfo.processInfo
    let v = info.operatingSystemVersion
    // On the simulator, utsname says "arm64"; the simulated model is in the environment.
    let model = info.environment["SIMULATOR_MODEL_IDENTIFIER"].map { "\($0) (simulator)" }
      ?? sysctlString("hw.machine")
    return DeviceSummary(
      manufacturer: "Apple",
      model: model,
      soc: sysctlString("hw.model"),
      osVersion: "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
      cpuCores: Double(info.processorCount),
      maxCpuFreqsMHz: [],
      totalRamMb: Double(info.physicalMemory / (1024 * 1024)),
      abi: "arm64"
    )
  }

  private func fileURL(_ uri: String) throws -> URL {
    if uri.hasPrefix("file://"), let url = URL(string: uri), url.isFileURL {
      return url
    }
    if uri.hasPrefix("/") {
      return URL(fileURLWithPath: uri)
    }
    throw RuntimeError.error(withMessage: "Unsupported image URI: \(uri)")
  }

  private func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: Swift.max(1, size))
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
  }
}
