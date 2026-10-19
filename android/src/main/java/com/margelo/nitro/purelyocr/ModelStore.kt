package com.margelo.nitro.purelyocr

import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.margelo.nitro.NitroModules
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.coroutineContext

/**
 * Model files of the manifest: where they are (downloaded into [directory] as `<sha256>.<ext>`, or
 * embedded in the APK as `assets/ocr-models/<path>`), and downloading the missing ones.
 * One per process; [HybridOcrModelStore] is its JS face.
 */
internal object ModelStore {
  private const val TAG = "PurelyOcr"
  private const val BUILT_IN_MANIFEST = "purelyocr/manifest.json"
  private const val EMBEDDED_DIR = "ocr-models"

  val context: Context
    get() = NitroModules.applicationContext ?: throw OcrException("internal", "No application context")

  @Volatile private var manifestOverride: ModelManifest? = null
  @Volatile private var baseUrl: String? = null
  @Volatile private var headers: Map<String, String> = emptyMap()
  @Volatile private var source: ModelSource = ModelSource.EMBEDDED_OR_REMOTE
  @Volatile private var directoryOverride: String? = null

  private val builtIn: ModelManifest by lazy {
    val json = context.assets.open(BUILT_IN_MANIFEST).use { String(it.readBytes(), Charsets.UTF_8) }
    parseManifest(json)
  }

  val manifest: ModelManifest get() = manifestOverride ?: builtIn

  val directory: File
    get() = File(directoryOverride ?: File(context.noBackupFilesDir, "ocr-models").path).also { it.mkdirs() }

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

  /** Downloads in flight, by sha256: concurrent prepare() calls share one. */
  private val inFlight = ConcurrentHashMap<String, FileDownload>()

  fun configure(config: ModelStoreConfig) {
    config.manifest?.let { validate(it) }
    manifestOverride = config.manifest ?: manifestOverride
    baseUrl = config.baseUrl?.trimEnd('/')
    headers = config.headers ?: emptyMap()
    source = config.source ?: ModelSource.EMBEDDED_OR_REMOTE
    directoryOverride = config.directory
  }

  // ─── Files of a pack ─────────────────────────────────────────────────────

  /** Formats ONNX Runtime reads; dictionaries are text. */
  val ORT_FORMATS = setOf(ModelFormat.ONNX, ModelFormat.ORT, ModelFormat.DICT)

  fun pack(packId: String): ModelPack =
    manifest.packs.firstOrNull { it.id == packId }
      ?: throw OcrException("invalid-argument", "No pack $packId in the manifest", mapOf("packId" to packId))

  /** One file per role, the first in a format the runtime reads. */
  fun files(pack: ModelPack, roles: Set<ModelRole>, formats: Set<ModelFormat>): List<ModelFile> {
    val byId = manifest.files.associateBy { it.id }
    val listed = pack.files.mapNotNull { byId[it] }
    return roles.map { role ->
      listed.firstOrNull { it.role == role && it.format in formats }
        ?: throw OcrException(
          "models-not-ready", "Pack ${pack.id} has no ${role.name.lowercase()} in ${formats.joinToString { it.name.lowercase() }}",
          mapOf("packId" to pack.id),
        )
    }
  }

  fun allRoles() = setOf(ModelRole.DETECTOR, ModelRole.RECOGNIZER, ModelRole.DICTIONARY)

  private fun ext(format: ModelFormat) = if (format == ModelFormat.DICT) "txt" else format.name.lowercase()

  fun installedFile(file: ModelFile) = File(directory, "${file.sha256}.${ext(file.format)}")

  private fun isInstalled(file: ModelFile): Boolean =
    installedFile(file).let { it.isFile && it.length() == file.bytes.toLong() }

  /** Dictionaries ship inside the package, so they are used from it whatever `source` says. */
  private fun mayUseEmbedded(file: ModelFile) = source != ModelSource.REMOTE || file.format == ModelFormat.DICT

  fun isAvailable(file: ModelFile): Boolean =
    (source != ModelSource.EMBEDDED && isInstalled(file)) || (mayUseEmbedded(file) && isEmbedded(file))

