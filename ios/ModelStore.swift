import CryptoKit
import Foundation
import NitroModules

/**
 * Model files of the manifest: downloaded into `directory` as `<sha256>.<ext>` or shipped in the
 * pod's resources (`NitroGlyphOcr.bundle/models/<path>`). The same logic as ModelStore.kt.
 * On iOS no engine needs these files yet (Paddle on iOS is not built), but the API is the same.
 */
final class ModelStore: @unchecked Sendable {
  static let shared = ModelStore()

  private let lock = NSLock()
  private var manifestOverride: ModelManifest?
  private var baseUrl: String?
  private var headers: [String: String] = [:]
  private var source: ModelSource = .embeddedOrRemote
  private var directoryOverride: String?
  private var inFlight: [String: Task<Int, Error>] = [:]
  private var tasks: [Double: Task<DownloadResult, Error>] = [:]

  private lazy var resources: URL? = {
    let candidates = [Bundle(for: ModelStore.self), Bundle.main]
    for bundle in candidates {
      if let url = bundle.url(forResource: "NitroGlyphOcr", withExtension: "bundle") { return url }
    }
    return nil
  }()

  private lazy var builtIn: ModelManifest = {
    guard let url = resources?.appendingPathComponent("models/manifest.json"), let data = try? Data(contentsOf: url),
      let manifest = try? Self.parse(data)
    else {
      return ModelManifest(schemaVersion: 1, baseUrl: nil, files: [], packs: [])
    }
    return manifest
  }()

  var manifest: ModelManifest { lock.locked { manifestOverride } ?? builtIn }

