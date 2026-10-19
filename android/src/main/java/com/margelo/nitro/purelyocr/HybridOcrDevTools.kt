package com.margelo.nitro.purelyocr

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.SystemClock
import com.margelo.nitro.core.Promise
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import java.io.File
import java.util.concurrent.Executors

/** Bench helpers of the OCR spike (`react-native-purely-ocr/dev`). Not part of the public API. */
class HybridOcrDevTools : HybridOcrDevToolsSpec() {
  private val context: Context get() = ModelStore.context

  private val scope = CoroutineScope(
    SupervisorJob() + Executors.newSingleThreadExecutor { Thread(it, "PurelyOcr-dev") }.asCoroutineDispatcher(),
  )
  private var mlKit: MlKitEngine? = null

  override val benchDir: String
    get() {
      val dir = File(context.getExternalFilesDir(null), "ocr-bench")
      File(dir, "in").mkdirs()
      File(dir, "out").mkdirs()
      return dir.absolutePath
    }

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

  override fun createTunedRecognizer(engine: OcrEngine, languages: Array<String>, packId: String?, tuning: DevTuning): HybridOcrRecognizerSpec =
    HybridOcrFactory.create(engine, languages, packId, tuning.threads?.toInt() ?: HybridOcrFactory.DEFAULT_THREADS, tuning)

  override val isMlKitAvailable: Boolean get() = MlKitEngine.isAvailable

  override fun recognizeMlKit(uri: String, maxImageSide: Double): Promise<OcrResult> = Requests.promise(scope, 0.0) {
    val engine = mlKit ?: MlKitEngine.create().also { mlKit = it }
    val t0 = SystemClock.elapsedRealtimeNanos()
    val input = ImageSource.fromUri(context, uri, options(maxImageSide))
    try {
      val t1 = SystemClock.elapsedRealtimeNanos()
      val groups = engine.recognize(input.bitmap).map { block -> block.map { toImage(it, input) } }
      val recognizeMs = (SystemClock.elapsedRealtimeNanos() - t1) / 1e6
      // ML Kit's own blocks, in its order: the same text as ML Kit's `Text.text`.
      val built = ResultBuilder.build(
        groups.flatten(), input.imageWidth, input.imageHeight, OcrOutput.ELEMENTS, ReadingOrder.BLOCKS, groups,
      )
      OcrResult(
        built.text, built.blocks, OcrImageSize(input.imageWidth.toDouble(), input.imageHeight.toDouble()),
        OcrEngine.MLKIT, arrayOf("en"),
        OcrTimings(input.decodeMs, recognizeMs, (SystemClock.elapsedRealtimeNanos() - t0) / 1e6),
        OcrDiagnostics(
          "mlkit-text-recognition-16.0.1", input.bitmap.width.toDouble(), input.bitmap.height.toDouble(),
          0.0, 0.0, 0.0, 0.0, groups.sumOf { it.size }.toDouble(),
        ),
      )
    } finally {
      input.bitmap.recycle()
    }
  }

  private fun toImage(line: RawLine, input: EngineInput): RawLine {
    fun map(p: Pt) = input.toImage(p.x, p.y)
    val tl = input.toImage(line.left, line.top)
    val br = input.toImage(line.right, line.bottom)
    return RawLine(
      line.text, line.confidence, line.corners.map(::map), tl.x, tl.y, br.x, br.y,
      line.words.map { RawWord(it.text, it.confidence, it.corners.map(::map)) },
    )
  }

  private fun options(maxImageSide: Double) =
    RecognizeOptions(null, null, null, null, null, maxImageSide, null, null, null, null)

  override fun createTestFrame(uri: String, maxSide: Double, orientation: FrameOrientation): ULong {
    val input = ImageSource.fromUri(context, uri, options(maxSide))
    try {
      // Even sides, as camera buffers have: odd YUV 4:2:0 buffers break the emulator's gralloc.
      val w = input.bitmap.width and 1.inv()
      val h = input.bitmap.height and 1.inv()
      if (w < 2 || h < 2) throw OcrException("invalid-argument", "The photo is too small for a frame")
      val argb = IntArray(w * h)
      input.bitmap.getPixels(argb, 0, w, 0, 0, w, h)
      val pointer = FrameBuffers.createTestFrame(argb, w, h, Exif.of(orientation, false))
      // Statuses are -1..-4; real pointers can be negative too (a tag in the top byte).
      if (pointer in -4L..0L) FrameBuffers.check(pointer.toInt(), 0)
      return pointer.toULong()
    } finally {
      input.bitmap.recycle()
    }
  }

  override fun getTestFrameInfo(pointer: ULong): TestFrameInfo {
    val desc = FrameBuffers.describe(pointer.toLong())
    if (desc.size < 3) throw OcrException("frame-unsupported", "AHardwareBuffer API is not available")
    val format = if (desc[2] == 1 || desc[2] == 2) "rgba" else "yuv-420"
    return TestFrameInfo(desc[0].toDouble(), desc[1].toDouble(), format)
  }

  override fun releaseTestFrame(pointer: ULong) = FrameBuffers.release(pointer.toLong())

  override fun dispose() {
    mlKit?.close()
    mlKit = null
    super.dispose()
  }
}