  fun packStatus(pack: ModelPack, formats: Set<ModelFormat> = ORT_FORMATS): ModelPackStatus {
    val files = try {
      files(pack, allRoles(), formats)
    } catch (e: OcrException) {
      return ModelPackStatus.MISSING
    }
    if (files.any { inFlight.containsKey(it.sha256) }) return ModelPackStatus.DOWNLOADING
    if (files.all { isAvailable(it) }) {
      val embedded = files.all { mayUseEmbedded(it) && isEmbedded(it) }
      return if (embedded) ModelPackStatus.EMBEDDED else ModelPackStatus.INSTALLED
    }
    val corrupt = files.any { f -> installedFile(f).let { it.isFile && it.length() != f.bytes.toLong() } }
    return if (corrupt) ModelPackStatus.CORRUPT else ModelPackStatus.MISSING
  }

  /** Bytes still to download for the pack. */
  fun missingBytes(pack: ModelPack, formats: Set<ModelFormat> = ORT_FORMATS): Long = try {
    files(pack, allRoles(), formats).filterNot { isAvailable(it) }.distinctBy { it.sha256 }.sumOf { it.bytes.toLong() }
  } catch (e: OcrException) {
    0
  }

  /** Whether the missing files can be fetched at all. */
  fun canDownload(pack: ModelPack, formats: Set<ModelFormat> = ORT_FORMATS): Boolean = try {
    source != ModelSource.EMBEDDED &&
      files(pack, allRoles(), formats).filterNot { isAvailable(it) }.all { urlFor(it) != null }
  } catch (e: OcrException) {
    false
  }

  fun readBytes(file: ModelFile): ByteArray {
    if (source != ModelSource.EMBEDDED && isInstalled(file)) return installedFile(file).readBytes()
    if (mayUseEmbedded(file) && isEmbedded(file)) {
      return context.assets.open("$EMBEDDED_DIR/${file.path}").use { it.readBytes() }
    }
    throw OcrException("models-not-ready", "${file.id} is not on the device", mapOf("fileId" to file.id))
  }

  // ─── Embedded files ──────────────────────────────────────────────────────

  private val embeddedChecks = ConcurrentHashMap<String, Boolean>()

  /** In the APK and matching its sha256; the check runs once per app version and is remembered. */
  private fun isEmbedded(file: ModelFile): Boolean = embeddedChecks.getOrPut(file.id + file.sha256) {
    val asset = "$EMBEDDED_DIR/${file.path}"
    val exists = try {
      context.assets.open(asset).close()
      true
    } catch (e: IOException) {
      false
    }
    if (!exists) return@getOrPut false
    val prefs = context.getSharedPreferences("purelyocr-embedded", Context.MODE_PRIVATE)
    val version = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
    val key = "$asset@${file.sha256}"
    if (prefs.getLong(key, -1) == version) return@getOrPut true
    val actual = context.assets.open(asset).use { sha256(it) }
    if (actual != file.sha256) {
      Log.e(TAG, "Embedded $asset: sha256 $actual != ${file.sha256}, ignored")
      return@getOrPut false
    }
    prefs.edit().putLong(key, version).apply()
    true
  }

  // ─── Downloading ─────────────────────────────────────────────────────────

  fun urlFor(file: ModelFile): String? =
    baseUrl?.let { "$it/${file.path}" } ?: file.url ?: manifest.baseUrl?.trimEnd('/')?.let { "$it/${file.path}" }

  private class FileDownload(val file: ModelFile) {
    val done = CompletableDeferred<Long>()
    @Volatile var received = 0L
    val listeners = CopyOnWriteArrayList<() -> Unit>()
    val waiters = AtomicInteger(0)
    @Volatile var job: Job? = null
  }

