package com.margelo.nitro.glyphocr.paddle

import android.util.Log
import org.pytorch.executorch.EValue
import org.pytorch.executorch.Module
import org.pytorch.executorch.Tensor
import java.nio.FloatBuffer

// Compiled only into builds with ExecuTorch (android/executorch, see build.gradle). Created by
// reflection from PaddleRuntimes, so the main source set does not depend on it.

/**
 * One fused ExecuTorch program with `detect` and `recognize` methods, lowered to XNNPACK or Vulkan
 * (see scripts/ocr-spike/executorch). It takes RGB and recognizer widths that are multiples of 8,
 * the contract of react-native-executorch's createPaddleOcr. Our ExecuTorch build has XNNPACK only:
 * Vulkan programs fail to load with ExecutorchRuntimeException.
 */
class ExecuTorchRuntime(path: String, threads: Int) : PaddleRuntime {
  private val module = Module.load(path, Module.LOAD_MODE_MMAP, threads)

  override val name = "executorch-1.4.0"

  override val rgbInput = true
  override val recWidthStep = 8

  init {
    for (method in arrayOf("detect", "recognize")) {
      Log.i("GlyphOcr", "ExecuTorch: loading $method from $path")
      module.loadMethod(method)
    }
  }

  override fun detect(input: FloatBuffer, h: Int, w: Int): FloatArray {
    val tensor = Tensor.fromBlob(input, longArrayOf(1, 3, h.toLong(), w.toLong()))
    return module.execute("detect", EValue.from(tensor))[0].toTensor().dataAsFloatArray
  }

  override fun recognize(input: FloatBuffer, w: Int): PaddleRuntime.RecOutput {
    val tensor = Tensor.fromBlob(input, longArrayOf(1, 3, REC_H.toLong(), w.toLong()))
    val out = module.execute("recognize", EValue.from(tensor))[0].toTensor()
    val shape = out.shape() // [1, T, C]
    return PaddleRuntime.RecOutput(out.dataAsFloatArray, shape[1].toInt(), shape[2].toInt())
  }

  override fun close() {
    module.destroy()
  }
}

