package com.margelo.nitro.glyphocr

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.SystemClock
import android.util.Log
import com.margelo.nitro.core.ArrayBuffer
import com.margelo.nitro.core.Promise
import com.margelo.nitro.glyphocr.paddle.OrtRuntime
import com.margelo.nitro.glyphocr.paddle.PaddleOcr
import com.margelo.nitro.glyphocr.paddle.PaddleRuntime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Options shared by photos and frames. */
internal class EngineOptions(
  val level: RecognitionLevel?,
  val minConfidence: Double?,
  val readingOrder: ReadingOrder?,
  val output: OcrOutput?,
  val diagnostics: Boolean?,
  val paddle: PaddleTuning?,
) {
  constructor(o: RecognizeOptions) : this(o.recognitionLevel, o.minConfidence, o.readingOrder, o.output, o.diagnostics, o.paddle)
  constructor(o: FrameRecognizeOptions?) :
    this(o?.recognitionLevel, o?.minConfidence, o?.readingOrder, o?.output, o?.diagnostics, o?.paddle)
}

/**
 * PaddleOCR (PP-OCRv5) with one model pack. Requests run one at a time on the recognizer's own
 * thread; `recognizeFrame` runs on the caller's thread and waits for the same engine lock.
 */
class HybridOcrRecognizer internal constructor(
  private val pack: ModelPack,
  override val languages: Array<String>,
  private val threads: Int,
  private val tuning: DevTuning? = null,
) : HybridOcrRecognizerSpec() {
  override val engine = OcrEngine.PADDLE
  override val packId: String = pack.id

  private val executor = Executors.newSingleThreadExecutor { Thread(it, "GlyphOcr-${pack.id}") }
  private val scope = CoroutineScope(SupervisorJob() + executor.asCoroutineDispatcher())
  /** Orders requests: a suspended download inside `load` must not let a recognition in. */
  private val queue = Mutex()
  /** The engine's buffers are not thread-safe: photos and frames take turns. */
  private val engineLock = ReentrantLock()

  @Volatile private var paddle: PaddleOcr? = null
  @Volatile private var warmedUp = false
  @Volatile private var disposed = false
  private var loadedBytes = 0L

  private val runtimeKind = tuning?.runtime ?: PaddleRuntimeKind.ONNXRUNTIME
  private val cpus = tuning?.cpus?.map { it.toInt() }?.toIntArray() ?: IntArray(0)

  private val files: List<ModelFile>
    get() = if (runtimeKind == PaddleRuntimeKind.EXECUTORCH) {
      ModelStore.files(pack, setOf(ModelRole.DICTIONARY), setOf(ModelFormat.DICT))
    } else {
      ModelStore.files(pack, ModelStore.allRoles(), ModelStore.ORT_FORMATS)
    }

  override val isReady: Boolean
    get() = try {
      files.all { ModelStore.isAvailable(it) } &&
        (runtimeKind != PaddleRuntimeKind.EXECUTORCH || tuning?.program?.let { File(it).isFile } == true)
    } catch (e: OcrException) {
      false
    }

  override val isLoaded: Boolean
    get() = paddle != null

  override val memorySize: Long
    get() = if (paddle != null) 3 * loadedBytes else 0

  override fun load(warmUp: Boolean, onProgress: (progress: PrepareProgress) -> Unit, requestId: Double): Promise<LoadResult> =
    Requests.promise(scope, requestId) {
      queue.withLock { loadLocked(warmUp, ProgressReporter(onProgress), requestId) }
    }

  private suspend fun loadLocked(warmUp: Boolean, progress: ProgressReporter, requestId: Double): LoadResult {
    assertAlive()
    if (paddle != null) {
      val warmMs = if (warmUp && !warmedUp) warm() else 0.0
      progress.report(PreparePhase.LOADING, 0.0, 0.0, 1.0, "", force = true)
      return LoadResult(0.0, 0.0, warmMs)
    }
    val files = files
    val downloaded = ModelStore.ensure(files, progress, 0.0, 0.85)
    Requests.throwIfCancelled(requestId)
    progress.report(PreparePhase.LOADING, 0.0, 0.0, 0.85, files.first().id, force = true)
    val t0 = SystemClock.elapsedRealtimeNanos()
    pinWorker()
    val runtime = createRuntime(files)
    val dictFile = files.first { it.role == ModelRole.DICTIONARY }
    val dict = String(ModelStore.readBytes(dictFile), Charsets.UTF_8).split('\n').filter { it.isNotEmpty() }
    engineLock.withLock { paddle = PaddleOcr(runtime, dict) }
    loadedBytes = files.sumOf { it.bytes.toLong() }
    val loadMs = (SystemClock.elapsedRealtimeNanos() - t0) / 1e6
    var warmMs = 0.0
    if (warmUp) {
      progress.report(PreparePhase.WARMING_UP, 0.0, 0.0, 0.95, dictFile.id, force = true)
      warmMs = warm()
    }
    progress.report(if (warmUp) PreparePhase.WARMING_UP else PreparePhase.LOADING, 0.0, 0.0, 1.0, dictFile.id, force = true)
    Log.i(TAG, "Loaded ${pack.id} (${runtime.name}) in ${loadMs.toInt()} ms, warm-up ${warmMs.toInt()} ms")
    return LoadResult(downloaded.toDouble(), loadMs, warmMs)
  }

  private fun createRuntime(files: List<ModelFile>): PaddleRuntime {
    val threads = if (cpus.isEmpty()) threads else cpus.size
    return try {
      when (runtimeKind) {
        PaddleRuntimeKind.ONNXRUNTIME -> OrtRuntime(
          ModelStore.readBytes(files.first { it.role == ModelRole.DETECTOR }),
          ModelStore.readBytes(files.first { it.role == ModelRole.RECOGNIZER }),
          threads,
          tuning?.useXnnpack == true && cpus.isEmpty(),
        )
        PaddleRuntimeKind.EXECUTORCH -> {
          val program = tuning?.program ?: throw OcrException("invalid-argument", "ExecuTorch needs DevTuning.program")
          if (!File(program).isFile) throw OcrException("models-not-ready", "No ExecuTorch program at $program")
          PaddleRuntimes.executorch(program, threads)
        }
      }
    } catch (e: OcrException) {
      throw e
    } catch (t: Throwable) {
      throw OcrException("model-load-failed", t.message ?: t.toString(), cause = t)
    }
  }

  /** One recognition of a small drawn label, so that the first real one does not pay for setup. */
  private fun warm(): Double {
    val engine = paddle ?: return 0.0
    val bitmap = Bitmap.createBitmap(960, 720, Bitmap.Config.ARGB_8888)
    Canvas(bitmap).apply {
      drawColor(Color.WHITE)
      val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK; textSize = 44f }
      listOf("Состав: вода, сахар, соль,", "лимонная кислота E330, крахмал.", "Ingredients: water, sugar 12%").forEachIndexed { i, s ->
        drawText(s, 60f, 200f + i * 90f, paint)
      }
    }
    val t0 = SystemClock.elapsedRealtimeNanos()
    try {
      engineLock.withLock { engine.run(bitmap, paddleOptions(EngineOptions(null as FrameRecognizeOptions?))) }
    } finally {
      bitmap.recycle()
    }
    warmedUp = true
    return (SystemClock.elapsedRealtimeNanos() - t0) / 1e6
  }

  override fun recognizeUri(uri: String, options: RecognizeOptions, requestId: Double): Promise<OcrResult> =
    queued(requestId, EngineOptions(options)) { ImageSource.fromUri(ModelStore.context, uri, options) }

  override fun recognizeBase64(base64: String, options: RecognizeOptions, requestId: Double): Promise<OcrResult> =
    queued(requestId, EngineOptions(options)) { ImageSource.fromBase64(base64, options) }

  override fun recognizePixels(
    pixels: ArrayBuffer, width: Double, height: Double, bytesPerRow: Double, format: RawPixelFormat,
    options: RecognizeOptions, requestId: Double,
  ): Promise<OcrResult> {
    // Copied now: the ArrayBuffer belongs to JS and may be gone once this returns.
    val argb = ImageSource.pixelsToArgb(pixels.getBuffer(false), width.toInt(), height.toInt(), bytesPerRow.toInt(), format)
    return queued(requestId, EngineOptions(options)) { ImageSource.fromArgb(argb, width.toInt(), height.toInt(), options) }
  }

  private fun queued(requestId: Double, options: EngineOptions, decode: () -> EngineInput): Promise<OcrResult> =
    Requests.promise(scope, requestId) {
      queue.withLock {
        assertAlive()
        if (paddle == null) loadLocked(false, ProgressReporter(null), requestId)
        val t0 = SystemClock.elapsedRealtimeNanos()
        pinWorker()
        val input = decode()
        try {
          Requests.throwIfCancelled(requestId)
          recognize(input, options, t0, requestId)
        } finally {
          input.bitmap.recycle()
        }
      }
    }

  override fun recognizeFrame(nativeBufferPointer: ULong, orientation: FrameOrientation, options: FrameRecognizeOptions?): OcrResult {
    assertAlive()
    if (paddle == null) throw OcrException("models-not-ready", "Prepare the recognizer before recognizeFrame")
    try {
      val t0 = SystemClock.elapsedRealtimeNanos()
      val input = ImageSource.fromFrame(
        nativeBufferPointer.toLong(), orientation, options?.mirrored ?: false, options?.roi, options?.maxImageSide,
      )
      try {
        return recognize(input, EngineOptions(options), t0, 0.0)
      } finally {
        input.bitmap.recycle()
      }
    } catch (t: Throwable) {
      throw OcrException.wrap(t)
    }
  }

  private fun paddleOptions(o: EngineOptions) = PaddleOcr.Options(
    detLimitSide = o.paddle?.detectorSide?.toInt()?.takeIf { it > 0 } ?: if (o.level == RecognitionLevel.FAST) 736 else 960,
    detThresh = (o.paddle?.detectorThreshold ?: 0.3).toFloat(),
    boxThresh = (o.paddle?.boxThreshold ?: 0.6).toFloat(),
    unclipRatio = (o.paddle?.unclipRatio ?: 1.5).toFloat(),
    dropScore = (o.minConfidence ?: 0.5).toFloat(),
  )

  private fun recognize(input: EngineInput, o: EngineOptions, t0: Long, requestId: Double): OcrResult {
    val engine = paddle ?: throw OcrException("disposed", "The recognizer was disposed")
    val output = o.output ?: OcrOutput.ELEMENTS
    var recognizeMs = 0.0
    val out = engineLock.withLock {
      // Timed inside the lock: a frame waiting for a photo is not engine time.
      val tr = SystemClock.elapsedRealtimeNanos()
      engine.run(input.bitmap, paddleOptions(o)) { Requests.throwIfCancelled(requestId) }.also {
        recognizeMs = (SystemClock.elapsedRealtimeNanos() - tr) / 1e6
      }
    }
    // The detector finds lines in raster order; sort explicitly so the grouping is deterministic.
    val lines = out.lines.sortedWith(compareBy({ it.top }, { it.left })).map { line ->
      val g = line.geometry
      fun at(share: Float, top: Boolean): Pt {
        val (x, y) = g.edgePoint(share, top)
        return input.toImage(x.toDouble(), y.toDouble())
      }
      val tl = input.toImage(line.left.toDouble(), line.top.toDouble())
      val br = input.toImage(line.right.toDouble(), line.bottom.toDouble())
      RawLine(
        text = line.text,
        confidence = line.score.toDouble(),
        corners = listOf(at(0f, true), at(1f, true), at(1f, false), at(0f, false)),
        left = tl.x, top = tl.y, right = br.x, bottom = br.y,
        words = if (output == OcrOutput.ELEMENTS) {
          line.words.map { w ->
            RawWord(w.text, w.score.toDouble(), listOf(at(w.start, true), at(w.end, true), at(w.end, false), at(w.start, false)))
          }
        } else {
          emptyList()
        },
      )
    }
    val built = ResultBuilder.build(lines, input.imageWidth, input.imageHeight, output, o.readingOrder ?: ReadingOrder.BLOCKS)
    val totalMs = (SystemClock.elapsedRealtimeNanos() - t0) / 1e6
    return OcrResult(
      text = built.text,
      blocks = built.blocks,
      image = OcrImageSize(input.imageWidth.toDouble(), input.imageHeight.toDouble()),
      engine = OcrEngine.PADDLE,
      languages = languages,
      timings = OcrTimings(input.decodeMs, recognizeMs, totalMs),
      diagnostics = if (o.diagnostics == true) {
        OcrDiagnostics(
          runtime = engine.runtimeName,
          inputWidth = input.bitmap.width.toDouble(),
          inputHeight = input.bitmap.height.toDouble(),
          detectorMs = out.detMs,
          recognizerMs = out.recMs,
          detectorInputWidth = out.detWidth.toDouble(),
          detectorInputHeight = out.detHeight.toDouble(),
          candidateLines = out.boxCount.toDouble(),
        )
      } else {
        null
      },
    )
  }

  override fun cancel(requestId: Double) = Requests.cancel(requestId)

  /** Dev tuning: ONNX Runtime ignores its affinity option on Android, but its pool threads inherit ours. */
  private fun pinWorker() {
    if (cpus.isEmpty()) return
    val err = CpuAffinity.setCurrentThreadCpus(cpus)
    if (err != 0) Log.w(TAG, "sched_setaffinity(${cpus.joinToString()}) failed: errno $err")
  }

  private fun assertAlive() {
    if (disposed) throw OcrException("disposed", "The recognizer was disposed")
  }

  override fun dispose() {
    if (disposed) return
    disposed = true
    // After the running request; queued ones then fail with `disposed`.
    scope.launch {
      queue.withLock {
        engineLock.withLock {
          paddle?.close()
          paddle = null
        }
      }
      executor.shutdown()
    }
    super.dispose()
  }

  companion object {
    private const val TAG = "GlyphOcr"
  }
}