  /**
   * Makes `files` available, downloading the missing ones one after another. Reports
   * `downloading` and `verifying` with fractions between `from` and `to`. Returns downloaded bytes.
   */
  suspend fun ensure(files: List<ModelFile>, progress: ProgressReporter, from: Double = 0.0, to: Double = 1.0): Long {
    val missing = files.filterNot { isAvailable(it) }.distinctBy { it.sha256 }
    if (missing.isEmpty()) return 0
    if (source == ModelSource.EMBEDDED) {
      throw OcrException(
        "models-not-ready", "Not embedded: ${missing.joinToString { it.id }}",
        mapOf("fileIds" to JSONArray(missing.map { it.id })),
      )
    }
    val total = missing.sumOf { it.bytes.toLong() }
    val dir = directory
    val partial = missing.sumOf { f -> partFile(f).let { if (it.isFile) it.length() else 0L } }
    val needed = total - partial + 4L * 1024 * 1024
    if (dir.usableSpace < needed) {
      throw OcrException(
        "insufficient-storage", "Need ${needed / 1_000_000} MB, ${dir.usableSpace / 1_000_000} MB free",
        mapOf("neededBytes" to needed, "availableBytes" to dir.usableSpace),
      )
    }
    var finished = 0L
    for (file in missing) {
      val download = inFlight.computeIfAbsent(file.sha256) { FileDownload(file).also { start(it) } }
      val report = {
        val received = finished + download.received
        val phase = if (download.received >= file.bytes.toLong()) PreparePhase.VERIFYING else PreparePhase.DOWNLOADING
        progress.report(phase, received.toDouble(), total.toDouble(), from + (to - from) * received / total, file.id)
      }
      download.listeners.add(report)
      download.waiters.incrementAndGet()
      try {
        download.done.await()
      } finally {
        download.listeners.remove(report)
        // The last caller to stop waiting (e.g. cancelled) stops the download; the .part file stays.
        if (download.waiters.decrementAndGet() == 0 && !download.done.isCompleted) download.job?.cancel()
      }
      finished += file.bytes.toLong()
    }
    progress.report(PreparePhase.VERIFYING, total.toDouble(), total.toDouble(), to, missing.last().id, force = true)
    return total
  }

  private fun partFile(file: ModelFile) = File(directory, "${file.sha256}.${ext(file.format)}.part")

  private fun start(download: FileDownload) {
    download.job = scope.launch {
      // Caught here: an exception escaping `launch` would crash the app.
      try {
        download.done.complete(fetch(download))
      } catch (t: Throwable) {
        download.done.completeExceptionally(OcrException.wrap(t))
      }
    }.also { job ->
      // Also runs when the job is cancelled before it started.
      job.invokeOnCompletion { t ->
        inFlight.remove(download.file.sha256)
        if (t != null) download.done.completeExceptionally(OcrException.wrap(t))
      }
    }
  }

  /** Resumes `<sha256>.<ext>.part` with `Range`, checks sha256, renames it into place. */
  private suspend fun fetch(download: FileDownload): Long {
    val file = download.file
    val url = urlFor(file)
      ?: throw OcrException("download-failed", "No URL for ${file.id}: configure a baseUrl", mapOf("fileId" to file.id))
    val part = partFile(file)
    val bytes = file.bytes.toLong()
    var offset = if (part.isFile) part.length() else 0L
    if (offset > bytes) {
      part.delete()
      offset = 0
    }
    if (offset < bytes) {
      val t0 = SystemClock.elapsedRealtime()
      val conn = (URL(url).openConnection() as HttpURLConnection).apply {
        connectTimeout = 15_000
        readTimeout = 30_000
        instanceFollowRedirects = true
        headers.forEach { (k, v) -> setRequestProperty(k, v) }
        if (offset > 0) setRequestProperty("Range", "bytes=$offset-")
      }
      try {
        val status = try {
          conn.responseCode
        } catch (e: IOException) {
          throw OcrException("download-failed", "${file.id}: ${e.message}", mapOf("url" to url), e)
        }
        val append = when (status) {
          206 -> true
          200 -> false
          416 -> true // the part is already complete
          else -> throw OcrException("download-failed", "${file.id}: HTTP $status", mapOf("status" to status, "url" to url))
        }
        if (!append) offset = 0
        download.received = offset
        if (status != 416) {
          conn.inputStream.use { input ->
            FileOutputStream(part, append).use { out ->
              val buf = ByteArray(1 shl 16)
              while (true) {
                coroutineContext.ensureActive()
                val n = try {
                  input.read(buf)
                } catch (e: IOException) {
                  throw OcrException("download-failed", "${file.id}: ${e.message}", mapOf("url" to url), e)
                }
                if (n < 0) break
                try {
                  out.write(buf, 0, n)
                } catch (e: IOException) {
                  throw OcrException("insufficient-storage", "${file.id}: ${e.message}", cause = e)
                }
                download.received += n
                download.listeners.forEach { it() }
              }
            }
          }
        }
        Log.i(TAG, "Downloaded ${file.id} (${part.length()} bytes) in ${SystemClock.elapsedRealtime() - t0} ms")
      } finally {
        conn.disconnect()
      }
    }
    download.received = bytes
    download.listeners.forEach { it() }
    val actual = part.inputStream().use { sha256(it) }
    if (actual != file.sha256) {
      part.delete()
      throw OcrException(
        "checksum-mismatch", "${file.id}: sha256 $actual",
        mapOf("fileId" to file.id, "expected" to file.sha256, "actual" to actual),
      )
    }
    val target = installedFile(file)
    if (!part.renameTo(target)) throw OcrException("internal", "Cannot move ${part.name} into place")
    return bytes
  }

