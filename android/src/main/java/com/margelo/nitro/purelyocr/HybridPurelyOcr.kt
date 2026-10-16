package com.margelo.nitro.purelyocr

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.margelo.nitro.NitroModules
import com.margelo.nitro.core.Promise
import com.margelo.nitro.purelyocr.paddle.PaddleOcr
import com.margelo.nitro.purelyocr.paddle.ReadingOrder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import java.io.File
import java.util.concurrent.Executors

class HybridPurelyOcr : HybridPurelyOcrSpec() {
  private val context: Context
    get() = NitroModules.applicationContext ?: throw Error("No ApplicationContext set!")

  // One worker thread: recognitions never overlap, so their timings do not disturb each other.
  private val scope = CoroutineScope(
    SupervisorJob() + Executors.newSingleThreadExecutor { Thread(it, "PurelyOcr") }.asCoroutineDispatcher(),
  )

  @Volatile
  private var paddle: PaddleOcr? = null

  /** Cores PaddleOCR runs on (0-based); empty = any. Applied to the worker thread before each run. */
  private var paddleCpus = IntArray(0)
  private var mlKit: TextRecognizer? = null

  override val isPaddleLoaded: Boolean
    get() = paddle != null

  override val benchDir: String
    get() {
      val dir = File(context.getExternalFilesDir(null), "ocr-bench")
      File(dir, "in").mkdirs()
      File(dir, "out").mkdirs()
      return dir.absolutePath
    }

  override fun loadPaddle(config: PaddleModelConfig): Promise<ModelLoadInfo> = Promise.async(scope) {
    val t0 = SystemClock.elapsedRealtimeNanos()
    val det = readBytes(config.detModel)
    val rec = readBytes(config.recModel)
    val dict = String(readBytes(config.recDict), Charsets.UTF_8).split('\n').filter { it.isNotEmpty() }
    paddle?.close()
    paddle = null
    val cpus = config.cpus.map { it.toInt() }.toIntArray()
    paddleCpus = cpus
    // ONNX Runtime ignores its thread-affinity option on Android, but its pool threads are created
    // with the session and inherit the creating thread's CPU mask. So pin the worker first.
    pinWorker(if (cpus.isEmpty()) CpuAffinity.allCpus() else cpus)
    paddle = if (cpus.isEmpty()) {
      PaddleOcr(det, rec, dict, config.threads.toInt(), config.useXnnpack)
    } else {
      PaddleOcr(det, rec, dict, cpus.size, useXnnpack = false)
    }
    ModelLoadInfo(
      loadMs = (SystemClock.elapsedRealtimeNanos() - t0) / 1e6,
      detBytes = det.size.toDouble(),
      recBytes = rec.size.toDouble(),
      dictSize = dict.size.toDouble(),
    )
  }

  override fun recognizePaddle(imageUri: String, options: PaddleOptions): Promise<OcrResult> = Promise.async(scope) {
    val engine = paddle ?: throw Error("PaddleOCR models are not loaded")
    pinWorker(if (paddleCpus.isEmpty()) CpuAffinity.allCpus() else paddleCpus)
    val t0 = SystemClock.elapsedRealtimeNanos()
    val bitmap = ImageLoader.decode(context, imageUri, options.maxImageSide.toInt())
    val decodeMs = (SystemClock.elapsedRealtimeNanos() - t0) / 1e6
    try {
      val out = engine.run(
        bitmap,
        PaddleOcr.Options(
          detLimitSide = options.detLimitSide.toInt(),
          detThresh = options.detThresh.toFloat(),
          boxThresh = options.boxThresh.toFloat(),
          unclipRatio = options.unclipRatio.toFloat(),
          dropScore = options.dropScore.toFloat(),
        ),
      )
      OcrResult(
        engine = OcrEngine.PADDLE,
        text = ReadingOrder.join(out.lines),
        lines = out.lines.map {
          OcrLine(it.text, it.score.toDouble(), it.left.toDouble(), it.top.toDouble(),
            (it.right - it.left).toDouble(), (it.bottom - it.top).toDouble())
        }.toTypedArray(),
        imageWidth = bitmap.width.toDouble(),
        imageHeight = bitmap.height.toDouble(),
        decodeMs = decodeMs,
        detMs = out.detMs,
        recMs = out.recMs,
        totalMs = out.detMs + out.recMs,
        detInputWidth = out.detWidth.toDouble(),
        detInputHeight = out.detHeight.toDouble(),
        boxCount = out.boxCount.toDouble(),
      )
    } finally {
      bitmap.recycle()
    }
  }

