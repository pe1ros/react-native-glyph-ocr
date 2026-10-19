import CoreVideo
import Foundation
import NitroModules

/** Bench helpers of the OCR spike (`react-native-purely-ocr/dev`). Not part of the public API. */
final class HybridOcrDevTools: HybridOcrDevToolsSpec {
  var benchDir: String {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ocr-bench")
    for sub in ["in", "out"] {
      try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    return dir.path
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
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
  }

  func getDeviceSummary() throws -> DeviceSummary {
    let info = ProcessInfo.processInfo
    let v = info.operatingSystemVersion
    // On the simulator, utsname says "arm64"; the simulated model is in the environment.
    let model = info.environment["SIMULATOR_MODEL_IDENTIFIER"].map { "\($0) (simulator)" } ?? sysctlString("hw.machine")
    return DeviceSummary(
      manufacturer: "Apple",
      model: model,
      soc: sysctlString("hw.model"),
      osVersion: "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
      cpuCores: Double(info.processorCount),
      maxCpuFreqsMHz: [],
      totalRamMb: Double(info.physicalMemory / (1024 * 1024)),
      abi: "arm64")
  }

  /** Vision has no tuning knobs: the recognizer is the public one. */
  func createTunedRecognizer(engine: OcrEngine, languages: [String], packId: String?, tuning: DevTuning) throws -> (any HybridOcrRecognizerSpec) {
    try HybridOcrFactory.create(engine, languages)
  }

  var isMlKitAvailable: Bool { false }

  func recognizeMlKit(uri: String, maxImageSide: Double) throws -> Promise<OcrResult> {
    throw OcrError("engine-unavailable", "ML Kit is Android only", ["engine": "mlkit"])
  }

  func createTestFrame(uri: String, maxSide: Double, orientation: FrameOrientation) throws -> UInt64 {
    let options = RecognizeOptions(
      recognitionLevel: nil, usesLanguageCorrection: nil, roi: nil, orientation: nil, minConfidence: nil,
      maxImageSide: maxSide, readingOrder: nil, output: nil, diagnostics: nil, paddle: nil)
    let input = try ImageSource.fromUri(uri, options)
    return try FrameBuffers.testFrame(input.image, Exif.of(orientation, mirrored: false))
  }

  func getTestFrameInfo(pointer: UInt64) throws -> TestFrameInfo {
    let buffer = try FrameBuffers.pixelBuffer(pointer)
    let format = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      ? "yuv-420-biplanar-full" : FrameBuffers.fourCC(CVPixelBufferGetPixelFormatType(buffer))
    return TestFrameInfo(
      width: Double(CVPixelBufferGetWidth(buffer)), height: Double(CVPixelBufferGetHeight(buffer)), pixelFormat: format)
  }

  func releaseTestFrame(pointer: UInt64) throws {
    FrameBuffers.release(pointer)
  }

  private func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: Swift.max(1, size))
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
  }
}