  // ─── Removing ────────────────────────────────────────────────────────────

  fun remove(packIds: List<String>) {
    val removing = packIds.map { pack(it) }
    val kept = manifest.packs.filter { p -> p.id !in packIds && packStatus(p) == ModelPackStatus.INSTALLED }
    val byId = manifest.files.associateBy { it.id }
    val keep = kept.flatMap { p -> p.files.mapNotNull { byId[it]?.sha256 } }.toSet()
    for (pack in removing) {
      for (file in pack.files.mapNotNull { byId[it] }) {
        if (file.sha256 in keep) continue
        installedFile(file).delete()
        partFile(file).delete()
      }
    }
  }

  /** Deletes files no file of the current manifest refers to. Returns freed bytes. */
  fun prune(): Long {
    val known = manifest.files.map { it.sha256 }.toSet()
    var freed = 0L
    for (f in directory.listFiles() ?: emptyArray()) {
      if (f.name.substringBefore(".") in known || inFlight.containsKey(f.name.substringBefore("."))) continue
      freed += f.length()
      f.delete()
    }
    return freed
  }

  // ─── Manifest ────────────────────────────────────────────────────────────

  private fun validate(m: ModelManifest) {
    if (m.schemaVersion.toInt() != 1) {
      throw OcrException("invalid-argument", "Manifest schemaVersion ${m.schemaVersion} is not 1")
    }
    val ids = m.files.map { it.id }.toSet()
    for (p in m.packs) {
      val unknown = p.files.filter { it !in ids }
      if (unknown.isNotEmpty()) {
        throw OcrException("invalid-argument", "Pack ${p.id} lists unknown files ${unknown.joinToString()}")
      }
    }
    for (f in m.files) {
      if (!Regex("^[0-9a-f]{64}$").matches(f.sha256)) {
        throw OcrException("invalid-argument", "${f.id}: sha256 must be 64 lower-case hex digits")
      }
    }
  }

  private fun parseManifest(json: String): ModelManifest {
    val o = JSONObject(json)
    val files = o.getJSONArray("files").let { a ->
      Array(a.length()) { i ->
        val f = a.getJSONObject(i)
        ModelFile(
          id = f.getString("id"),
          role = ModelRole.valueOf(f.getString("role").uppercase()),
          format = ModelFormat.valueOf(f.getString("format").uppercase()),
          path = f.getString("path"),
          url = f.optString("url").ifEmpty { null },
          sha256 = f.getString("sha256").lowercase(),
          bytes = f.getDouble("bytes"),
          license = f.optString("license").ifEmpty { null },
        )
      }
    }
    val packs = o.getJSONArray("packs").let { a ->
      Array(a.length()) { i ->
        val p = a.getJSONObject(i)
        ModelPack(
          id = p.getString("id"),
          engine = OcrEngine.valueOf(p.getString("engine").uppercase()),
          family = p.getString("family"),
          languages = strings(p.getJSONArray("languages")),
          files = strings(p.getJSONArray("files")),
        )
      }
    }
    return ModelManifest(o.getDouble("schemaVersion"), o.optString("baseUrl").ifEmpty { null }, files, packs).also { validate(it) }
  }

  private fun strings(a: JSONArray) = Array(a.length()) { a.getString(it) }

  fun sha256(input: InputStream): String {
    val md = MessageDigest.getInstance("SHA-256")
    val buf = ByteArray(1 shl 16)
    while (true) {
      val n = input.read(buf)
      if (n < 0) break
      md.update(buf, 0, n)
    }
    return md.digest().joinToString("") { "%02x".format(it) }
  }
}

/** Sends `PrepareProgress` to JS at most 10 times a second. */
internal class ProgressReporter(private val onProgress: ((PrepareProgress) -> Unit)?) {
  private var last = 0L

  @Synchronized
  fun report(phase: PreparePhase, received: Double, total: Double, fraction: Double, fileId: String, force: Boolean = false) {
    val callback = onProgress ?: return
    val now = SystemClock.elapsedRealtime()
    if (!force && now - last < 100) return
    last = now
    callback(PrepareProgress(phase, received, total, fraction.coerceIn(0.0, 1.0), fileId))
  }
}
