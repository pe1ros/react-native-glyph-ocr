package com.margelo.nitro.glyphocr

import android.graphics.Bitmap
import com.margelo.nitro.glyphocr.paddle.PaddleRuntime
import java.lang.reflect.InvocationTargetException

/**
 * Parts compiled in only with build flags (see android/build.gradle): ExecuTorch (`src/executorch`,
 * when android/executorch holds the minimal build) and ML Kit for `/dev` (`src/mlkit`,
 * `GlyphOcr_devMlKit=true`). Loaded by reflection, so the main source set builds without them.
 */
internal object PaddleRuntimes {
  val hasExecuTorch: Boolean get() = BuildConfig.GLYPHOCR_EXECUTORCH

  fun executorch(program: String, threads: Int): PaddleRuntime {
    if (!hasExecuTorch) {
      throw OcrException("engine-unavailable", "This build has no ExecuTorch (android/executorch is missing)")
    }
    val cls = Class.forName("com.margelo.nitro.glyphocr.paddle.ExecuTorchRuntime")
    return try {
      cls.getConstructor(String::class.java, Int::class.javaPrimitiveType).newInstance(program, threads) as PaddleRuntime
    } catch (e: InvocationTargetException) {
      throw OcrException("model-load-failed", e.targetException.message ?: e.targetException.toString(), cause = e.targetException)
    }
  }
}

/** ML Kit Text Recognition v2 (Latin), for comparison in the bench. */
internal interface MlKitEngine : AutoCloseable {
  /** ML Kit's own blocks of lines, in pixels of `bitmap`. */
  fun recognize(bitmap: Bitmap): List<List<RawLine>>

  companion object {
    val isAvailable: Boolean get() = BuildConfig.GLYPHOCR_MLKIT

    fun create(): MlKitEngine {
      if (!isAvailable) throw OcrException("engine-unavailable", "ML Kit is compiled in only with GlyphOcr_devMlKit=true")
      return Class.forName("com.margelo.nitro.glyphocr.MlKitTextEngine").getConstructor().newInstance() as MlKitEngine
    }
  }
}