  var directory: URL {
    let url: URL
    if let dir = lock.locked({ directoryOverride }) {
      url = URL(fileURLWithPath: dir)
    } else {
      url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ocr-models")
    }
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      // Models are re-downloadable: keep them out of backups (the system does not purge them).
      var u = url
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? u.setResourceValues(values)
    }
    return url
  }

  func configure(_ config: ModelStoreConfig) throws {
    if let m = config.manifest { try Self.validate(m) }
    lock.locked {
      if let m = config.manifest { manifestOverride = m }
      baseUrl = config.baseUrl.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
      headers = config.headers ?? [:]
      source = config.source ?? .embeddedOrRemote
      directoryOverride = config.directory
    }
  }

  // ─── Files of a pack ─────────────────────────────────────────────────────

  func pack(_ id: String) throws -> ModelPack {
    guard let p = manifest.packs.first(where: { $0.id == id }) else {
      throw OcrError("invalid-argument", "No pack \(id) in the manifest", ["packId": id])
    }
    return p
  }

  /** One file per role, ONNX (the format Paddle on ONNX Runtime would read) or the dictionary. */
  func files(_ pack: ModelPack) throws -> [ModelFile] {
    let byId = Dictionary(manifest.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let listed = pack.files.compactMap { byId[$0] }
    return try [ModelRole.detector, .recognizer, .dictionary].map { role in
      guard let f = listed.first(where: { $0.role == role && ($0.format == .onnx || $0.format == .ort || $0.format == .dict) }) else {
        throw OcrError("models-not-ready", "Pack \(pack.id) has no \(role.stringValue)", ["packId": pack.id])
      }
      return f
    }
  }

  private func ext(_ format: ModelFormat) -> String { format == .dict ? "txt" : format.stringValue }

  func installedURL(_ f: ModelFile) -> URL { directory.appendingPathComponent("\(f.sha256).\(ext(f.format))") }
  private func partURL(_ f: ModelFile) -> URL { directory.appendingPathComponent("\(f.sha256).\(ext(f.format)).part") }

  private func size(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
  }

  private func isInstalled(_ f: ModelFile) -> Bool { size(installedURL(f)) == Int(f.bytes) }

  private func mayUseEmbedded(_ f: ModelFile) -> Bool { lock.locked { source } != .remote || f.format == .dict }

  private var embeddedChecks: [String: Bool] = [:]

  /** In the pod's resources and matching its sha256; checked once per process. */
  private func isEmbedded(_ f: ModelFile) -> Bool {
    if let known = lock.locked({ embeddedChecks[f.id + f.sha256] }) { return known }
    var ok = false
    if let url = resources?.appendingPathComponent("models").appendingPathComponent(f.path),
      let data = try? Data(contentsOf: url, options: .mappedIfSafe)
    {
      ok = Self.sha256(data) == f.sha256
    }
    lock.locked { embeddedChecks[f.id + f.sha256] = ok }
    return ok
  }

  func isAvailable(_ f: ModelFile) -> Bool {
    (lock.locked({ source }) != .embedded && isInstalled(f)) || (mayUseEmbedded(f) && isEmbedded(f))
  }

  func status(_ pack: ModelPack) -> ModelPackStatus {
    guard let files = try? files(pack) else { return .missing }
    if lock.locked({ files.contains { inFlight[$0.sha256] != nil } }) { return .downloading }
    if files.allSatisfy(isAvailable) {
      return files.allSatisfy { mayUseEmbedded($0) && isEmbedded($0) } ? .embedded : .installed
    }
    let corrupt = files.contains { f in size(installedURL(f)).map { $0 != Int(f.bytes) } ?? false }
    return corrupt ? .corrupt : .missing
  }

  func urlFor(_ f: ModelFile) -> URL? {
    let base = lock.locked { baseUrl }
    if let base { return URL(string: "\(base)/\(f.path)") }
    if let url = f.url { return URL(string: url) }
    if let mb = manifest.baseUrl { return URL(string: "\(mb.hasSuffix("/") ? String(mb.dropLast()) : mb)/\(f.path)") }
    return nil
  }

  // ─── Downloading ─────────────────────────────────────────────────────────

  func download(_ packIds: [String], _ onProgress: @escaping (PrepareProgress) -> Void, _ requestId: Double) throws -> Promise<DownloadResult> {
    let packs = try packIds.map(pack)
    let files = try packs.flatMap(files)
    var seen = Set<String>()
    let missing = files.filter { !isAvailable($0) && seen.insert($0.sha256).inserted }
    if missing.isEmpty { return Promise.resolved(withResult: DownloadResult(downloadedBytes: 0, packIds: packIds)) }
    if lock.locked({ source }) == .embedded {
      throw OcrError("models-not-ready", "Not embedded: \(missing.map(\.id).joined(separator: ", "))")
    }
    let total = missing.reduce(0) { $0 + Int($1.bytes) }
    let promise = Promise<DownloadResult>()
    let task = Task<DownloadResult, Error> {
      var finished = 0
      var last = DispatchTime.now().uptimeNanoseconds
      for f in missing {
        let shared = self.sharedDownload(f) { received in
          let now = DispatchTime.now().uptimeNanoseconds
          guard now - last > 100_000_000 else { return }
          last = now
          onProgress(PrepareProgress(
            phase: received >= Int(f.bytes) ? .verifying : .downloading, receivedBytes: Double(finished + received),
            totalBytes: Double(total), fraction: Double(finished + received) / Double(total), fileId: f.id))
        }
        _ = try await withTaskCancellationHandler {
          try await shared.value
        } onCancel: {
          shared.cancel()
        }
        finished += Int(f.bytes)
      }
      onProgress(PrepareProgress(
        phase: .verifying, receivedBytes: Double(total), totalBytes: Double(total), fraction: 1, fileId: missing.last!.id))
      return DownloadResult(downloadedBytes: Double(total), packIds: packIds)
    }
    lock.locked { tasks[requestId] = task }
    Task {
      do {
        promise.resolve(withResult: try await task.value)
      } catch {
        promise.reject(withError: task.isCancelled ? OcrError("cancelled", "Cancelled") : OcrError.wrap(error))
      }
      _ = self.lock.locked { self.tasks.removeValue(forKey: requestId) }
    }
    return promise
  }

  func cancel(_ requestId: Double) {
    lock.locked { tasks[requestId] }?.cancel()
  }

  /** One download per file, shared by concurrent callers. */
  private func sharedDownload(_ f: ModelFile, _ progress: @escaping (Int) -> Void) -> Task<Int, Error> {
    lock.locked {
      if let t = inFlight[f.sha256] { return t }
      let t = Task<Int, Error> {
        defer { _ = self.lock.locked { self.inFlight.removeValue(forKey: f.sha256) } }
        return try await self.fetch(f, progress)
      }
      inFlight[f.sha256] = t
      return t
    }
  }

  /** Resumes `<sha256>.<ext>.part` with `Range`, checks sha256, moves it into place. */
  private func fetch(_ f: ModelFile, _ progress: @escaping (Int) -> Void) async throws -> Int {
    guard let url = urlFor(f) else {
      throw OcrError("download-failed", "No URL for \(f.id): configure a baseUrl", ["fileId": f.id])
    }
    let part = partURL(f)
    var offset = size(part) ?? 0
    if offset > Int(f.bytes) {
      try? FileManager.default.removeItem(at: part)
      offset = 0
    }
    let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage ?? Int64.max
    if free < Int64(Int(f.bytes) - offset + 4 << 20) {
      throw OcrError("insufficient-storage", "Need \((Int(f.bytes) - offset) / 1_000_000) MB", ["neededBytes": Int(f.bytes) - offset])
    }
    if offset < Int(f.bytes) {
      var request = URLRequest(url: url, timeoutInterval: 30)
      for (k, v) in lock.locked({ headers }) { request.setValue(v, forHTTPHeaderField: k) }
      if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
      let (bytes, response): (URLSession.AsyncBytes, URLResponse)
      do {
        (bytes, response) = try await URLSession.shared.bytes(for: request)
      } catch {
        throw OcrError("download-failed", "\(f.id): \(error.localizedDescription)", ["url": url.absoluteString])
      }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard status == 200 || status == 206 || status == 416 else {
        throw OcrError("download-failed", "\(f.id): HTTP \(status)", ["status": status, "url": url.absoluteString])
      }
      if status == 200 { offset = 0 }
      if status != 416 {
        if offset == 0 { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var received = offset
        var chunk = Data()
        chunk.reserveCapacity(1 << 16)
        do {
          for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 1 << 16 {
              try handle.write(contentsOf: chunk)
              received += chunk.count
              chunk.removeAll(keepingCapacity: true)
              progress(received)
            }
          }
          try handle.write(contentsOf: chunk)
        } catch is CancellationError {
          throw OcrError("cancelled", "Cancelled")
        } catch let e as OcrError {
          throw e
        } catch {
          throw OcrError("download-failed", "\(f.id): \(error.localizedDescription)", ["url": url.absoluteString])
        }
      }
    }
    progress(Int(f.bytes))
    let data = try Data(contentsOf: part, options: .mappedIfSafe)
    let actual = Self.sha256(data)
    guard actual == f.sha256 else {
      try? FileManager.default.removeItem(at: part)
      throw OcrError("checksum-mismatch", "\(f.id): sha256 \(actual)", ["fileId": f.id, "expected": f.sha256, "actual": actual])
    }
    let target = installedURL(f)
    try? FileManager.default.removeItem(at: target)
    try FileManager.default.moveItem(at: part, to: target)
    return Int(f.bytes)
  }

  // ─── Removing ────────────────────────────────────────────────────────────

  func remove(_ packIds: [String]) throws {
    let removing = try packIds.map(pack)
    let byId = Dictionary(manifest.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let keep = Set(manifest.packs.filter { !packIds.contains($0.id) && status($0) == .installed }
      .flatMap { $0.files.compactMap { byId[$0]?.sha256 } })
    for p in removing {
      for f in p.files.compactMap({ byId[$0] }) where !keep.contains(f.sha256) {
        try? FileManager.default.removeItem(at: installedURL(f))
        try? FileManager.default.removeItem(at: partURL(f))
      }
    }
  }

  func prune() -> Int {
    let known = Set(manifest.files.map(\.sha256))
    var freed = 0
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names {
      let sha = String(name.split(separator: ".").first ?? "")
      if known.contains(sha) || lock.locked({ inFlight[sha] != nil }) { continue }
      let url = directory.appendingPathComponent(name)
      freed += size(url) ?? 0
      try? FileManager.default.removeItem(at: url)
    }
    return freed
  }

  // ─── Manifest ────────────────────────────────────────────────────────────

  static func validate(_ m: ModelManifest) throws {
    guard m.schemaVersion == 1 else { throw OcrError("invalid-argument", "Manifest schemaVersion \(m.schemaVersion) is not 1") }
    let ids = Set(m.files.map(\.id))
    for p in m.packs {
      let unknown = p.files.filter { !ids.contains($0) }
      if !unknown.isEmpty { throw OcrError("invalid-argument", "Pack \(p.id) lists unknown files \(unknown.joined(separator: ", "))") }
    }
    for f in m.files where f.sha256.count != 64 || f.sha256.contains(where: { !"0123456789abcdef".contains($0) }) {
      throw OcrError("invalid-argument", "\(f.id): sha256 must be 64 lower-case hex digits")
    }
  }

  static func parse(_ data: Data) throws -> ModelManifest {
    guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let files = o["files"] as? [[String: Any]], let packs = o["packs"] as? [[String: Any]]
    else { throw OcrError("invalid-argument", "Not a model manifest") }
    let m = ModelManifest(
      schemaVersion: (o["schemaVersion"] as? NSNumber)?.doubleValue ?? 0,
      baseUrl: o["baseUrl"] as? String,
      files: try files.map { f in
        guard let id = f["id"] as? String, let role = (f["role"] as? String).flatMap(ModelRole.init(fromString:)),
          let format = (f["format"] as? String).flatMap(ModelFormat.init(fromString:)), let path = f["path"] as? String,
          let sha = f["sha256"] as? String, let bytes = f["bytes"] as? NSNumber
        else { throw OcrError("invalid-argument", "Bad manifest file entry") }
        return ModelFile(
          id: id, role: role, format: format, path: path, url: f["url"] as? String, sha256: sha.lowercased(),
          bytes: bytes.doubleValue, license: f["license"] as? String)
      },
      packs: try packs.map { p in
        guard let id = p["id"] as? String, let engine = (p["engine"] as? String).flatMap(OcrEngine.init(fromString:)),
          let family = p["family"] as? String, let languages = p["languages"] as? [String], let files = p["files"] as? [String]
        else { throw OcrError("invalid-argument", "Bad manifest pack entry") }
        return ModelPack(id: id, engine: engine, family: family, languages: languages, files: files)
      })
    try validate(m)
    return m
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/** JS face of ModelStore. */
final class HybridOcrModelStore: HybridOcrModelStoreSpec {
  private let store = ModelStore.shared

  var manifest: ModelManifest { store.manifest }
  var directory: String { store.directory.path }

  func configure(config: ModelStoreConfig) throws { try store.configure(config) }

  func getPackStatus(packId: String) throws -> ModelPackStatus { store.status(try store.pack(packId)) }

  func download(packIds: [String], onProgress: @escaping (_ progress: PrepareProgress) -> Void, requestId: Double) throws -> Promise<DownloadResult> {
    return try store.download(packIds, onProgress, requestId)
  }

  func remove(packIds: [String]) throws -> Promise<Void> {
    let store = self.store
    return Promise.parallel { try store.remove(packIds) }
  }

  func prune() throws -> Promise<Double> {
    let store = self.store
    return Promise.parallel { Double(store.prune()) }
  }

  func cancel(requestId: Double) throws { store.cancel(requestId) }
}
