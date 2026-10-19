package com.margelo.nitro.glyphocr.paddle

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtLoggingLevel
import ai.onnxruntime.OrtSession
import java.nio.FloatBuffer
import kotlin.math.max

/** Runs the two PP-OCRv5 models; pre/post-processing stays in [PaddleOcr]. */
interface PaddleRuntime : AutoCloseable {
  /** For diagnostics: `onnxruntime-1.30.0`, `executorch-1.4.0`. */
  val name: String

  /** Input channel order: PaddleOCR's ONNX exports take BGR, our ExecuTorch export takes RGB. */
  val rgbInput: Boolean

  /** Recognizer input widths are rounded up to a multiple of this. */
  val recWidthStep: Int

  /** [1, 3, h, w] -> [h * w] text probability. */
  fun detect(input: FloatBuffer, h: Int, w: Int): FloatArray

  /** [1, 3, 48, w] -> softmax probabilities [steps * classes]. */
  fun recognize(input: FloatBuffer, w: Int): RecOutput

  class RecOutput(val probs: FloatArray, val steps: Int, val classes: Int)
}

/** The official PaddleOCR ONNX exports on ONNX Runtime: the default runtime. */
class OrtRuntime(detModel: ByteArray, recModel: ByteArray, threads: Int, useXnnpack: Boolean) : PaddleRuntime {
  private val env = OrtEnvironment.getEnvironment()

  override val name = "onnxruntime-${OrtEnvironment.getEnvironment().version}"
  private val det = env.createSession(detModel, sessionOptions(threads, useXnnpack))
  private val rec = env.createSession(recModel, sessionOptions(threads, useXnnpack))
  private val detInput = det.inputNames.first()
  private val recInput = rec.inputNames.first()

  override val rgbInput = false
  override val recWidthStep = 1

  override fun detect(input: FloatBuffer, h: Int, w: Int): FloatArray {
    val prob = FloatArray(h * w)
    OnnxTensor.createTensor(env, input, longArrayOf(1, 3, h.toLong(), w.toLong())).use { tensor ->
      det.run(mapOf(detInput to tensor)).use { result ->
        (result.get(0) as OnnxTensor).floatBuffer.get(prob)
      }
    }
    return prob
  }

  override fun recognize(input: FloatBuffer, w: Int): PaddleRuntime.RecOutput {
    OnnxTensor.createTensor(env, input, longArrayOf(1, 3, REC_H.toLong(), w.toLong())).use { tensor ->
      rec.run(mapOf(recInput to tensor)).use { result ->
        val out = result.get(0) as OnnxTensor
        val shape = out.info.shape // [1, T, C]
        val probs = FloatArray((shape[1] * shape[2]).toInt())
        out.floatBuffer.get(probs)
        return PaddleRuntime.RecOutput(probs, shape[1].toInt(), shape[2].toInt())
      }
    }
  }

  override fun close() {
    det.close()
    rec.close()
  }

  private companion object {
    fun sessionOptions(threads: Int, useXnnpack: Boolean) = OrtSession.SessionOptions().apply {
      setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
      // The Paddle exports carry unused initializers; ONNX Runtime warns about each of them.
      setSessionLogLevel(OrtLoggingLevel.ORT_LOGGING_LEVEL_ERROR)
      if (useXnnpack) {
        // XNNPACK has its own thread pool; ORT's one should stay at 1 thread.
        addXnnpack(mapOf("intra_op_num_threads" to max(1, threads).toString()))
        setIntraOpNumThreads(1)
        addConfigEntry("session.intra_op.allow_spinning", "0")
      } else if (threads > 0) {
        setIntraOpNumThreads(threads)
      }
    }
  }
}

internal const val REC_H = 48