  override fun recognizeMlKit(imageUri: String, maxImageSide: Double): Promise<OcrResult> = Promise.async(scope) {
    val recognizer = mlKit ?: TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS).also { mlKit = it }
    pinWorker(CpuAffinity.allCpus())
    val t0 = SystemClock.elapsedRealtimeNanos()
    val bitmap = ImageLoader.decode(context, imageUri, maxImageSide.toInt())
    val t1 = SystemClock.elapsedRealtimeNanos()
    try {
      val text = Tasks.await(recognizer.process(InputImage.fromBitmap(bitmap, 0)))
      val t2 = SystemClock.elapsedRealtimeNanos()
      val lines = text.textBlocks.flatMap { block ->
        block.lines.map { line ->
          val box = line.boundingBox
          OcrLine(
            line.text, line.confidence.toDouble(),
            (box?.left ?: 0).toDouble(), (box?.top ?: 0).toDouble(),
            (box?.width() ?: 0).toDouble(), (box?.height() ?: 0).toDouble(),
          )
        }
      }
      OcrResult(
        engine = OcrEngine.MLKIT,
        text = text.text,
        lines = lines.toTypedArray(),
        imageWidth = bitmap.width.toDouble(),
        imageHeight = bitmap.height.toDouble(),
        decodeMs = (t1 - t0) / 1e6,
        detMs = 0.0,
        recMs = 0.0,
        totalMs = (t2 - t1) / 1e6,
        detInputWidth = 0.0,
        detInputHeight = 0.0,
        boxCount = lines.size.toDouble(),
      )
    } finally {
      bitmap.recycle()
    }
  }

  override fun recognizeVision(imageUri: String, options: VisionOptions): Promise<OcrResult> =
    throw Error("Apple Vision is iOS only")

  override fun listImages(dir: String): Array<String> {
    val ext = setOf("jpg", "jpeg", "png", "heic", "heif", "webp")
    return (File(dir).listFiles() ?: emptyArray())
      .filter { it.isFile && it.extension.lowercase() in ext }
      .sortedBy { it.name }
      .map { it.absolutePath }
      .toTypedArray()
  }

  override fun writeText(path: String, content: String) {
    val file = File(path)
    file.parentFile?.mkdirs()
    file.writeText(content, Charsets.UTF_8)
  }

  override fun getDeviceSummary(): DeviceSummary {
    val cores = Runtime.getRuntime().availableProcessors()
    val freqs = (0 until cores).map { i ->
      runCatching {
        File("/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq").readText().trim().toDouble() / 1000
      }.getOrDefault(0.0)
    }
    val memory = ActivityManager.MemoryInfo()
    (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
    val soc = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}"
    } else {
      "${Build.BOARD} / ${Build.HARDWARE}"
    }
    return DeviceSummary(
      manufacturer = Build.MANUFACTURER,
      model = Build.MODEL,
      soc = soc,
      osVersion = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
      cpuCores = cores.toDouble(),
      maxCpuFreqsMHz = freqs.toDoubleArray(),
      totalRamMb = (memory.totalMem / (1024 * 1024)).toDouble(),
      abi = Build.SUPPORTED_ABIS.firstOrNull() ?: "",
    )
  }

  private fun pinWorker(cpus: IntArray) {
    val err = CpuAffinity.setCurrentThreadCpus(cpus)
    if (err != 0) Log.w(TAG, "sched_setaffinity(${cpus.joinToString()}) failed: errno $err")
  }

  /** `name` is a file in the module's `assets/ocr/` or an absolute path. */
  private fun readBytes(name: String): ByteArray =
    if (name.startsWith("/")) File(name).readBytes()
    else context.assets.open("ocr/$name").use { it.readBytes() }

  companion object {
    private const val TAG = "PurelyOcr"
  }

  override fun dispose() {
    paddle?.close()
    paddle = null
    mlKit?.close()
    mlKit = null
    super.dispose()
  }
}
